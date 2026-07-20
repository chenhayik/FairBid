import 'package:cloud_firestore/cloud_firestore.dart';

import '../domain/pending_verification.dart';

/// Reads the admin verification queue and records approve/reject decisions.
/// The UI depends on this interface so tests can use a fake without Firestore.
abstract interface class VerificationRepository {
  /// Streams every user awaiting review (`verificationStatus == 'pending'`),
  /// oldest submission first so the queue is worked front-to-back.
  Stream<List<PendingVerification>> watchPending();

  /// Loads the applicant's sensitive identity photos (ID, selfie, or the
  /// requestor's ID/SSM document) from their owner+admin-only private doc, for
  /// the review gallery. Returns an empty list when none are present.
  Future<List<VerificationDocument>> loadIdentityDocuments(String uid);

  /// Records the admin's decision: flips `verificationStatus` to
  /// `approved`/`rejected`, stamps `reviewedAt`, and (on reject) stores the
  /// optional [reason] so the applicant can be told why.
  Future<void> decide({
    required String uid,
    required bool approved,
    String? reason,
  });
}

/// Firestore-backed [VerificationRepository]. The queue is a query over the
/// `users` collection; decisions are a single owner-or-admin-guarded update to
/// the applicant's own doc (see `firestore.rules`).
class FirestoreVerificationRepository implements VerificationRepository {
  FirestoreVerificationRepository({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  CollectionReference<Map<String, dynamic>> get _users =>
      _firestore.collection('users');

  @override
  Stream<List<PendingVerification>> watchPending() {
    return _users
        .where('verificationStatus', isEqualTo: 'pending')
        .snapshots()
        .map((snapshot) {
      final items = <PendingVerification>[
        for (final doc in snapshot.docs)
          ?PendingVerification.fromMap(doc.id, doc.data()),
      ]..sort((a, b) {
          // Oldest first; undated submissions sink to the bottom.
          final at = a.submittedAt, bt = b.submittedAt;
          if (at == null && bt == null) return 0;
          if (at == null) return 1;
          if (bt == null) return -1;
          return at.compareTo(bt);
        });
      return items;
    });
  }

  @override
  Future<List<VerificationDocument>> loadIdentityDocuments(String uid) async {
    final data = (await _users
            .doc(uid)
            .collection('private')
            .doc('verification')
            .get())
        .data();
    if (data == null) return const [];
    final docs = <VerificationDocument>[];
    void add(String label, String? url) {
      if (url != null && url.isNotEmpty) {
        docs.add(VerificationDocument(label: label, url: url));
      }
    }

    add('Identity Document', data['idDocumentUrl'] as String?);
    add('Selfie', data['selfieUrl'] as String?);
    add('Identity / SSM Document', data['clientDocumentUrl'] as String?);
    return docs;
  }

  @override
  Future<void> decide({
    required String uid,
    required bool approved,
    String? reason,
  }) {
    return _users.doc(uid).set({
      'verificationStatus': approved ? 'approved' : 'rejected',
      'reviewedAt': FieldValue.serverTimestamp(),
      if (!approved && reason != null && reason.trim().isNotEmpty)
        'verificationReason': reason.trim(),
    }, SetOptions(merge: true));
  }
}
