import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../domain/bid.dart';

/// Thrown by [BidRepository.acceptBid] when the job is no longer open or the
/// bid is no longer pending — e.g. a second accept, or the bid was withdrawn,
/// raced this one.
class BidAcceptRaceException implements Exception {
  const BidAcceptRaceException();
}

/// Thrown by [BidRepository.acceptBid] when the requestor's available balance
/// (wallet balance minus what's already locked against other accepted bids)
/// can't cover this bid's amount — the server-side gate in the `acceptBid`
/// Cloud Function.
class InsufficientBalanceException implements Exception {
  const InsufficientBalanceException({
    required this.shortfallSen,
    required this.availableSen,
    required this.requiredSen,
  });

  final int shortfallSen;
  final int availableSen;
  final int requiredSen;
}

/// Thrown by [BidRepository.withdrawBid] when the bid is no longer pending
/// — e.g. it was just accepted or rejected by a concurrent [acceptBid].
class BidNotPendingException implements Exception {
  const BidNotPendingException();
}

/// Thrown by [BidRepository.submitBid] when the backend rejects the write
/// (`permission-denied`). The usual cause is a stale snapshot: the bid carries
/// the provider's Trust Score as the sheet saw it, and the security rules pin
/// that to the profile's current value — so if the score was recomputed
/// server-side after the sheet opened, the write is refused. It can also mean
/// the job stopped accepting bids. Either way the fix is to reopen the sheet
/// (which reloads the fresh profile) and submit again, so the sheet's captured
/// data isn't re-sent unchanged.
class BidRejectedException implements Exception {
  const BidRejectedException();
}

/// Reads and writes bids. UI/controllers depend on this interface so tests can
/// use a fake without Firestore.
abstract interface class BidRepository {
  /// Creates (or re-creates after a withdrawal) the provider's bid on a job
  /// and increments the job's `bidCount`.
  Future<void> submitBid(Bid bid);

  /// Deletes the provider's bid and decrements the job's `bidCount`.
  Future<void> withdrawBid(String jobId, String providerId);

  /// Streams all bids on a job (requestor view). Sorting by price or Trust
  /// Score is done client-side — a job only ever has a handful of bids.
  Stream<List<Bid>> watchBids(String jobId);

  /// Streams the provider's own bids across all jobs (newest first), for the
  /// "Pending Bids" list on the provider side.
  Stream<List<Bid>> watchMyBids(String providerId);

  /// Streams the provider's existing bid on one job, or null — used by the
  /// job detail to decide between "Submit a bid" and "Withdraw".
  Stream<Bid?> watchMyBid(String jobId, String providerId);

  /// Accepts [bid]: marks it accepted, rejects the job's other pending bids,
  /// and moves the job to in_progress with the winner fields set.
  Future<void> acceptBid(Bid bid);
}

/// Firestore-backed [BidRepository]. Bids live at `jobs/{jobId}/bids/{uid}` —
/// the provider's uid as the doc id enforces one bid per provider per job.
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
    // A transaction keeps `bidCount` correct: only count a *new* bid, so
    // re-submitting over an existing bid doesn't double-count.
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
      // Rules rejected the write (most often the Trust Score pin against a
      // stale snapshot). Surface it as a typed, recoverable case.
      if (e.code == 'permission-denied') throw const BidRejectedException();
      rethrow;
    }
  }

  @override
  Future<void> withdrawBid(String jobId, String providerId) {
    final bidRef = _bids(jobId).doc(providerId);
    // Only decrement when a bid actually existed, so a double-withdraw can't
    // push the count below the real number of bids. Refuse to withdraw a bid
    // that's already been accepted/rejected — deleting it would orphan the
    // job's winner fields.
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
                // A bid's parent's parent is its job document.
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
    // The `acceptBid` Cloud Function does the race-safe transaction (winner →
    // accepted, other pending bids → rejected, job → in_progress) plus the
    // wallet-balance gate that a client write can't be trusted to enforce.
    try {
      await _functions.httpsCallable('acceptBid').call<void>({
        'jobId': bid.jobId,
        'providerId': bid.providerId,
      });
    } on FirebaseFunctionsException catch (e) {
      if (e.code != 'failed-precondition') rethrow;
      final details = e.details;
      if (details is Map && details['reason'] == 'insufficient_balance') {
        throw InsufficientBalanceException(
          shortfallSen: (details['shortfallSen'] as num).toInt(),
          availableSen: (details['availableSen'] as num).toInt(),
          requiredSen: (details['requiredSen'] as num).toInt(),
        );
      }
      // `reason: 'race'` (job no longer open / bid no longer pending), or any
      // other failed-precondition — surface as the race case either way.
      throw const BidAcceptRaceException();
    }
  }

  /// Normalises Firestore Timestamps to DateTime before building the [Bid].
  Bid _fromDoc(String jobId, DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = Map<String, dynamic>.of(doc.data() ?? {});
    data['createdAt'] = (data['createdAt'] as Timestamp?)?.toDate();
    return Bid.fromMap(jobId, doc.id, data);
  }
}
