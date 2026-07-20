import 'package:cloud_firestore/cloud_firestore.dart';

import '../domain/bid.dart';
import '../domain/job.dart';

/// Thrown by [BidRepository.acceptBid] when the job is no longer open or the
/// bid is no longer pending — e.g. a second accept, or the bid was withdrawn,
/// raced this one.
class BidAcceptRaceException implements Exception {
  const BidAcceptRaceException();
}

/// Thrown by [BidRepository.withdrawBid] when the bid is no longer pending
/// — e.g. it was just accepted or rejected by a concurrent [acceptBid].
class BidNotPendingException implements Exception {
  const BidNotPendingException();
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
  FirestoreBidRepository({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  DocumentReference<Map<String, dynamic>> _job(String jobId) =>
      _firestore.collection('jobs').doc(jobId);

  CollectionReference<Map<String, dynamic>> _bids(String jobId) =>
      _job(jobId).collection('bids');

  @override
  Future<void> submitBid(Bid bid) {
    final bidRef = _bids(bid.jobId).doc(bid.providerId);
    // A transaction keeps `bidCount` correct: only count a *new* bid, so
    // re-submitting over an existing bid doesn't double-count.
    return _firestore.runTransaction((tx) async {
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
    // Transactions can't run queries, so the candidate pending-bid ids are
    // fetched once outside it; each is re-read (and re-validated) by
    // reference inside the transaction, which is what makes the accept safe
    // against a concurrent accept or withdraw.
    final candidates = await _bids(bid.jobId)
        .where('status', isEqualTo: BidStatus.pending.storage)
        .get();
    final otherRefs = candidates.docs
        .map((d) => d.reference)
        .where((ref) => ref.id != bid.providerId)
        .toList();
    final winnerRef = _bids(bid.jobId).doc(bid.providerId);
    final jobRef = _job(bid.jobId);

    return _firestore.runTransaction((tx) async {
      // All reads before any writes.
      final jobSnap = await tx.get(jobRef);
      final winnerSnap = await tx.get(winnerRef);
      final otherSnaps = <DocumentSnapshot<Map<String, dynamic>>>[
        for (final ref in otherRefs) await tx.get(ref),
      ];

      final jobOpen =
          JobStatus.fromStorage(jobSnap.data()?['status'] as String?) ==
              JobStatus.open;
      // Also true when the winner doc no longer exists (withdrawn) — no
      // separate `.exists` check needed.
      final winnerStillPending =
          winnerSnap.data()?['status'] == BidStatus.pending.storage;
      if (!jobOpen || !winnerStillPending) {
        throw const BidAcceptRaceException();
      }

      // Writes.
      tx.update(winnerRef, {'status': BidStatus.accepted.storage});
      for (var i = 0; i < otherRefs.length; i++) {
        // Skip anything withdrawn/resolved since the pre-fetch — nothing to
        // reject.
        if (otherSnaps[i].data()?['status'] == BidStatus.pending.storage) {
          tx.update(otherRefs[i], {'status': BidStatus.rejected.storage});
        }
      }
      tx.update(jobRef, {
        'status': JobStatus.inProgress.storage,
        'acceptedProviderId': bid.providerId,
        'acceptedProviderName': bid.providerName,
        'acceptedBidAmountSen': bid.amountSen,
      });
    });
  }

  /// Normalises Firestore Timestamps to DateTime before building the [Bid].
  Bid _fromDoc(String jobId, DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = Map<String, dynamic>.of(doc.data() ?? {});
    data['createdAt'] = (data['createdAt'] as Timestamp?)?.toDate();
    return Bid.fromMap(jobId, doc.id, data);
  }
}
