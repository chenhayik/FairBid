import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../domain/milestone.dart';

/// Reads and writes escrow milestones. Money-free writes (propose, submit)
/// go straight to Firestore; the money-moving ones (fund, release) call the
/// Cloud Functions that own `walletBalanceSen` — Firestore rules reject any
/// client write to it, mirroring how `recomputeTrustScore` protects the Trust
/// Score. UI/controllers depend on this interface so tests can use a fake.
abstract interface class MilestoneRepository {
  /// Provider proposes (or amends) the milestone plan for an in-progress job
  /// via the `proposeMilestonePlan` Cloud Function, which enforces the amounts
  /// total the accepted bid and writes each milestone `proposed` — fundable
  /// only once the requestor approves.
  Future<void> proposeMilestones(String jobId, List<Milestone> milestones);

  /// Requestor approves the proposed plan (`approveMilestonePlan`), moving
  /// every proposed milestone to `pending` so funding can begin.
  Future<void> approveMilestonePlan(String jobId);

  /// Requestor sends the proposed plan back with a note
  /// (`rejectMilestonePlan`); the provider then re-proposes.
  Future<void> rejectMilestonePlan(String jobId, {String? note});

  /// Streams a job's milestones in their proposed order.
  Stream<List<Milestone>> watchMilestones(String jobId);

  /// Streams every milestone assigned to [providerId] across jobs (newest
  /// first), for the Earnings screen's In Escrow / Total Earnings figures.
  Stream<List<Milestone>> watchProviderMilestones(String providerId);

  /// Provider marks a funded milestone as delivered. Plain guarded write —
  /// rules enforce funded → submitted only, by the accepted provider.
  Future<void> submitMilestone(String jobId, String milestoneId,
      {String? note});

  /// Debits the requestor's wallet and funds the milestone (the
  /// `fundMilestone` Cloud Function).
  Future<void> fundMilestone(String jobId, String milestoneId);

  /// Credits the provider's wallet, releases the milestone and — when it was
  /// the job's last unreleased one — completes the job, unlocking reviews
  /// (the `releaseMilestone` Cloud Function).
  Future<void> releaseMilestone(String jobId, String milestoneId);
}

/// Firestore-backed [MilestoneRepository]. Milestones live at
/// `jobs/{jobId}/milestones/{milestoneId}`.
class FirestoreMilestoneRepository implements MilestoneRepository {
  FirestoreMilestoneRepository(
      {FirebaseFirestore? firestore, FirebaseFunctions? functions})
      : _firestore = firestore ?? FirebaseFirestore.instance,
        _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFirestore _firestore;
  final FirebaseFunctions _functions;

  CollectionReference<Map<String, dynamic>> _milestones(String jobId) =>
      _firestore.collection('jobs').doc(jobId).collection('milestones');

  @override
  Future<void> proposeMilestones(
      String jobId, List<Milestone> milestones) async {
    // Ordered by list position; the function derives each milestone's `order`
    // from its index, so send them in the intended sequence.
    final ordered = [...milestones]..sort((a, b) => a.order.compareTo(b.order));
    await _functions.httpsCallable('proposeMilestonePlan').call<void>({
      'jobId': jobId,
      'milestones': [
        for (final m in ordered)
          {'description': m.description, 'amountSen': m.amountSen},
      ],
    });
  }

  @override
  Future<void> approveMilestonePlan(String jobId) async {
    await _functions
        .httpsCallable('approveMilestonePlan')
        .call<void>({'jobId': jobId});
  }

  @override
  Future<void> rejectMilestonePlan(String jobId, {String? note}) async {
    await _functions.httpsCallable('rejectMilestonePlan').call<void>({
      'jobId': jobId,
      if (note != null && note.isNotEmpty) 'note': note,
    });
  }

  @override
  Stream<List<Milestone>> watchMilestones(String jobId) {
    return _milestones(jobId).orderBy('order').snapshots().map((snapshot) => [
          for (final doc in snapshot.docs) _fromDoc(jobId, doc),
        ]);
  }

  @override
  Stream<List<Milestone>> watchProviderMilestones(String providerId) {
    return _firestore
        .collectionGroup('milestones')
        .where('providerId', isEqualTo: providerId)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) => [
              for (final doc in snapshot.docs)
                // A milestone's parent's parent is its job document.
                _fromDoc(doc.reference.parent.parent!.id, doc),
            ]);
  }

  @override
  Future<void> submitMilestone(String jobId, String milestoneId,
      {String? note}) {
    return _milestones(jobId).doc(milestoneId).update({
      'status': MilestoneStatus.submitted.storage,
      if (note != null && note.isNotEmpty) 'submissionNote': note,
    });
  }

  @override
  Future<void> fundMilestone(String jobId, String milestoneId) async {
    await _functions.httpsCallable('fundMilestone').call<void>(
        {'jobId': jobId, 'milestoneId': milestoneId});
  }

  @override
  Future<void> releaseMilestone(String jobId, String milestoneId) async {
    await _functions.httpsCallable('releaseMilestone').call<void>(
        {'jobId': jobId, 'milestoneId': milestoneId});
  }

  /// Normalises Firestore Timestamps to DateTime before building the
  /// [Milestone].
  Milestone _fromDoc(
      String jobId, DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = Map<String, dynamic>.of(doc.data() ?? {});
    data['createdAt'] = (data['createdAt'] as Timestamp?)?.toDate();
    return Milestone.fromMap(jobId, doc.id, data);
  }
}
