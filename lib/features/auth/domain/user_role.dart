/// The role a person signs up as. Stored on their `users/{uid}` profile and
/// used to route them to the correct home experience after login.
///
/// `admin` is never chosen during registration - admins are created manually
/// in the Firebase console (see the technical plan, §3.1.1).
enum UserRole {
  requestor,
  provider,
  admin;

  /// Human-readable label shown in the UI.
  String get label => switch (this) {
        UserRole.requestor => 'Requestor',
        UserRole.provider => 'Service Provider',
        UserRole.admin => 'Admin',
      };

  /// The value written to / read from Firestore.
  String get storageValue => name;

  /// Parses the value stored in Firestore back into a role.
  static UserRole fromStorage(String? value) => UserRole.values.firstWhere(
        (role) => role.name == value,
        orElse: () => UserRole.requestor,
      );
}
