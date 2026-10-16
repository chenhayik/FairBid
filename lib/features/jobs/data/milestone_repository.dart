import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../domain/milestone.dart';

/// What:   Escrow milestone reads and writes, behind an interface so tests can fake it.
/// Input:  Firestore `jobs/{jobId}/milestones`; release goes through a callable.
/// Output: Milestone streams, submit (plain write) and release (callable that moves money).
abstract interface class MilestoneRepository {
  /// What:   Live list of a job's milestones.
  /// Output: Milestones in order.
  Stream<List<Milestone>> watchMilestones(String jobId);

  /// What:   Live list of the provider's milestones across jobs.
  /// Output: Milestones newest first (Earnings figures).
  Stream<List<Milestone>> watchProviderMilestones(String providerId);

  /// What:   Provider marks a funded milestone delivered.
  /// Output: Rules allow funded to submitted only.
  Future<void> submitMilestone(String jobId, String milestoneId,
      {String? note});

  /// What:   Requestor releases a delivered milestone.
  /// Output: Pays the provider via callable; releasing the last one completes the job.
  Future<void> releaseMilestone(String jobId, String milestoneId);
}

/// What:   Firestore and Cloud Functions [MilestoneRepository].
/// Input:  Firestore `jobs/{id}/milestones` and callables.
/// Output: Milestone streams and escrow actions.
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
                // parent.parent is the job.
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

  /// What:   Maps a Firestore doc to a Milestone.
  /// Output: Milestone with createdAt converted to DateTime.
  Milestone _fromDoc(
      String jobId, DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = Map<String, dynamic>.of(doc.data() ?? {});
    data['createdAt'] = (data['createdAt'] as Timestamp?)?.toDate();
    return Milestone.fromMap(jobId, doc.id, data);
  }
}
