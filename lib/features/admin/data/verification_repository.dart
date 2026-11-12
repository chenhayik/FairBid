import 'package:cloud_firestore/cloud_firestore.dart';

import '../../onboarding/domain/face_box.dart';
import '../../onboarding/domain/id_extract.dart';
import '../../onboarding/domain/ssm_extract.dart';
import '../domain/pending_verification.dart';

/// What:   Admin verification API.
/// Input:  Firestore `users` and their private docs via FirestoreVerificationRepository; a fake in tests.
/// Output: The pending queue, identity documents, the ID and SSM checks and decisions.
abstract interface class VerificationRepository {
  /// Users with `verificationStatus == 'pending'`, oldest submission first.
  Stream<List<PendingVerification>> watchPending();

  /// The applicant's private identity photos (ID with face box, selfie, requestor or SSM document); empty if none.
  Future<List<VerificationDocument>> loadIdentityDocuments(String uid);

  /// The automated MyKad check for [uid], or null if none has run.
  Future<IdExtract?> loadIdExtract(String uid);

  /// The automated SSM document check for [uid], or null if none has run.
  Future<SsmExtract?> loadSsmExtract(String uid);

  /// Sets `verificationStatus` to approved or rejected, stamps `reviewedAt` and stores a reject [reason].
  Future<void> decide({
    required String uid,
    required bool approved,
    String? reason,
  });
}

/// What:   Firestore-backed [VerificationRepository].
/// Input:  A query over `users`; decisions are one admin-guarded write to the applicant's doc.
/// Output: PendingVerification list, documents and decisions.
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

  /// What:   Builds one queue entry from a pending user doc.
  /// Input:  [doc] from the pending query; the applicant's private `payout` and `verification` docs via [_tryPrivate].
  /// Output: PendingVerification with the private data merged in.
  Future<PendingVerification?> _toPendingVerification(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) async {
    return PendingVerification.fromMap(doc.id, doc.data(),
        payoutData: await _tryPrivate(doc.id, 'payout'),
        verificationData: await _tryPrivate(doc.id, 'verification'));
  }

  DocumentReference<Map<String, dynamic>> _private(String uid, String id) =>
      _users.doc(uid).collection('private').doc(id);

  /// What:   Reads one of an applicant's private docs.
  /// Input:  [uid] and the doc [id] under `private/`.
  /// Output: The data; a missing or unreadable doc gives null instead of breaking the queue.
  Future<Map<String, dynamic>?> _tryPrivate(String uid, String id) async {
    try {
      return (await _private(uid, id).get()).data();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<VerificationDocument>> loadIdentityDocuments(String uid) async {
    final data = (await _private(uid, 'verification').get()).data();
    if (data == null) return const [];
    final docs = <VerificationDocument>[];
    void add(String label, String? url, [String? boxField]) {
      if (url != null && url.isNotEmpty) {
        final box = data[boxField];
        docs.add(VerificationDocument(
          label: label,
          url: url,
          faceBox: FaceBox.fromMap(
              box is Map ? Map<String, dynamic>.from(box) : null),
        ));
      }
    }

    add(VerificationDocument.idLabel, data['idDocumentUrl'] as String?,
        'idFaceBox');
    add(VerificationDocument.selfieLabel, data['selfieUrl'] as String?,
        'selfieFaceBox');
    add('Identity / SSM Document', data['clientDocumentUrl'] as String?);
    add('SSM Document', data['ssmDocumentUrl'] as String?);
    return docs;
  }

  @override
  Future<IdExtract?> loadIdExtract(String uid) async =>
      IdExtract.fromMap((await _private(uid, 'idExtract').get()).data());

  @override
  Future<SsmExtract?> loadSsmExtract(String uid) async =>
      SsmExtract.fromMap((await _private(uid, 'ssmExtract').get()).data());

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
