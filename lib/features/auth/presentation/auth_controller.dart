import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/location/region.dart';
import '../data/auth_exception.dart';
import '../data/auth_repository.dart';
import '../domain/app_user.dart';
import '../domain/mfa.dart';
import '../domain/user_role.dart';

/// What:   App-wide auth state and the sign-in / register / sign-out actions.
/// Input:  [AuthRepository.authStateChanges] and its action methods.
/// Output: Notifies listeners (busy spinner, error text, router redirects) on every change.
class AuthController extends ChangeNotifier {
  AuthController(this._repository) {
    _subscription = _repository.authStateChanges().listen((user) {
      _user = user;
      _initializing = false;
      notifyListeners();
    });
  }

  final AuthRepository _repository;
  late final StreamSubscription<AppUser?> _subscription;

  AppUser? _user;
  bool _initializing = true;
  bool _busy = false;
  String? _errorMessage;

  AppUser? get user => _user;

  /// True until the first auth state is known (the splash screen shows).
  bool get isInitializing => _initializing;

  bool get isBusy => _busy;

  /// The last error message; cleared when a new action starts.
  String? get errorMessage => _errorMessage;

  /// Runs just before sign-out while still authenticated; detaches the device's push token.
  Future<void> Function(String uid)? onBeforeSignOut;

  Future<bool> signInWithEmail(String email, String password) {
    return _run(() =>
        _repository.signInWithEmail(email: email, password: password));
  }

  Future<bool> register({
    required String email,
    required String password,
    required String displayName,
    required UserRole role,
  }) {
    return _run(() => _repository.registerWithEmail(
          email: email,
          password: password,
          displayName: displayName,
          role: role,
        ));
  }

  Future<bool> signInWithGoogle({required UserRole roleIfNew}) {
    return _run(() => _repository.signInWithGoogle(roleIfNew: roleIfNew));
  }

  /// Sends a password-reset email to [email].
  Future<bool> sendPasswordReset(String email) {
    return _run(() => _repository.sendPasswordReset(email));
  }

  /// Sends (or re-sends) the verification email.
  Future<bool> sendEmailVerification() =>
      _run(() => _repository.sendEmailVerification());

  /// Checks whether the email is verified and refreshes [user]. Skips [_run] and
  /// swallows errors: it fires on every app resume and a failure just keeps the banner.
  Future<bool> refreshEmailVerified() async {
    try {
      final verified = await _repository.reloadUser();
      await refreshUser();
      return verified;
    } catch (_) {
      return _user?.emailVerified ?? false;
    }
  }

  /// Re-proves the user's identity before a sensitive action.
  Future<bool> reauthenticate({String? password}) =>
      _run(() => _repository.reauthenticate(password: password));

  /// Set when a sign-in or re-auth needs a second factor; see [takePendingChallenge].
  MfaChallenge? _pendingChallenge;

  /// Reads and clears the pending challenge so it is handled once.
  MfaChallenge? takePendingChallenge() {
    final challenge = _pendingChallenge;
    _pendingChallenge = null;
    return challenge;
  }

  Future<List<MfaFactor>> enrolledFactors() => _repository.enrolledFactors();

  /// Starts TOTP enrolment; throws [AuthException] so the setup sheet shows it inline.
  Future<TotpEnrollment> startTotpEnrollment() =>
      _repository.startTotpEnrollment();

  Future<bool> completeTotpEnrollment({
    required TotpEnrollment enrollment,
    required String code,
  }) =>
      _run(() => _repository.completeTotpEnrollment(
            enrollment: enrollment,
            code: code,
          ));

  Future<bool> unenrollFactor(String factorUid) =>
      _run(() => _repository.unenrollFactor(factorUid));

  /// Answers an MFA challenge; false with [errorMessage] on a wrong or expired code.
  Future<bool> submitMfaCode(MfaChallenge challenge, String code) =>
      _run(() => _repository.resolveMfa(challenge, code));

  Future<void> signOut() => _run(() async {
        final uid = _user?.uid;
        final hook = onBeforeSignOut;
        if (uid != null && hook != null) {
          try {
            await hook(uid);
          } catch (_) {}
        }
        await _repository.signOut();
      });

  /// Deletes the signed-in account; false with [errorMessage] on failure.
  Future<bool> deleteAccount({String? password}) =>
      _run(() => _repository.deleteAccount(password: password));

  /// Re-reads the profile so router redirects react to changes made elsewhere.
  Future<void> refreshUser() async {
    _user = await _repository.currentUser();
    notifyListeners();
  }

  /// Saves the provider's "Jobs near you" point, then refreshes.
  Future<void> setBaseLocation(PickedLocation picked) async {
    final uid = _user?.uid;
    if (uid == null) return;
    await _repository.updateBaseLocation(uid: uid, picked: picked);
    await refreshUser();
  }

  /// Saves the Edit Profile fields, then refreshes.
  Future<void> updateProfile({
    required String displayName,
    String? phone,
    String? location,
    String? bio,
    PickedLocation? picked,
    String? category,
    List<String>? skills,
  }) async {
    final user = _user;
    if (user == null) return;
    await _repository.updateProfile(
      uid: user.uid,
      displayName: displayName,
      phone: phone,
      location: location,
      bio: bio,
      isProvider: user.role == UserRole.provider,
      picked: picked,
      category: category,
      skills: skills,
    );
    await refreshUser();
  }

  /// Saves the avatar URL, then refreshes. No-op when signed out.
  Future<void> updateProfilePhoto(String photoUrl) async {
    final uid = _user?.uid;
    if (uid == null) return;
    await _repository.updateProfilePhoto(uid: uid, photoUrl: photoUrl);
    await refreshUser();
  }

  /// Toggles [jobId] on the watchlist, then refreshes. No-op when signed out.
  Future<void> toggleSaved(String jobId) async {
    final user = _user;
    if (user == null) return;
    await _repository.setJobSaved(
      uid: user.uid,
      jobId: jobId,
      saved: !user.isSaved(jobId),
    );
    await refreshUser();
  }

  void clearError() {
    if (_errorMessage == null) return;
    _errorMessage = null;
    notifyListeners();
  }

  /// Runs [action] with the busy flag and error message; true on success.
  Future<bool> _run(Future<void> Function() action) async {
    _busy = true;
    _errorMessage = null;
    notifyListeners();
    try {
      await action();
      return true;
    } on MfaRequiredException catch (e) {
      // Not an error: the caller prompts for the code and retries.
      _pendingChallenge = e.challenge;
      return false;
    } on AuthException catch (e) {
      _errorMessage = e.message;
      return false;
    } catch (_) {
      _errorMessage = 'Something went wrong. Please try again.';
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}
