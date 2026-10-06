import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../domain/milestone.dart';

/// Reads and writes escrow milestones. The money-free submit goes straight
/// to Firestore; release calls the Cloud Function that owns
/// `walletBalanceSen` - Firestore rules reject any client write to it,
/// mirroring how `recomputeTrustScore` protects the Trust Score. UI/controllers depend on this interface so tests can use a fake.
abstract interface class MilestoneRepository {
  /// Streams a job's milestones in their proposed order.
  Stream<List<Milestone>> watchMilestones(String jobId);

  /// Streams every milestone assigned to [providerId] across jobs (newest
  /// first), for the Earnings screen's In Escrow / Total Earnings figures.
  Stream<List<Milestone>> watchProviderMilestones(String providerId);

  /// Provider marks a funded milestone as delivered. Plain guarded write -
  /// rules enforce funded → submitted only, by the accepted provider.
  Future<void> submitMilestone(String jobId, String milestoneId,
      {String? note});

  /// Credits the provider's wallet, releases the milestone and - when it was
  /// the job's last unreleased one - completes the job, unlocking reviews
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
