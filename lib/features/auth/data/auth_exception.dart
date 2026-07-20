import 'package:firebase_auth/firebase_auth.dart';

/// An authentication error with a message that is safe to show the user.
///
/// Firebase throws [FirebaseAuthException] with terse codes like
/// `wrong-password`. [AuthException.fromFirebase] turns those codes into short,
/// friendly sentences so every screen can display errors the same way.
class AuthException implements Exception {
  const AuthException(this.message);

  final String message;

  factory AuthException.fromFirebase(FirebaseAuthException e) {
    final message = switch (e.code) {
      'invalid-email' => 'That email address looks invalid.',
      'user-disabled' => 'This account has been disabled.',
      'user-not-found' ||
      'wrong-password' ||
      'invalid-credential' =>
        'Incorrect email or password.',
      'email-already-in-use' => 'An account already exists for that email.',
      'weak-password' => 'Please choose a stronger password (8+ characters).',
      'operation-not-allowed' =>
        'This sign-in method is not enabled for the project.',
      'network-request-failed' =>
        'Network error. Check your connection and try again.',
      'too-many-requests' => 'Too many attempts. Please try again later.',
      'account-exists-with-different-credential' =>
        'That email is already linked to a different sign-in method.',
      _ => 'Something went wrong. Please try again.',
    };
    return AuthException(message);
  }

  @override
  String toString() => message;
}
