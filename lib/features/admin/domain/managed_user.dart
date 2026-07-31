/// A user as seen in the admin "Users" management list — the fields needed to
/// identify someone and act on their account, nothing sensitive.
class ManagedUser {
  const ManagedUser({
    required this.uid,
    required this.displayName,
    required this.email,
    required this.role,
    required this.suspended,
    this.suspensionReason,
    this.verificationStatus = 'none',
    this.photoUrl,
  });

  final String uid;
  final String displayName;
  final String? email;

  /// 'requestor' | 'provider' | 'admin' (storage form).
  final String role;

  final bool suspended;
  final String? suspensionReason;
  final String verificationStatus;
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
      suspensionReason: data['suspensionReason'] as String?,
      verificationStatus: data['verificationStatus'] as String? ?? 'none',
      photoUrl: data['profilePhotoUrl'] as String?,
    );
  }
}
