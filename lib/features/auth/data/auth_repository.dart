import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../../../core/config/platform_config.dart';
import '../domain/app_user.dart';
import '../domain/user_role.dart';
import 'auth_config.dart';
import 'auth_exception.dart';

/// Everything the UI needs from the auth system, expressed without any Firebase
/// types. Screens depend on this interface, so tests can provide a fake and the
/// real implementation can be swapped without touching the UI.
abstract interface class AuthRepository {
  /// Emits the current [AppUser] whenever sign-in state changes, and `null`
  /// when signed out. Emits once on startup.
  Stream<AppUser?> authStateChanges();

  /// Re-reads the signed-in user's profile (e.g. after onboarding updates it).
  Future<AppUser?> currentUser();

  Future<void> signInWithEmail({
    required String email,
    required String password,
  });

  /// Sends a password-reset email to [email].
  Future<void> sendPasswordReset(String email);

  Future<void> registerWithEmail({
    required String email,
    required String password,
    required String displayName,
    required UserRole role,
  });

  /// Signs in with Google. If this is a brand-new account, a profile is created
  /// using [roleIfNew]; existing accounts keep their stored role.
  Future<void> signInWithGoogle({required UserRole roleIfNew});

  /// Saves a provider's reference point for "Jobs near you".
  Future<void> updateBaseLocation({
    required String uid,
    required double lat,
    required double lng,
    required String address,
  });

  /// Saves the editable profile fields (Edit Profile screen). Only the passed
  /// fields are written; balances, role and Trust Score are never touched here.
  Future<void> updateProfile({
    required String uid,
    required String displayName,
    required String? phone,
    required String? location,
    required String? bio,
  });

  /// Toggles whether [jobId] is on [uid]'s watchlist (the bookmark on a job
  /// card / feed / "Jobs near you"). Not a protected field — the self-update
  /// rule already permits it.
  Future<void> setJobSaved({
    required String uid,
    required String jobId,
    required bool saved,
  });

  Future<void> signOut();

  /// Permanently deletes the signed-in user's Firebase Auth account. Firestore
  /// cleanup (the `users/{uid}` profile and its subcollections) happens
  /// server-side via the `cleanupUserDoc` Cloud Function, triggered by the
  /// Auth deletion.
  ///
  /// Firebase requires a recent sign-in for this; if the session is stale,
  /// [password] is used to reauthenticate (email/password accounts) or a
  /// fresh Google sign-in is triggered (Google accounts) before retrying.
  Future<void> deleteAccount({String? password});
}

/// The production [AuthRepository], backed by Firebase Authentication for
/// credentials and Cloud Firestore for the `users/{uid}` profile that holds the
/// person's role, wallet balance, Trust Score, etc.
class FirebaseAuthRepository implements AuthRepository {
  FirebaseAuthRepository({
    FirebaseAuth? auth,
    FirebaseFirestore? firestore,
  })  : _auth = auth ?? FirebaseAuth.instance,
        _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseAuth _auth;
  final FirebaseFirestore _firestore;

  CollectionReference<Map<String, dynamic>> get _users =>
      _firestore.collection('users');

  @override
  Stream<AppUser?> authStateChanges() {
    // Re-emit not only when the Firebase Auth state changes (sign in/out), but
    // also whenever the signed-in user's Firestore profile changes — so an
    // admin approving their verification, or any other profile edit, reflects
    // live in the app without forcing a re-login.
    late final StreamController<AppUser?> controller;
    StreamSubscription<User?>? authSub;
    StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? profileSub;

    void emit(AppUser? user) {
      if (!controller.isClosed) controller.add(user);
    }

    controller = StreamController<AppUser?>(
      onListen: () {
        authSub = _auth.authStateChanges().listen((user) {
          profileSub?.cancel();
          profileSub = null;
          if (user == null) {
            emit(null);
            return;
          }
          // Live-watch the profile doc; fall back to a minimal user if it
          // can't be read so the app never gets stuck on the splash screen.
          profileSub = _users.doc(user.uid).snapshots().listen(
                (snapshot) => emit(_mapUser(user, snapshot.data())),
                onError: (_) => emit(_fallbackUser(user)),
              );
        });
      },
      onCancel: () async {
        await profileSub?.cancel();
        await authSub?.cancel();
      },
    );
    return controller.stream;
  }

  @override
  Future<AppUser?> currentUser() => _toAppUser(_auth.currentUser);

  @override
  Future<void> signInWithEmail({
    required String email,
    required String password,
  }) {
    return _guard(() => _auth.signInWithEmailAndPassword(
          email: email.trim(),
          password: password,
        ));
  }

  @override
  Future<void> sendPasswordReset(String email) {
    return _guard(() => _auth.sendPasswordResetEmail(email: email.trim()));
  }

  @override
  Future<void> registerWithEmail({
    required String email,
    required String password,
    required String displayName,
    required UserRole role,
  }) {
    return _guard(() async {
      final credential = await _auth.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      final user = credential.user!;
      try {
        await user.updateDisplayName(displayName.trim());
        await _createProfileIfMissing(user, role, displayName.trim());
      } catch (_) {
        // The auth account exists but we failed to finish setting it up (e.g.
        // the profile write was denied). Roll it back so the email is free to
        // retry and we never leave an account without a profile.
        await user.delete().catchError((_) {});
        rethrow;
      }
    });
  }

  @override
  Future<void> signInWithGoogle({required UserRole roleIfNew}) {
    return _guard(() async {
      final signIn = GoogleSignIn.instance;

      // google_sign_in 7.x must be initialised once before use, and the
      // interactive `authenticate()` flow is only available on some platforms.
      await signIn.initialize(serverClientId: googleServerClientId);
      if (!signIn.supportsAuthenticate()) {
        throw const AuthException(
          'Google sign-in is not supported on this platform.',
        );
      }

      final googleUser = await signIn.authenticate();
      final idToken = googleUser.authentication.idToken;
      if (idToken == null) {
        throw const AuthException('Google did not return a valid token.');
      }

      // Firebase only needs the ID token to verify a Google sign-in.
      final credential = GoogleAuthProvider.credential(idToken: idToken);
      final userCredential = await _auth.signInWithCredential(credential);
      await _createProfileIfMissing(
        userCredential.user!,
        roleIfNew,
        googleUser.displayName ?? userCredential.user!.displayName ?? '',
      );
    });
  }

  @override
  Future<void> updateBaseLocation({
    required String uid,
    required double lat,
    required double lng,
    required String address,
  }) {
    return _users.doc(uid).set({
      'baseLat': lat,
      'baseLng': lng,
      'baseAddress': address,
    }, SetOptions(merge: true));
  }

  @override
  Future<void> updateProfile({
    required String uid,
    required String displayName,
    required String? phone,
    required String? location,
    required String? bio,
  }) {
    return _users.doc(uid).set({
      'displayName': displayName.trim(),
      'phone': phone?.trim(),
      'location': location?.trim(),
      'bio': bio?.trim(),
    }, SetOptions(merge: true));
  }

  @override
  Future<void> setJobSaved({
    required String uid,
    required String jobId,
    required bool saved,
  }) {
    return _users.doc(uid).update({
      'watchlist': saved
          ? FieldValue.arrayUnion([jobId])
          : FieldValue.arrayRemove([jobId]),
    });
  }

  @override
  Future<void> signOut() async {
    // Sign out of both Google and Firebase so the next login prompts again.
    await GoogleSignIn.instance.signOut();
    await _auth.signOut();
  }

  @override
  Future<void> deleteAccount({String? password}) {
    return _guard(() async {
      final user = _auth.currentUser;
      if (user == null) return;
      try {
        await user.delete();
      } on FirebaseAuthException catch (e) {
        if (e.code != 'requires-recent-login') rethrow;
        await _reauthenticate(user, password);
        await user.delete();
      }
    });
  }

  /// Satisfies Firebase's recent-login requirement before a sensitive action
  /// (here, account deletion) by re-proving the user's identity.
  Future<void> _reauthenticate(User user, String? password) async {
    final usesPassword =
        user.providerData.any((p) => p.providerId == 'password');
    if (usesPassword) {
      final email = user.email;
      if (email == null || password == null || password.isEmpty) {
        throw const AuthException(
            'Please enter your password to confirm account deletion.');
      }
      await user.reauthenticateWithCredential(
        EmailAuthProvider.credential(email: email, password: password),
      );
      return;
    }

    final signIn = GoogleSignIn.instance;
    await signIn.initialize(serverClientId: googleServerClientId);
    final googleUser = await signIn.authenticate();
    final idToken = googleUser.authentication.idToken;
    if (idToken == null) {
      throw const AuthException('Google did not return a valid token.');
    }
    await user.reauthenticateWithCredential(
      GoogleAuthProvider.credential(idToken: idToken),
    );
  }

  /// Creates the Firestore profile only the first time an account appears, so
  /// re-logins never overwrite an existing role or balance.
  Future<void> _createProfileIfMissing(
    User user,
    UserRole role,
    String displayName,
  ) async {
    final doc = _users.doc(user.uid);
    final snapshot = await doc.get();
    if (snapshot.exists) return;

    // No trust or rating fields: rules reject them at create, and the
    // `recomputeTrustOnUserWrite` Cloud Function seeds the server-computed
    // Trust Score moments after this write lands.
    await doc.set({
      'role': role.storageValue,
      'displayName': displayName.isEmpty ? (user.email ?? 'User') : displayName,
      'email': user.email,
      'walletBalanceSen': 0,
      'verificationStatus': 'none',
      'onboardingComplete': false,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  /// Reads the role from the profile and builds an [AppUser]. Returns `null`
  /// when signed out. Used by [currentUser] for a one-shot read; the live
  /// stream in [authStateChanges] maps snapshots through [_mapUser] directly.
  Future<AppUser?> _toAppUser(User? user) async {
    if (user == null) return null;
    try {
      final snapshot = await _users.doc(user.uid).get();
      return _mapUser(user, snapshot.data());
    } on FirebaseException {
      // If the profile can't be read (offline, transient error), fall back to a
      // minimal user so the app never gets stuck on the splash screen.
      return _fallbackUser(user);
    }
  }

  /// Builds an [AppUser] from a Firebase auth [user] and its Firestore profile
  /// [data] (null when the doc doesn't exist yet, e.g. mid-registration).
  AppUser _mapUser(User user, Map<String, dynamic>? data) {
    final onboarding = data?['onboarding'] as Map<String, dynamic>?;
    final accountLast4 = onboarding?['accountLast4'] as String?;
    return AppUser(
      uid: user.uid,
      email: user.email,
      displayName:
          data?['displayName'] as String? ?? user.displayName ?? user.email,
      role: UserRole.fromStorage(data?['role'] as String?),
      verificationStatus: data?['verificationStatus'] as String? ?? 'none',
      onboardingComplete: data?['onboardingComplete'] as bool? ?? false,
      trustScore: (data?['trustScore'] as num?)?.toInt() ?? 0,
      phone: data?['phone'] as String?,
      location: data?['location'] as String?,
      baseLat: (data?['baseLat'] as num?)?.toDouble(),
      baseLng: (data?['baseLng'] as num?)?.toDouble(),
      baseAddress: data?['baseAddress'] as String?,
      bio: data?['bio'] as String?,
      walletBalanceSen: (data?['walletBalanceSen'] as num?)?.toInt() ?? 0,
      escrowLockedSen: (data?['escrowLockedSen'] as num?)?.toInt() ?? 0,
      ratingCount: (data?['ratingCount'] as num?)?.toInt() ?? 0,
      ratingSum: (data?['ratingSum'] as num?)?.toInt() ?? 0,
      jobsCompleted: (data?['jobsCompleted'] as num?)?.toInt() ?? 0,
      disputesLost: (data?['disputesLost'] as num?)?.toInt() ?? 0,
      trustBreakdown: data?['trust'] == null
          ? null
          : TrustBreakdown.fromMap(data!['trust'] as Map<String, dynamic>),
      profilePhotoUrl: data?['profilePhotoUrl'] as String?,
      providerType: onboarding?['providerType'] as String?,
      payoutBankName: onboarding?['bankName'] as String?,
      payoutAccountLast4:
          accountLast4 == null || accountLast4.isEmpty ? null : accountLast4,
      isPasswordAccount: _isPasswordAccount(user),
      watchlist:
          (data?['watchlist'] as List?)?.whereType<String>().toList() ??
              const [],
    );
  }

  /// A minimal user built from auth alone, used when the profile can't be read.
  AppUser _fallbackUser(User user) => AppUser(
        uid: user.uid,
        email: user.email,
        displayName: user.displayName ?? user.email,
        role: UserRole.requestor,
        isPasswordAccount: _isPasswordAccount(user),
      );

  bool _isPasswordAccount(User user) =>
      user.providerData.any((p) => p.providerId == 'password');

  /// Runs a Firebase call and rethrows failures as user-friendly
  /// [AuthException]s.
  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } on FirebaseAuthException catch (e) {
      throw AuthException.fromFirebase(e);
    } on GoogleSignInException catch (e) {
      // The user closing the Google sheet is not an error worth showing.
      if (e.code == GoogleSignInExceptionCode.canceled) return;
      // Surface the real cause (e.g. clientConfigurationError) to aid debugging.
      final detail = e.description?.trim();
      throw AuthException(
        'Google sign-in failed (${e.code.name})'
        '${detail == null || detail.isEmpty ? '' : ': $detail'}.',
      );
    } on FirebaseException catch (e) {
      // Non-auth Firebase errors, e.g. a Firestore permission-denied while
      // saving or reading the profile. (FirebaseAuthException is caught above.)
      throw AuthException(_firebaseMessage(e));
    }
  }

  String _firebaseMessage(FirebaseException e) {
    return switch (e.code) {
      'permission-denied' =>
        'Could not save your profile: access denied. Check the Firestore '
            'security rules.',
      'unavailable' =>
        'Could not reach the database. Check your connection and try again.',
      _ => 'Could not save your profile (${e.code}). Please try again.',
    };
  }
}
