import 'package:cloud_firestore/cloud_firestore.dart';

/// What:   "Report this user" API for complaints raised from a public profile (unlike flagReview, which reports one review).
/// Input:  Firestore via FirestoreUserReportRepository; a fake in tests.
/// Output: A document in the admin-read-only `reports` collection; there is deliberately no client read.
/// Notes:  No admin screen reads `reports` yet, so the profile copy only promises it was received.
abstract interface class UserReportRepository {
  /// Files a report against [reportedUid]; throws on failure so the caller can say it didn't send.
  Future<void> reportUser({
    required String reporterId,
    required String reportedUid,
    required String reason,
  });
}

/// What:   Firestore-backed [UserReportRepository].
/// Input:  Reporter, reported uid and reason.
/// Output: A `reports` doc with `status: 'open'`.
class FirestoreUserReportRepository implements UserReportRepository {
  FirestoreUserReportRepository({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  @override
  Future<void> reportUser({
    required String reporterId,
    required String reportedUid,
    required String reason,
  }) {
    return _firestore.collection('reports').add({
      'reporterId': reporterId,
      'reportedUid': reportedUid,
      'reason': reason,
      'status': 'open',
      'createdAt': FieldValue.serverTimestamp(),
    });
  }
}
