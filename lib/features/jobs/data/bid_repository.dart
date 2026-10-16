import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../domain/bid.dart';

/// What:   Thrown by acceptBid when the job is no longer open or the bid is no longer pending.
/// Input:  None.
/// Output: Exception the UI turns into a retry message.
class BidAcceptRaceException implements Exception {
  const BidAcceptRaceException();
}

/// What:   Thrown when a callable refuses because the requestor's available balance can't cover the amount.
/// Input:  [shortfallSen], [availableSen], [requiredSen] from the server.
/// Output: Exception the UI turns into a top-up prompt.
class InsufficientBalanceException implements Exception {
  const InsufficientBalanceException({
    required this.shortfallSen,
    required this.availableSen,
    required this.requiredSen,
  });

  final int shortfallSen;
  final int availableSen;
  final int requiredSen;

  /// What:   Reads the shortfall out of a callable error.
  /// Input:  [e] from a FirebaseFunctions call.
  /// Output: The exception, or null if [e] isn't `insufficient_balance`.
  static InsufficientBalanceException? from(FirebaseFunctionsException e) {
    final details = e.details;
    if (details is! Map || details['reason'] != 'insufficient_balance') {
      return null;
    }
    return InsufficientBalanceException(
      shortfallSen: (details['shortfallSen'] as num).toInt(),
      availableSen: (details['availableSen'] as num).toInt(),
      requiredSen: (details['requiredSen'] as num).toInt(),
    );
  }
}

/// What:   Thrown by withdrawBid when the bid is no longer pending (just accepted or rejected).
/// Input:  None.
/// Output: Exception the UI turns into a refresh message.
class BidNotPendingException implements Exception {
  const BidNotPendingException();
}

/// What:   Thrown by submitBid on `permission-denied` (stale Trust Score or the job closed).
/// Input:  None.
/// Output: Exception; reopening the sheet and resubmitting fixes it.
class BidRejectedException implements Exception {
  const BidRejectedException();
}

/// What:   Per-job bid reads and writes, behind an interface so tests can fake it.
/// Input:  Firestore `jobs/{jobId}/bids/{uid}` and the `acceptBid` callable, via FirestoreBidRepository.
/// Output: Bid streams and writes; failures as the exceptions above.
abstract interface class BidRepository {
  /// What:   Creates the provider's bid or replaces it.
  /// Output: Writes the bid and counts it in `bidCount` (new bids only).
  Future<void> submitBid(Bid bid);

  /// What:   Withdraws the provider's pending bid.
  /// Output: Deletes the bid and decrements `bidCount`.
  Future<void> withdrawBid(String jobId, String providerId);

  /// What:   Live bids on one job.
  /// Output: All bids, unsorted (callers sort).
  Stream<List<Bid>> watchBids(String jobId);

  /// What:   Live list of a provider's own bids across jobs.
  /// Output: Bids, newest first.
  Stream<List<Bid>> watchMyBids(String providerId);

  /// What:   Live view of the provider's bid on one job.
  /// Output: The bid, or null.
  Stream<Bid?> watchMyBid(String jobId, String providerId);

  /// What:   Requestor accepts a bid.
  /// Output: Rejects the other pending bids and moves the job to in_progress; may throw the exceptions above.
  Future<void> acceptBid(Bid bid);
}

/// What:   Firestore and Cloud Functions [BidRepository].
/// Input:  Firestore `jobs/{id}/bids/{uid}` (the uid doc id gives one bid per provider) and callables.
/// Output: Bid streams and writes.
class FirestoreBidRepository implements BidRepository {
  FirestoreBidRepository(
      {FirebaseFirestore? firestore, FirebaseFunctions? functions})
      : _firestore = firestore ?? FirebaseFirestore.instance,
        _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFirestore _firestore;
  final FirebaseFunctions _functions;

  DocumentReference<Map<String, dynamic>> _job(String jobId) =>
      _firestore.collection('jobs').doc(jobId);

  CollectionReference<Map<String, dynamic>> _bids(String jobId) =>
      _job(jobId).collection('bids');

  @override
  Future<void> submitBid(Bid bid) async {
    final bidRef = _bids(bid.jobId).doc(bid.providerId);
    // Transaction: only a new bid raises `bidCount`.
    try {
      await _firestore.runTransaction((tx) async {
        final existing = await tx.get(bidRef);
        tx.set(bidRef, {
          ...bid.toMap(),
          'status': BidStatus.pending.storage,
          'createdAt': FieldValue.serverTimestamp(),
        });
        if (!existing.exists) {
          tx.update(_job(bid.jobId), {'bidCount': FieldValue.increment(1)});
        }
      });
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') throw const BidRejectedException();
      rethrow;
    }
  }

  @override
  Future<void> withdrawBid(String jobId, String providerId) {
    final bidRef = _bids(jobId).doc(providerId);
    // Only decrement if the bid existed; refuse once accepted/rejected, or the winner fields orphan.
    return _firestore.runTransaction((tx) async {
      final existing = await tx.get(bidRef);
      if (!existing.exists) return;
      if (existing.data()?['status'] != BidStatus.pending.storage) {
        throw const BidNotPendingException();
      }
      tx.delete(bidRef);
      tx.update(_job(jobId), {'bidCount': FieldValue.increment(-1)});
    });
  }

  @override
  Stream<List<Bid>> watchBids(String jobId) {
    return _bids(jobId).snapshots().map((snapshot) => [
          for (final doc in snapshot.docs) _fromDoc(jobId, doc),
        ]);
  }

  @override
  Stream<List<Bid>> watchMyBids(String providerId) {
    return _firestore
        .collectionGroup('bids')
        .where('providerId', isEqualTo: providerId)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) => [
              for (final doc in snapshot.docs)
                // parent.parent is the job.
                _fromDoc(doc.reference.parent.parent!.id, doc),
            ]);
  }

  @override
  Stream<Bid?> watchMyBid(String jobId, String providerId) {
    return _bids(jobId).doc(providerId).snapshots().map(
        (doc) => doc.exists ? _fromDoc(jobId, doc) : null);
  }

  @override
  Future<void> acceptBid(Bid bid) async {
    // The callable does the race-safe transaction and the balance check.
    try {
      await _functions.httpsCallable('acceptBid').call<void>({
        'jobId': bid.jobId,
        'providerId': bid.providerId,
      });
    } on FirebaseFunctionsException catch (e) {
      if (e.code != 'failed-precondition') rethrow;
      final shortfall = InsufficientBalanceException.from(e);
      if (shortfall != null) throw shortfall;
      // reason 'race' or any other failed-precondition: treat as a race.
      throw const BidAcceptRaceException();
    }
  }

  Bid _fromDoc(String jobId, DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = Map<String, dynamic>.of(doc.data() ?? {});
    data['createdAt'] = (data['createdAt'] as Timestamp?)?.toDate();
    return Bid.fromMap(jobId, doc.id, data);
  }
}
