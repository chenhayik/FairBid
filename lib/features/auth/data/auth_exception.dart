import 'package:firebase_auth/firebase_auth.dart';

/// What:   Auth error whose [message] is safe to show the user.
/// Input:  Thrown by FirebaseAuthRepository; [AuthException.fromFirebase] maps Firebase codes.
/// Output: [message] shown by screens and AuthController.errorMessage.
class AuthException implements Exception {
  const AuthException(this.message);

  final String message;

  factory AuthException.fromFirebase(FirebaseAuthException e) {
    // Android reports an expired TOTP challenge as code 'unknown'.
    if (e.message?.contains('TOTP_CHALLENGE_TIMEOUT') ?? false) {
      return const AuthException(
          'That took too long. Please sign in again.');
    }
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
      'requires-recent-login' => 'Please confirm your password to continue.',
      'user-mismatch' => 'Those credentials belong to a different account.',
      'invalid-verification-code' =>
        'That code is incorrect. Check your authenticator app and try again.',
      'second-factor-already-in-use' =>
        'Two-factor authentication is already set up on this account.',
      'maximum-second-factor-count-exceeded' =>
        'You have reached the maximum number of second factors.',
      'unverified-email' =>
        'Verify your email address before turning on two-factor '
            'authentication.',
      'multi-factor-info-not-found' =>
        'That second factor is no longer enrolled.',
      _ => 'Something went wrong. Please try again.',
    };
    return AuthException(message);
  }

  @override
  String toString() => message;
}
