/// What:   Form validators shared by the auth and onboarding forms.
/// Input:  The field text.
/// Output: `null` when valid, else the error message.
class Validators {
  const Validators._();

  static String? email(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return 'Email is required.';
    // Shape check only; Firebase validates authoritatively.
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

  static String? confirmPassword(String? value, String original) {
    if (value != original) return 'Passwords do not match.';
    return null;
  }
}
