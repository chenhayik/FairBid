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
        .asyncMap((snapshot) async {
      final items = (await Future.wait([
        for (final doc in snapshot.docs) _toPendingVerification(doc),
      ]))
          .whereType<PendingVerification>()
          .toList()
        ..sort((a, b) {
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

  /// Merges in the applicant's private/payout doc (phone and payout bank
  /// details) before building the snapshot - mirrors
  /// `AuthRepository._mapUser`'s merge. A missing/unreadable private doc
  /// degrades to null (applicants who haven't saved since the
  /// payout-privacy migration keep showing those fields from the legacy
  /// public-doc locations via `PendingVerification.fromMap`'s fallback),
  /// never throws and never breaks the queue's rendering.
  Future<PendingVerification?> _toPendingVerification(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) async {
    Map<String, dynamic>? payout;
    try {
      payout =
          (await doc.reference.collection('private').doc('payout').get())
              .data();
    } catch (_) {
      payout = null;
    }
    // The SSM number moved off the world-readable user document (it is personal
    // data for a sole proprietorship), so the queue reads it from the private
    // doc that admins are allowed to see.
    Map<String, dynamic>? verification;
    try {
      verification = (await doc.reference
              .collection('private')
              .doc('verification')
              .get())
          .data();
    } catch (_) {
      verification = null;
    }
    return PendingVerification.fromMap(doc.id, doc.data(),
        payoutData: payout, verificationData: verification);
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
    add('SSM Document', data['ssmDocumentUrl'] as String?);
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
