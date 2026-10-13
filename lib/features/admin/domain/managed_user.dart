/// What:   A user row in the admin Users list.
/// Input:  `users/{uid}` data via ManagedUser.fromMap (user_admin_repository.dart).
/// Output: Identity and status fields only, nothing sensitive.
class ManagedUser {
  const ManagedUser({
    required this.uid,
    required this.displayName,
    required this.email,
    required this.role,
    required this.suspended,
    this.photoUrl,
  });

  final String uid;
  final String displayName;
  final String? email;

  /// 'requestor', 'provider' or 'admin'.
  final String role;

  final bool suspended;
  final String? photoUrl;

  factory ManagedUser.fromMap(String uid, Map<String, dynamic> data) {
    return ManagedUser(
      uid: uid,
      displayName: (data['displayName'] as String?) ??
          (data['email'] as String?) ??
          'User',
      email: data['email'] as String?,
      role: data['role'] as String? ?? 'requestor',
      suspended: data['suspended'] as bool? ?? false,
      photoUrl: data['profilePhotoUrl'] as String?,
    );
  }
}
