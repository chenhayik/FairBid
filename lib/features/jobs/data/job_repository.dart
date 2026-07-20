import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../domain/job.dart';

/// Reads and writes jobs. UI/controllers depend on this interface so tests can
/// use a fake without Firestore.
abstract interface class JobRepository {
  /// Creates a new open job and returns its id.
  Future<String> create(Job job);

  /// Streams open jobs (newest first), optionally filtered by [category].
  /// Budget and distance filtering are applied client-side by the caller.
  Stream<List<Job>> watchOpenJobs({String? category});

  /// Streams the jobs posted by [requestorId] (newest first).
  Stream<List<Job>> watchMyJobs(String requestorId);

  /// Streams the jobs a provider has won — where their accepted bid assigned
  /// them (newest first).
  Stream<List<Job>> watchAssignedJobs(String providerId);

  Future<Job?> getById(String id);

  /// Cancels a still-open job (no provider yet, so nothing to settle). Rules
  /// only permit the requestor the open → cancelled transition directly; every
  /// mid-flight transition goes through the cancellation callables below.
  Future<void> cancelOpenJob(String id);

  /// Either party requests cancellation of an in-progress job
  /// (`requestJobCancellation`). Refused server-side while escrow is held.
  Future<void> requestCancellation(String jobId, {String? reason});

  /// The counterparty answers a pending cancellation request
  /// (`respondToJobCancellation`): [accept] finalises the cancellation,
  /// otherwise the request is cleared.
  Future<void> respondToCancellation(String jobId, {required bool accept});

  /// Admin override that cancels an in-progress job (`adminCancelJob`), still
  /// refused while escrow is held.
  Future<void> adminCancelJob(String jobId, {String? reason});
}

/// Firestore-backed [JobRepository]. Jobs live in a top-level `jobs` collection.
class FirestoreJobRepository implements JobRepository {
  FirestoreJobRepository(
      {FirebaseFirestore? firestore, FirebaseFunctions? functions})
      : _firestore = firestore ?? FirebaseFirestore.instance,
        _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFirestore _firestore;
  final FirebaseFunctions _functions;

  CollectionReference<Map<String, dynamic>> get _jobs =>
      _firestore.collection('jobs');

  @override
  Future<String> create(Job job) async {
    final ref = await _jobs.add({
      ...job.toMap(),
      'status': JobStatus.open.storage,
      'bidCount': 0,
      'createdAt': FieldValue.serverTimestamp(),
    });
    return ref.id;
  }

  @override
  Stream<List<Job>> watchOpenJobs({String? category}) {
    Query<Map<String, dynamic>> query =
        _jobs.where('status', isEqualTo: JobStatus.open.storage);
    if (category != null) {
      query = query.where('category', isEqualTo: category);
    }
    query = query.orderBy('createdAt', descending: true);
    return query.snapshots().map(_toJobs);
  }

  @override
  Stream<List<Job>> watchMyJobs(String requestorId) {
    return _jobs
        .where('requestorId', isEqualTo: requestorId)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map(_toJobs);
  }

  @override
  Stream<List<Job>> watchAssignedJobs(String providerId) {
    return _jobs
        .where('acceptedProviderId', isEqualTo: providerId)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map(_toJobs);
  }

  @override
  Future<Job?> getById(String id) async {
    final doc = await _jobs.doc(id).get();
    return doc.exists ? _fromDoc(doc) : null;
  }

  @override
  Future<void> cancelOpenJob(String id) {
    return _jobs.doc(id).update({'status': JobStatus.cancelled.storage});
  }

  @override
  Future<void> requestCancellation(String jobId, {String? reason}) async {
    await _functions.httpsCallable('requestJobCancellation').call<void>({
      'jobId': jobId,
      if (reason != null && reason.isNotEmpty) 'reason': reason,
    });
  }

  @override
  Future<void> respondToCancellation(String jobId,
      {required bool accept}) async {
    await _functions.httpsCallable('respondToJobCancellation').call<void>({
      'jobId': jobId,
      'accept': accept,
    });
  }

  @override
  Future<void> adminCancelJob(String jobId, {String? reason}) async {
    await _functions.httpsCallable('adminCancelJob').call<void>({
      'jobId': jobId,
      if (reason != null && reason.isNotEmpty) 'reason': reason,
    });
  }

  List<Job> _toJobs(QuerySnapshot<Map<String, dynamic>> snapshot) =>
      snapshot.docs.map(_fromDoc).toList();

  /// Normalises Firestore Timestamps to DateTime before building the [Job].
  Job _fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = Map<String, dynamic>.of(doc.data() ?? {});
    data['createdAt'] = (data['createdAt'] as Timestamp?)?.toDate();
    data['deadline'] = (data['deadline'] as Timestamp?)?.toDate();
    data['cancellationRequestedAt'] =
        (data['cancellationRequestedAt'] as Timestamp?)?.toDate();
    data['cancelledAt'] = (data['cancelledAt'] as Timestamp?)?.toDate();
    return Job.fromMap(doc.id, data);
  }
}
