import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../../../core/config/platform_config.dart';
import '../domain/app_user.dart';
import '../domain/mfa.dart';
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

  /// Sends the "verify your email" message to the signed-in user's address.
  Future<void> sendEmailVerification();

  /// Re-reads the account from Firebase and reports whether the email is now
  /// verified. Firebase pushes nothing when the link is clicked, so the app
  /// has to ask.
  Future<bool> reloadUser();

  /// Re-proves the signed-in user's identity before a sensitive action.
  /// [password] is required for email/password accounts; ignored for Google.
  Future<void> reauthenticate({String? password});

  /// The second factors enrolled on the signed-in account (empty when none).
  Future<List<MfaFactor>> enrolledFactors();

  /// Starts TOTP enrolment. Requires a verified email and a recent login -
  /// call [reauthenticate] first.
  Future<TotpEnrollment> startTotpEnrollment();

  /// Finishes enrolment by proving the user's authenticator app produced
  /// [code] from [enrollment].
  Future<void> completeTotpEnrollment({
    required TotpEnrollment enrollment,
    required String code,
    required String label,
  });

  /// Removes an enrolled factor. Firebase may sign the user out afterwards.
  Future<void> unenrollFactor(String factorUid);

  /// Answers an [MfaChallenge] with the code from the authenticator app,
  /// completing the sign-in or re-auth that raised it.
  Future<void> resolveMfa(MfaChallenge challenge, String code);

  /// Signs in with Google. If this is a brand-new account, a profile is created
  /// using [roleIfNew]; existing accounts keep their stored role.
  Future<void> signInWithGoogle({required UserRole roleIfNew});

  /// Saves a provider's reference point for "Jobs near you". [districtCode]
  /// is one of Penang's 5 districts (see `Region`); [town] is optional.
  Future<void> updateBaseLocation({
    required String uid,
    required double lat,
    required double lng,
    required String address,
    required String districtCode,
    String? town,
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

  /// Saves the signed-in user's avatar URL (Edit Profile screen's photo
  /// control). Uploading the file itself is handled by
  /// `DocumentStorageRepository.uploadAvatar`; this just persists the
  /// resulting download URL onto the profile.
  Future<void> updateProfilePhoto({
    required String uid,
    required String photoUrl,
  });

  /// Toggles whether [jobId] is on [uid]'s watchlist (the bookmark on a job
  /// card / feed / "Jobs near you"). Not a protected field - the self-update
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

  /// Owner+admin-only doc holding payout bank details and the phone number -
  /// see `firestore.rules`' `private/{doc}` block. Shared by both onboarding
  /// flows and [updateProfile].
  DocumentReference<Map<String, dynamic>> _payoutDoc(String uid) =>
      _users.doc(uid).collection('private').doc('payout');

  /// Best-effort read of [uid]'s private payout doc: a missing doc (every
  /// legacy user who hasn't saved since the migration) or a read failure
  /// degrades to `null`, never throws - the caller falls back to the legacy
  /// public-doc locations for those fields.
  Future<Map<String, dynamic>?> _payoutData(String uid) async {
    try {
      return (await _payoutDoc(uid).get()).data();
    } catch (_) {
      return null;
    }
  }

  @override
  Stream<AppUser?> authStateChanges() {
    // Re-emit not only when the Firebase Auth state changes (sign in/out), but
    // also whenever the signed-in user's Firestore profile changes - so an
    // admin approving their verification, or any other profile edit, reflects
    // live in the app without forcing a re-login.
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
          // Live-watch the profile doc; fall back to a minimal user if it
          // can't be read so the app never gets stuck on the splash screen.
          // Each emission also re-reads the owner-only private payout doc
          // (asyncMap) so phone/bank details stay live too, without a second
          // top-level stream to combine.
          profileSub = _users
              .doc(user.uid)
              .snapshots()
              .asyncMap((snapshot) async => _mapUser(
                    // reload() swaps in a new currentUser; prefer that live
                    // one over the frozen one captured at sign-in.
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
    // No ActionCodeSettings: the default link opens Firebase's own hosted
    // "email verified" page, so no App Links / Hosting config is needed.
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

      // reload() swaps in a new currentUser rather than updating this one,
      // so re-read it - `user.emailVerified` here would still be stale.
      final refreshed = _auth.currentUser;
      final verified = refreshed?.emailVerified ?? false;

      // reload() doesn't refresh the ID token, so `email_verified` would
      // stay false in rules/callables for up to an hour without this.
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
    required String label,
  }) {
    return _guard(() async {
      final assertion = await TotpMultiFactorGenerator.getAssertionForEnrollment(
        enrollment.handle as TotpSecret,
        code,
      );
      // displayName is required for TOTP - shows in the sign-in hints.
      await _auth.currentUser!.multiFactor.enroll(assertion, displayName: label);
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

  MfaFactor _toFactor(MultiFactorInfo info) => MfaFactor(
        uid: info.uid,
        displayName: info.displayName ?? 'Authenticator app',
        // enrollmentTimestamp is seconds since epoch, not milliseconds.
        enrolledAt: DateTime.fromMillisecondsSinceEpoch(
          (info.enrollmentTimestamp * 1000).round(),
        ),
      );

  MfaChallenge _toChallenge(FirebaseAuthMultiFactorException e) {
    // e.resolver allocates a new wrapper each call - read it once.
    final resolver = e.resolver;
    return MfaChallenge(
      hints: resolver.hints.map(_toFactor).toList(),
      resolver: resolver,
    );
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
        await _ensureProfile(user, role, displayName.trim());
        // Best-effort: a mail failure must not roll back a good account, so
        // this deliberately swallows its error (the banner offers a resend).
        await user.sendEmailVerification().catchError((_) {});
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
      final user = userCredential.user!;
      final displayName = _googleDisplayName(googleUser, userCredential);
      // Keep the auth profile in step with the name we settled on, so anything
      // reading `User.displayName` (and the next sign-in) sees it too.
      if ((user.displayName ?? '').trim().isEmpty) {
        await user.updateDisplayName(displayName).catchError((_) {});
      }
      await _ensureProfile(user, roleIfNew, displayName);
    });
  }

  /// The best human name available for a Google sign-in.
  ///
  /// Android's Credential Manager often hands back a credential with no
  /// display name, and Firebase only copies one onto the auth profile when the
  /// ID token carried it, so walk every source before falling back to the
  /// email's local part - showing the whole address as someone's name is the
  /// bug this chain exists to avoid.
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

  /// A readable stand-in built from an email's local part, e.g.
  /// `siti.rahman@gmail.com` -> `Siti Rahman`. Used only when no provider gave
  /// us a real name; still far better than the full address.
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
    required double lat,
    required double lng,
    required String address,
    required String districtCode,
    String? town,
  }) {
    return _users.doc(uid).set({
      'baseLat': lat,
      'baseLng': lng,
      'baseAddress': address,
      'baseDistrictCode': districtCode,
      'baseTown': town,
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
    // Phone moved to the owner+admin-only private/payout doc (it used to sit
    // on the world-readable public profile); write it there and explicitly
    // delete the public copy so legacy accounts migrate as they save. A
    // one-off backfill Cloud Function is still needed for users who never
    // save again - deliberately out of scope here.
    final batch = _firestore.batch()
      ..set(_users.doc(uid), {
        'displayName': displayName.trim(),
        'location': location?.trim(),
        'bio': bio?.trim(),
        'phone': FieldValue.delete(),
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

  /// Writes the Firestore profile only the first time an account appears, so
  /// re-logins never overwrite an existing role or balance - the one exception
  /// being [_healEmailAsDisplayName].
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

    // No trust or rating fields: rules reject them at create, and the
    // `recomputeTrustOnUserWrite` Cloud Function seeds the server-computed
    // Trust Score moments after this write lands.
    await doc.set({
      'role': role.storageValue,
      'displayName':
          displayName.isEmpty ? _nameFromEmail(user.email) : displayName,
      'email': user.email,
      'walletBalanceSen': 0,
      'verificationStatus': 'none',
      'onboardingComplete': false,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  /// Repairs profiles created before [_googleDisplayName] existed, which stored
  /// the email address as the account name. Deliberately narrow: it only writes
  /// when the stored name is still the bare email (or empty), so a name the
  /// user picked themselves is never overwritten.
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
    // Best-effort: the rules deny profile writes to a suspended account, and a
    // cosmetic repair must never turn a good sign-in into an error.
    await doc
        .set({'displayName': displayName}, SetOptions(merge: true))
        .catchError((_) {});
  }

  /// Reads the role from the profile and builds an [AppUser]. Returns `null`
  /// when signed out. Used by [currentUser] for a one-shot read; the live
  /// stream in [authStateChanges] maps snapshots through [_mapUser] directly.
  Future<AppUser?> _toAppUser(User? user) async {
    if (user == null) return null;
    try {
      final snapshot = await _users.doc(user.uid).get();
      return _mapUser(user, snapshot.data(), await _payoutData(user.uid));
    } on FirebaseException {
      // If the profile can't be read (offline, transient error), fall back to a
      // minimal user so the app never gets stuck on the splash screen.
      return _fallbackUser(user);
    }
  }

  /// Builds an [AppUser] from a Firebase auth [user], its Firestore profile
  /// [data] (null when the doc doesn't exist yet, e.g. mid-registration) and
  /// [payoutData], its owner-only private/payout doc (null when missing -
  /// every legacy user who hasn't saved since the migration, or when the read
  /// failed; either way this degrades to nulls rather than throwing).
  AppUser _mapUser(
    User user,
    Map<String, dynamic>? data,
    Map<String, dynamic>? payoutData,
  ) {
    final onboarding = data?['onboarding'] as Map<String, dynamic>?;
    // Payout bank details and phone moved to the private/payout doc; legacy
    // accounts that haven't saved since the migration still carry them on the
    // public doc, so fall back to those locations until the user's next save
    // scrubs them (see updateProfile and the onboarding repositories).
    final accountLast4 = (payoutData?['accountLast4'] ??
        onboarding?['accountLast4']) as String?;
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
      // A provider who never picked a base in the feed still has the service
      // location from onboarding, so "Jobs near you" works from day one.
      baseLat: ((data?['baseLat'] ?? onboarding?['lat']) as num?)?.toDouble(),
      baseLng: ((data?['baseLng'] ?? onboarding?['lng']) as num?)?.toDouble(),
      baseAddress: data?['baseAddress'] as String?,
      baseDistrictCode: data?['baseDistrictCode'] as String?,
      baseTown: data?['baseTown'] as String?,
      defaultLat: (data?['lat'] as num?)?.toDouble(),
      defaultLng: (data?['lng'] as num?)?.toDouble(),
      defaultDistrictCode: data?['districtCode'] as String?,
      defaultTown: data?['town'] as String?,
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
      payoutBankName:
          (payoutData?['bankName'] ?? onboarding?['bankName']) as String?,
      payoutAccountLast4:
          accountLast4 == null || accountLast4.isEmpty ? null : accountLast4,
      isPasswordAccount: _isPasswordAccount(user),
      emailVerified: user.emailVerified,
      watchlist:
          (data?['watchlist'] as List?)?.whereType<String>().toList() ??
              const [],
      suspended: data?['suspended'] as bool? ?? false,
      suspensionReason: data?['suspensionReason'] as String?,
    );
  }

  /// A minimal user built from auth alone, used when the profile can't be read.
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

  /// Runs a Firebase call and rethrows failures as user-friendly
  /// [AuthException]s.
  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } on FirebaseAuthMultiFactorException catch (e) {
      // Must precede FirebaseAuthException - it's a subclass, and the
      // resolver is lost if the generic clause swallows it.
      throw MfaRequiredException(_toChallenge(e));
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

  /// [_guard] for calls that return a value. No GoogleSignInException clause
  /// - none of its callers touch Google sign-in.
  Future<T> _guardValue<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on FirebaseAuthMultiFactorException catch (e) {
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
