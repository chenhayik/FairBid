import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../../../core/config/platform_config.dart';
import '../../../core/location/region.dart';
import '../domain/app_user.dart';
import '../domain/mfa.dart';
import '../domain/user_role.dart';
import 'auth_config.dart';
import 'auth_exception.dart';

/// What:   Auth and profile API the UI depends on, free of Firebase types.
/// Input:  Firebase Auth + Firestore via FirebaseAuthRepository; a fake in tests.
/// Output: AppUser reads/streams; failures as AuthException or MfaRequiredException.
abstract interface class AuthRepository {
  /// Emits the [AppUser] on every sign-in or profile change, `null` when signed out.
  Stream<AppUser?> authStateChanges();

  /// Re-reads the signed-in user's profile.
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

  /// Sends the "verify your email" message to the signed-in user's address.
  Future<void> sendEmailVerification();

  /// Re-reads the account and reports whether the email is now verified.
  Future<bool> reloadUser();

  /// Re-proves the signed-in user's identity before a sensitive action.
  /// [password] is required for email/password accounts; ignored for Google.
  Future<void> reauthenticate({String? password});

  /// The second factors enrolled on the signed-in account (empty when none).
  Future<List<MfaFactor>> enrolledFactors();

  /// Starts TOTP enrolment; needs a verified email and a recent login ([reauthenticate]).
  Future<TotpEnrollment> startTotpEnrollment();

  /// Finishes enrolment with the authenticator app's [code] for [enrollment].
  Future<void> completeTotpEnrollment({
    required TotpEnrollment enrollment,
    required String code,
  });

  /// Removes an enrolled factor. Firebase may sign the user out afterwards.
  Future<void> unenrollFactor(String factorUid);

  /// Answers an [MfaChallenge] with the authenticator [code], finishing the sign-in or re-auth.
  Future<void> resolveMfa(MfaChallenge challenge, String code);

  /// Signs in with Google; a new account gets a profile with [roleIfNew].
  Future<void> signInWithGoogle({required UserRole roleIfNew});

  /// Saves a provider's "Jobs near you" reference point.
  Future<void> updateBaseLocation({
    required String uid,
    required PickedLocation picked,
  });

  /// Saves the Edit Profile fields; never touches balances, role or Trust Score.
  /// A [picked] location also updates the distance point (provider base or
  /// requestor default); a provider's [category] and [skills] go into `onboarding`.
  Future<void> updateProfile({
    required String uid,
    required String displayName,
    required String? phone,
    required String? location,
    required String? bio,
    bool isProvider = false,
    PickedLocation? picked,
    String? category,
    List<String>? skills,
  });

  /// Persists an avatar download URL (from `DocumentStorageRepository.uploadAvatar`).
  Future<void> updateProfilePhoto({
    required String uid,
    required String photoUrl,
  });

  /// Adds or removes [jobId] on [uid]'s watchlist.
  Future<void> setJobSaved({
    required String uid,
    required String jobId,
    required bool saved,
  });

  Future<void> signOut();

  /// Deletes the Auth account; the `cleanupUserDoc` Cloud Function removes the profile.
  /// A stale session re-authenticates first, with [password] or a fresh Google sign-in.
  Future<void> deleteAccount({String? password});
}

/// What:   Production [AuthRepository].
/// Input:  Firebase Auth (credentials) and Firestore `users/{uid}` (role, wallet, Trust Score).
/// Output: AppUser values and streams; writes the profile docs.
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

  /// Owner+admin-only doc holding the phone number.
  DocumentReference<Map<String, dynamic>> _payoutDoc(String uid) =>
      _users.doc(uid).collection('private').doc('payout');

  /// What:   Reads a user's private payout doc.
  /// Input:  [uid]; `users/{uid}/private/payout`.
  /// Output: The data (holds the phone number); a missing doc or read failure gives null.
  Future<Map<String, dynamic>?> _payoutData(String uid) async {
    try {
      return (await _payoutDoc(uid).get()).data();
    } catch (_) {
      return null;
    }
  }

  @override
  Stream<AppUser?> authStateChanges() {
    // Also re-emits on every profile doc change, so admin approvals show live.
    late final StreamController<AppUser?> controller;
    StreamSubscription<User?>? authSub;
    StreamSubscription<AppUser?>? profileSub;

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
          // Falls back to a minimal user so a read error never strands the splash
          // screen; asyncMap re-reads the private payout doc for the phone.
          profileSub = _users
              .doc(user.uid)
              .snapshots()
              .asyncMap((snapshot) async => _mapUser(
                    // reload() swaps in a new currentUser; prefer it.
                    _auth.currentUser ?? user,
                    snapshot.data(),
                    await _payoutData(user.uid),
                  ))
              .listen(emit, onError: (_) => emit(_fallbackUser(user)));
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
  Future<void> sendEmailVerification() {
    // No ActionCodeSettings: the default link opens Firebase's hosted page.
    return _guard(() async {
      await _auth.currentUser?.sendEmailVerification();
    });
  }

  @override
  Future<bool> reloadUser() async {
    final user = _auth.currentUser;
    if (user == null) return false;
    try {
      await user.reload();
      // reload() swaps in a new currentUser, so `user.emailVerified` is stale.
      final refreshed = _auth.currentUser;
      final verified = refreshed?.emailVerified ?? false;
      // The ID token isn't refreshed by reload(); rules would see the old claim.
      if (verified) await refreshed?.getIdToken(true);
      return verified;
    } on FirebaseAuthException catch (e) {
      throw AuthException.fromFirebase(e);
    }
  }

  @override
  Future<void> reauthenticate({String? password}) {
    return _guard(() async {
      final user = _auth.currentUser;
      if (user == null) {
        throw const AuthException('Please sign in again to continue.');
      }
      await _reauthenticate(user, password);
    });
  }

  @override
  Future<List<MfaFactor>> enrolledFactors() {
    return _guardValue(() async {
      final user = _auth.currentUser;
      if (user == null) return const <MfaFactor>[];
      final factors = await user.multiFactor.getEnrolledFactors();
      return factors.map(_toFactor).toList();
    });
  }

  @override
  Future<TotpEnrollment> startTotpEnrollment() {
    return _guardValue(() async {
      final user = _auth.currentUser!;
      final session = await user.multiFactor.getSession();
      final secret = await TotpMultiFactorGenerator.generateSecret(session);
      final url = await secret.generateQrCodeUrl(
        accountName: user.email ?? user.uid,
        issuer: 'FairBid',
      );
      return TotpEnrollment(
        secretKey: secret.secretKey,
        qrCodeUrl: url,
        handle: secret,
      );
    });
  }

  @override
  Future<void> completeTotpEnrollment({
    required TotpEnrollment enrollment,
    required String code,
  }) {
    return _guard(() async {
      final assertion = await TotpMultiFactorGenerator.getAssertionForEnrollment(
        enrollment.handle as TotpSecret,
        code,
      );
      // TOTP requires a displayName; it shows in the sign-in hints.
      await _auth.currentUser!.multiFactor.enroll(assertion, displayName: 'Authenticator app');
    });
  }

  @override
  Future<void> unenrollFactor(String factorUid) {
    return _guard(() => _auth.currentUser!.multiFactor.unenroll(
          factorUid: factorUid,
        ));
  }

  @override
  Future<void> resolveMfa(MfaChallenge challenge, String code) {
    return _guard(() async {
      final resolver = challenge.resolver as MultiFactorResolver;
      // Filter by factorId, not hints.first - SMS would silently pick wrong.
      final hint = resolver.hints.firstWhere((h) => h.factorId == 'totp');
      final assertion =
          await TotpMultiFactorGenerator.getAssertionForSignIn(hint.uid, code);
      await resolver.resolveSignIn(assertion);
    });
  }

  MfaFactor _toFactor(MultiFactorInfo info) => MfaFactor(uid: info.uid);

  // e.resolver allocates a new wrapper each call - read it once.
  MfaChallenge _toChallenge(FirebaseAuthMultiFactorException e) =>
      MfaChallenge(resolver: e.resolver);

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
        await _ensureProfile(user, role, displayName.trim());
        // A mail failure must not roll back a good account (the banner offers a resend).
        await user.sendEmailVerification().catchError((_) {});
      } catch (_) {
        // Roll back so the email is free to retry and no account lacks a profile.
        await user.delete().catchError((_) {});
        rethrow;
      }
    });
  }

  /// google_sign_in 7.x needs one initialize() call; a failed attempt is cleared to retry.
  Future<void>? _googleInit;
  Future<void> get _googleReady => _googleInit ??= GoogleSignIn.instance
      .initialize(serverClientId: googleServerClientId)
      .catchError((Object e) {
    _googleInit = null;
    throw e;
  });

  @override
  Future<void> signInWithGoogle({required UserRole roleIfNew}) {
    return _guard(() async {
      final (googleUser, credential) = await _googleCredential();
      final userCredential = await _auth.signInWithCredential(credential);
      final user = userCredential.user!;
      final displayName = _googleDisplayName(googleUser, userCredential);
      // Keep User.displayName in step with the name we settled on.
      if ((user.displayName ?? '').trim().isEmpty) {
        await user.updateDisplayName(displayName).catchError((_) {});
      }
      await _ensureProfile(user, roleIfNew, displayName);
    });
  }

  /// What:   Runs the interactive Google sign-in.
  /// Input:  GoogleSignIn.instance (google_sign_in 7.x).
  /// Output: The Google account with its Firebase credential; AuthException if unsupported or no token.
  Future<(GoogleSignInAccount, AuthCredential)> _googleCredential() async {
    await _googleReady;
    final signIn = GoogleSignIn.instance;
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
    return (googleUser, GoogleAuthProvider.credential(idToken: idToken));
  }

  /// What:   The best name available for a Google sign-in.
  /// Input:  [googleUser] and the Firebase [userCredential].
  /// Output: First non-empty name from Google, the profile, provider data or the user, else a name from the email.
  /// Notes:  Android's Credential Manager often returns no display name.
  String _googleDisplayName(
    GoogleSignInAccount googleUser,
    UserCredential userCredential,
  ) {
    final user = userCredential.user!;
    final profileName = userCredential.additionalUserInfo?.profile?['name'];
    final candidates = <String?>[
      googleUser.displayName,
      profileName is String ? profileName : null,
      for (final provider in user.providerData) provider.displayName,
      user.displayName,
    ];
    for (final candidate in candidates) {
      final name = candidate?.trim() ?? '';
      if (name.isNotEmpty) return name;
    }
    return _nameFromEmail(googleUser.email);
  }

  /// What:   A display name from an email's local part.
  /// Input:  [email], e.g. `siti.rahman@gmail.com`.
  /// Output: Capitalised words split on . _ - (here `Siti Rahman`), or "User" when empty.
  String _nameFromEmail(String? email) {
    final local = (email ?? '').split('@').first.split('+').first;
    final words = local
        .split(RegExp(r'[._\-]+'))
        .where((word) => word.isNotEmpty)
        .map((word) => word[0].toUpperCase() + word.substring(1));
    return words.isEmpty ? 'User' : words.join(' ');
  }

  @override
  Future<void> updateBaseLocation({
    required String uid,
    required PickedLocation picked,
  }) =>
      _users.doc(uid).set(_baseFields(picked), SetOptions(merge: true));

  /// What:   The provider "Jobs near you" fields.
  /// Input:  [p], a PickedLocation.
  /// Output: Map with baseLat, baseLng, baseAddress, baseDistrictCode and baseTown.
  static Map<String, Object?> _baseFields(PickedLocation p) => {
        'baseLat': p.lat,
        'baseLng': p.lng,
        'baseAddress': p.address,
        'baseDistrictCode': p.region.districtCode,
        'baseTown': p.region.town,
      };

  @override
  Future<void> updateProfile({
    required String uid,
    required String displayName,
    required String? phone,
    required String? location,
    required String? bio,
    bool isProvider = false,
    PickedLocation? picked,
    String? category,
    List<String>? skills,
  }) {
    // The phone lives in private/payout; delete any legacy public copy.
    final batch = _firestore.batch()
      ..set(_users.doc(uid), {
        'displayName': displayName.trim(),
        'location': location?.trim(),
        'bio': bio?.trim(),
        'phone': FieldValue.delete(),
        if (picked != null && !isProvider) ...{
          'lat': picked.lat,
          'lng': picked.lng,
          'districtCode': picked.region.districtCode,
          'town': picked.region.town,
        },
        if (picked != null && isProvider) ..._baseFields(picked),
        // Merged into the existing onboarding map.
        if (isProvider &&
            (picked != null || category != null || skills != null))
          'onboarding': {
            if (picked != null) ...{
              'coverageArea': picked.address,
              'districtCode': picked.region.districtCode,
              'town': picked.region.town,
              'lat': picked.lat,
              'lng': picked.lng,
            },
            'category': ?category,
            'skills': ?skills,
          },
      }, SetOptions(merge: true))
      ..set(_payoutDoc(uid), {
        'phone': phone?.trim(),
      }, SetOptions(merge: true));
    return batch.commit();
  }

  @override
  Future<void> updateProfilePhoto({
    required String uid,
    required String photoUrl,
  }) {
    return _users.doc(uid).set({
      'profilePhotoUrl': photoUrl,
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
    // Sign out of Google too so the next login prompts again; its failure must not block.
    try {
      await _googleReady;
      await GoogleSignIn.instance.signOut();
    } catch (_) {}
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

  /// What:   Re-proves the user's identity for account deletion, 2FA or withdrawal.
  /// Input:  [user]; [password] for email/password accounts, otherwise a fresh Google sign-in.
  /// Output: Completes on success; AuthException if the password is missing or Google is cancelled.
  Future<void> _reauthenticate(User user, String? password) async {
    if (_isPasswordAccount(user)) {
      final email = user.email;
      if (email == null || password == null || password.isEmpty) {
        throw const AuthException(
            'Please enter your password to continue.');
      }
      await user.reauthenticateWithCredential(
        EmailAuthProvider.credential(email: email, password: password),
      );
      return;
    }

    final AuthCredential credential;
    try {
      credential = (await _googleCredential()).$2;
    } on GoogleSignInException catch (e) {
      if (e.code != GoogleSignInExceptionCode.canceled) rethrow;
      throw const AuthException('Google confirmation was cancelled.');
    }
    await user.reauthenticateWithCredential(credential);
  }

  /// What:   Creates the profile doc on first sign-in only.
  /// Input:  [user], [role] and [displayName].
  /// Output: Writes role, name, email and zeroed wallet fields; an existing profile keeps its role and balance.
  /// Notes:  No trust fields are written: rules reject them and `recomputeTrustOnUserWrite` seeds the score.
  Future<void> _ensureProfile(
    User user,
    UserRole role,
    String displayName,
  ) async {
    final doc = _users.doc(user.uid);
    final snapshot = await doc.get();
    if (snapshot.exists) {
      await _healEmailAsDisplayName(doc, snapshot, user, displayName);
      return;
    }

    // No trust fields: rules reject them; `recomputeTrustOnUserWrite` seeds the score.
    await doc.set({
      'role': role.name,
      'displayName':
          displayName.isEmpty ? _nameFromEmail(user.email) : displayName,
      'email': user.email,
      'walletBalanceSen': 0,
      'verificationStatus': 'none',
      'onboardingComplete': false,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  /// What:   Repairs a stored name that is still the bare email.
  /// Input:  The profile [doc] and [snapshot], the [user] and the better [displayName].
  /// Output: Replaces an empty or email-only name; never overwrites a chosen name.
  /// Notes:  Errors are swallowed: rules deny suspended accounts and a cosmetic repair must not fail the sign-in.
  Future<void> _healEmailAsDisplayName(
    DocumentReference<Map<String, dynamic>> doc,
    DocumentSnapshot<Map<String, dynamic>> snapshot,
    User user,
    String displayName,
  ) async {
    final stored = (snapshot.data()?['displayName'] as String? ?? '').trim();
    final email = (user.email ?? '').trim();
    final isEmailAsName = email.isNotEmpty &&
        stored.toLowerCase() == email.toLowerCase();
    if (stored.isNotEmpty && !isEmailAsName) return;
    if (displayName.isEmpty || displayName == stored) return;
    // Rules deny suspended accounts; a cosmetic repair must not fail the sign-in.
    await doc
        .set({'displayName': displayName}, SetOptions(merge: true))
        .catchError((_) {});
  }

  /// What:   Reads the signed-in user's profile once.
  /// Input:  [user] from Firebase Auth; `users/{uid}` and its private payout doc.
  /// Output: An AppUser, null when signed out, or a minimal one if the profile is unreadable (so the splash cannot hang).
  Future<AppUser?> _toAppUser(User? user) async {
    if (user == null) return null;
    try {
      final snapshot = await _users.doc(user.uid).get();
      return _mapUser(user, snapshot.data(), await _payoutData(user.uid));
    } on FirebaseException {
      // Unreadable profile (offline): fall back so the splash screen can't hang.
      return _fallbackUser(user);
    }
  }

  /// What:   Maps Firebase user and Firestore data into an [AppUser].
  /// Input:  [user]; profile [data] and private [payoutData], either may be null.
  /// Output: AppUser with defaults for missing fields.
  /// How:    Phone comes from the private doc, falling back to the legacy public field; base location falls back to the onboarding service location so "Jobs near you" works at once.
  AppUser _mapUser(
    User user,
    Map<String, dynamic>? data,
    Map<String, dynamic>? payoutData,
  ) {
    final onboarding = data?['onboarding'] as Map<String, dynamic>?;
    // The phone lives in private/payout; legacy accounts still have it public.
    return AppUser(
      uid: user.uid,
      email: user.email,
      displayName:
          data?['displayName'] as String? ?? user.displayName ?? user.email,
      role: UserRole.fromStorage(data?['role'] as String?),
      verificationStatus: data?['verificationStatus'] as String? ?? 'none',
      onboardingComplete: data?['onboardingComplete'] as bool? ?? false,
      trustScore: (data?['trustScore'] as num?)?.toInt() ?? 0,
      phone: (payoutData?['phone'] ?? data?['phone']) as String?,
      location: data?['location'] as String?,
      // Falls back to the onboarding service location so "Jobs near you" works at once.
      baseLat: ((data?['baseLat'] ?? onboarding?['lat']) as num?)?.toDouble(),
      baseLng: ((data?['baseLng'] ?? onboarding?['lng']) as num?)?.toDouble(),
      baseDistrictCode: data?['baseDistrictCode'] as String?,
      baseTown: data?['baseTown'] as String?,
      defaultLat: (data?['lat'] as num?)?.toDouble(),
      defaultLng: (data?['lng'] as num?)?.toDouble(),
      defaultDistrictCode: data?['districtCode'] as String?,
      defaultTown: data?['town'] as String?,
      bio: data?['bio'] as String?,
      walletBalanceSen: (data?['walletBalanceSen'] as num?)?.toInt() ?? 0,
      ratingCount: (data?['ratingCount'] as num?)?.toInt() ?? 0,
      ratingSum: (data?['ratingSum'] as num?)?.toInt() ?? 0,
      jobsCompleted: (data?['jobsCompleted'] as num?)?.toInt() ?? 0,
      trustBreakdown: data?['trust'] == null
          ? null
          : TrustBreakdown.fromMap(data!['trust'] as Map<String, dynamic>),
      profilePhotoUrl: data?['profilePhotoUrl'] as String?,
      providerType: onboarding?['providerType'] as String?,
      category: onboarding?['category'] as String?,
      skills: (onboarding?['skills'] as List?)?.whereType<String>().toList() ??
          const [],
      isPasswordAccount: _isPasswordAccount(user),
      emailVerified: user.emailVerified,
      watchlist:
          (data?['watchlist'] as List?)?.whereType<String>().toList() ??
              const [],
      suspended: data?['suspended'] as bool? ?? false,
      suspensionReason: data?['suspensionReason'] as String?,
    );
  }

  /// What:   A minimal user built from Firebase Auth alone.
  /// Input:  [user].
  /// Output: A requestor AppUser, used when the profile cannot be read.
  AppUser _fallbackUser(User user) => AppUser(
        uid: user.uid,
        email: user.email,
        displayName: user.displayName ?? user.email,
        role: UserRole.requestor,
        isPasswordAccount: _isPasswordAccount(user),
        emailVerified: user.emailVerified,
      );

  bool _isPasswordAccount(User user) =>
      user.providerData.any((p) => p.providerId == 'password');

  /// What:   [_guardValue] for void calls, also handling Google sign-in errors.
  /// Input:  [action], a Firebase call.
  /// Output: Runs it; closing the Google sheet is silent, other Google failures become AuthException.
  Future<void> _guard(Future<void> Function() action) => _guardValue(() async {
        try {
          await action();
        } on GoogleSignInException catch (e) {
          // Closing the Google sheet is not worth an error.
          if (e.code == GoogleSignInExceptionCode.canceled) return;
          final detail = e.description?.trim();
          throw AuthException(
            'Google sign-in failed (${e.code.name})'
            '${detail == null || detail.isEmpty ? '' : ': $detail'}.',
          );
        }
      });

  /// What:   Runs a Firebase call and converts its failures into user-friendly errors.
  /// Input:  [action], a Firebase call.
  /// Output: The call's result, or MfaRequiredException / AuthException.
  /// Notes:  The multi-factor catch must precede FirebaseAuthException (its superclass) or the resolver is lost.
  Future<T> _guardValue<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on FirebaseAuthMultiFactorException catch (e) {
      // Must precede FirebaseAuthException (its superclass) or the resolver is lost.
      throw MfaRequiredException(_toChallenge(e));
    } on FirebaseAuthException catch (e) {
      throw AuthException.fromFirebase(e);
    } on FirebaseException catch (e) {
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
