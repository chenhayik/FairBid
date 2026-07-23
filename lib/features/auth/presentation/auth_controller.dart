import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/auth_exception.dart';
import '../data/auth_repository.dart';
import '../domain/app_user.dart';
import '../domain/user_role.dart';

/// Holds authentication state for the whole app and exposes the sign-in /
/// register / sign-out actions the screens call. (The "ViewModel" of the auth
/// feature.)
///
/// It is a [ChangeNotifier] so widgets can `watch` it for the busy spinner and
/// error text, and so go_router can refresh its redirects when the user signs
/// in or out.
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

  /// The signed-in user, or `null` when signed out.
  AppUser? get user => _user;

  /// True until the first auth state is known (used to show a splash screen).
  bool get isInitializing => _initializing;

  /// True while a sign-in / register / sign-out call is in flight.
  bool get isBusy => _busy;

  /// The last error message, or `null`. Cleared when a new action starts.
  String? get errorMessage => _errorMessage;

  bool get isSignedIn => _user != null;

  /// Runs just before sign-out, while the session is still authenticated —
  /// the app wires this to detach the device's push token so the next account
  /// on this device can't receive the previous user's notifications.
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

  Future<void> signOut() => _run(() async {
        final uid = _user?.uid;
        final hook = onBeforeSignOut;
        if (uid != null && hook != null) {
          try {
            await hook(uid);
          } catch (_) {
            // Best-effort: a failed token detach must never block sign-out.
          }
        }
        await _repository.signOut();
      });

  /// Permanently deletes the signed-in account. Returns `false` with
  /// [errorMessage] set (e.g. a wrong/missing password) if it fails.
  Future<bool> deleteAccount({String? password}) =>
      _run(() => _repository.deleteAccount(password: password));

  /// Re-reads the profile after something else (e.g. onboarding) changed it,
  /// so router redirects react to the new state.
  Future<void> refreshUser() async {
    _user = await _repository.currentUser();
    notifyListeners();
  }

  /// Saves the provider's "Jobs near you" reference point, then refreshes.
  Future<void> setBaseLocation(double lat, double lng, String address) async {
    final uid = _user?.uid;
    if (uid == null) return;
    await _repository.updateBaseLocation(
        uid: uid, lat: lat, lng: lng, address: address);
    await refreshUser();
  }

  /// Saves the editable profile fields (Edit Profile screen), then refreshes so
  /// the profile reflects the new values immediately.
  Future<void> updateProfile({
    required String displayName,
    String? phone,
    String? location,
    String? bio,
  }) async {
    final uid = _user?.uid;
    if (uid == null) return;
    await _repository.updateProfile(
      uid: uid,
      displayName: displayName,
      phone: phone,
      location: location,
      bio: bio,
    );
    await refreshUser();
  }

  /// Toggles whether [jobId] is on the signed-in user's watchlist (the
  /// bookmark on a job card), then refreshes so the change reflects
  /// immediately. No-ops when signed out.
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

  /// Clears the visible error (e.g. when switching screens).
  void clearError() {
    if (_errorMessage == null) return;
    _errorMessage = null;
    notifyListeners();
  }

  /// Runs an auth [action] while managing the busy flag and error message.
  /// Returns `true` on success so screens can react (e.g. navigate).
  Future<bool> _run(Future<void> Function() action) async {
    _busy = true;
    _errorMessage = null;
    notifyListeners();
    try {
      await action();
      return true;
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
