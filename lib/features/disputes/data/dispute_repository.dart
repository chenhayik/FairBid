import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../domain/dispute.dart';

/// What:   Dispute API: raise, withdraw, resolve and the admin queue.
/// Input:  Cloud Functions and Firestore via FirestoreDisputeRepository; a fake in tests.
/// Output: Mutations run in functions (atomic, tamper-proof); rules reject client writes to `disputes`.
abstract interface class DisputeRepository {
  /// A party disputes a funded or delivered milestone: freezes it and opens the dispute (`raiseDispute`).
  Future<void> raiseDispute({
    required String jobId,
    required String milestoneId,
    required String statement,
    List<String> evidenceUrls = const [],
  });

  /// The raiser withdraws their open dispute; the milestone returns to its prior state (`withdrawDispute`).
  Future<void> withdrawDispute({
    required String jobId,
    required String milestoneId,
  });

  /// Admin ruling: pay the provider (`release`) or refund the client and end the job (`refund`) (`resolveDispute`).
  Future<void> resolveDispute({
    required String disputeId,
    required DisputeResolution resolution,
    required String rulingNote,
  });

  /// Every open dispute, oldest first.
  Stream<List<Dispute>> watchOpenDisputes();
}

/// What:   Firebase-backed [DisputeRepository].
/// Input:  Top-level `disputes` collection (one query for the admin queue) and the dispute callables.
/// Output: Dispute models and mutation calls.
class FirestoreDisputeRepository implements DisputeRepository {
  FirestoreDisputeRepository(
      {FirebaseFirestore? firestore, FirebaseFunctions? functions})
      : _firestore = firestore ?? FirebaseFirestore.instance,
        _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFirestore _firestore;
  final FirebaseFunctions _functions;

  @override
  Future<void> raiseDispute({
    required String jobId,
    required String milestoneId,
    required String statement,
    List<String> evidenceUrls = const [],
  }) async {
    await _functions.httpsCallable('raiseDispute').call<void>({
      'jobId': jobId,
      'milestoneId': milestoneId,
      'statement': statement,
      'evidenceUrls': evidenceUrls,
    });
  }

  @override
  Future<void> withdrawDispute({
    required String jobId,
    required String milestoneId,
  }) async {
    await _functions.httpsCallable('withdrawDispute').call<void>({
      'jobId': jobId,
      'milestoneId': milestoneId,
    });
  }

  @override
  Future<void> resolveDispute({
    required String disputeId,
    required DisputeResolution resolution,
    required String rulingNote,
  }) async {
    await _functions.httpsCallable('resolveDispute').call<void>({
      'disputeId': disputeId,
      'resolution': resolution.storage,
      'rulingNote': rulingNote,
    });
  }

  @override
  Stream<List<Dispute>> watchOpenDisputes() {
    // Sorted client-side to avoid a composite index (few open disputes).
    return _firestore
        .collection('disputes')
        .where('status', isEqualTo: DisputeStatus.open.storage)
        // Safety cap; unordered, so beyond 100 some would not be listed.
        .limit(100)
        .snapshots()
        .map((snapshot) => [
              for (final doc in snapshot.docs) _fromDoc(doc),
            ]..sort((a, b) {
                final at = a.createdAt, bt = b.createdAt;
                if (at == null && bt == null) return 0;
                if (at == null) return 1;
                if (bt == null) return -1;
                return at.compareTo(bt);
              }));
  }

  Dispute _fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = Map<String, dynamic>.of(doc.data() ?? {});
    data['createdAt'] = (data['createdAt'] as Timestamp?)?.toDate();
    return Dispute.fromMap(doc.id, data);
  }
}
