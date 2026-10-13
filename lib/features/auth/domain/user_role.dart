/// What:   The role a person signs up as; routes them to the right home.
/// Input:  `role` on `users/{uid}`.
/// Output: Enum; `admin` is never chosen at registration (set in the Firebase console).
enum UserRole {
  requestor,
  provider,
  admin;

  String get label => switch (this) {
        UserRole.requestor => 'Requestor',
        UserRole.provider => 'Service Provider',
        UserRole.admin => 'Admin',
      };

  /// Parses the stored `name`; unknown values become requestor.
  static UserRole fromStorage(String? value) =>
      values.asNameMap()[value] ?? UserRole.requestor;
}
