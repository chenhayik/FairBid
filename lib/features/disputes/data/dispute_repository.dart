import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../domain/dispute.dart';

/// Raises and resolves milestone disputes, and streams the admin queue. Both
/// mutations call Cloud Functions - freezing the milestone and moving the
/// escrowed money must be atomic and tamper-proof, so Firestore rules reject
/// every client write to `disputes` (same pattern as the wallet).
/// UI/controllers depend on this interface so tests can use a fake.
abstract interface class DisputeRepository {
  /// A party disputes a funded/delivered milestone: freezes it (`→ disputed`)
  /// and opens the dispute for admin review (the `raiseDispute` function).
  Future<void> raiseDispute({
    required String jobId,
    required String milestoneId,
    required String statement,
    List<String> evidenceUrls = const [],
  });

  /// The raiser withdraws their open dispute; the milestone goes back to
  /// where it was (the `withdrawDispute` function).
  Future<void> withdrawDispute({
    required String jobId,
    required String milestoneId,
  });

  /// Admin ruling: pay the provider (`release`), or refund the client and
  /// end the job (`refund`) - the `resolveDispute` function.
  Future<void> resolveDispute({
    required String disputeId,
    required DisputeResolution resolution,
    required String rulingNote,
  });

  /// Streams every open dispute, oldest first, for the admin queue.
  Stream<List<Dispute>> watchOpenDisputes();
}

/// Firebase-backed [DisputeRepository]. Disputes live in the top-level
/// `disputes` collection so the admin queue is a single query.
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
    // Client-side sort (a handful of open disputes at most) keeps this a
    // single-field query needing no composite index - same trick as the
    // verification queue.
    return _firestore
        .collection('disputes')
        .where('status', isEqualTo: DisputeStatus.open.storage)
        // Bounded: "a handful of open disputes" is an assumption about the
        // platform, not a constraint on it. The admin queue works through
        // them oldest-first, so a cap cannot hide the ones needing attention.
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

  /// Normalises Firestore Timestamps to DateTime before building the
  /// [Dispute].
  Dispute _fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = Map<String, dynamic>.of(doc.data() ?? {});
    data['createdAt'] = (data['createdAt'] as Timestamp?)?.toDate();
    data['resolvedAt'] = (data['resolvedAt'] as Timestamp?)?.toDate();
    return Dispute.fromMap(doc.id, data);
  }
}
