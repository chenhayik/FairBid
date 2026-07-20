/// Simple, reusable form validators shared by the auth and onboarding forms.
/// Each returns `null` when valid or an error message when not.
class Validators {
  const Validators._();

  static String? email(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return 'Email is required.';
    // Good-enough email shape check; Firebase does the authoritative check.
    final looksLikeEmail = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(text);
    if (!looksLikeEmail) return 'Invalid email format';
    return null;
  }

  static String? password(String? value) {
    final text = value ?? '';
    if (text.isEmpty) return 'Password is required.';
    if (text.length < 8) return 'Must be at least 8 characters.';
    return null;
  }

  static String? required(String? value, String fieldName) {
    if ((value?.trim() ?? '').isEmpty) return '$fieldName is required.';
    return null;
  }

  /// Confirms a second field matches the [original] password.
  static String? confirmPassword(String? value, String original) {
    if (value != original) return 'Passwords do not match.';
    return null;
  }
}
