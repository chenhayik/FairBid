import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../domain/job.dart';
import '../domain/job_event.dart';
import '../domain/service_address.dart';

/// Firestore's cap on the number of values in a `whereIn` filter.
const int kWhereInLimit = 30;

/// Splits [ids] into consecutive chunks of at most [limit], preserving order.
///
/// Exists because Firestore rejects a `whereIn` with more than [kWhereInLimit]
/// values. Saved Jobs used to sidestep that with `ids.take(30)`, which silently
/// dropped every bookmark past the 30th; callers must query each chunk and
/// combine the results instead. Kept as a pure top-level function so the
/// arithmetic is directly testable - the repository around it needs a live
/// Firestore and cannot be.
List<List<String>> chunkForWhereIn(List<String> ids, {int limit = kWhereInLimit}) {
  assert(limit > 0, 'limit must be positive');
  return [
    for (var i = 0; i < ids.length; i += limit)
      ids.sublist(i, i + limit > ids.length ? ids.length : i + limit),
  ];
}

/// How many open jobs the feed loads at a time. The feed grows this window
/// rather than paging through disjoint pages, so the list stays a live stream
/// (new jobs still appear) while the query stays bounded.
const int kOpenJobsPageSize = 30;

/// Reads and writes jobs. UI/controllers depend on this interface so tests can
/// use a fake without Firestore.
abstract interface class JobRepository {
  /// Creates a new open job and returns its id.
  Future<String> create(Job job);

  /// Open jobs, newest first, bounded to [limit].
  ///
  /// Pass [category] to filter server-side. Doing it in the query rather than
  /// in Dart is what makes the bound safe: filtering a limited window client
  /// side would hide jobs simply because the newest [limit] happened to be in
  /// other categories.
  Stream<List<Job>> watchOpenJobs({String? category, int limit});

  /// Streams the jobs posted by [requestorId] (newest first).
  Stream<List<Job>> watchMyJobs(String requestorId);

  /// Streams the jobs a provider has won - where their accepted bid assigned
  /// them (newest first).
  Stream<List<Job>> watchAssignedJobs(String providerId);

  Future<Job?> getById(String id);

  /// Streams one job, emitting on every change; null when it doesn't exist.
  Stream<Job?> watchJob(String id);

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

  /// Streams a job's activity timeline (oldest first), written server-side by
  /// the `logJobPosted`/`logJobStatusChange`/`logMilestoneStatusChange` Cloud
  /// Functions.
  Stream<List<JobEvent>> watchJobEvents(String jobId);

  /// Streams the jobs on a user's watchlist (Saved Jobs screen), for the
  /// bookmarked ids in [jobIds], newest first. Yields an empty list without
  /// querying when [jobIds] is empty.
  ///
  /// Every id is returned: implementations must work around Firestore's 30-id
  /// `whereIn` cap rather than truncating, or bookmarks past the 30th vanish
  /// with no indication to the user.
  Stream<List<Job>> watchSavedJobs(List<String> jobIds);

  /// Saves (or overwrites) [jobId]'s private service address. Only the
  /// job's owner may write it (see `firestore.rules`).
  Future<void> setJobAddress(String jobId, ServiceAddress address);

  /// Streams [jobId]'s private service address, emitting `null` when none
  /// has been set. Readable only by the job's owner, its accepted provider
  /// and admins.
  Stream<ServiceAddress?> watchJobAddress(String jobId);
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
  Stream<List<Job>> watchOpenJobs({
    String? category,
    int limit = kOpenJobsPageSize,
  }) {
    // Both shapes are covered by declared composite indexes in
    // firestore.indexes.json: (status, createdAt) and, when a category is
    // given, (status, category, createdAt). The latter existed unused until
    // now, because the category filter used to run in Dart.
    Query<Map<String, dynamic>> query =
        _jobs.where('status', isEqualTo: JobStatus.open.storage);
    if (category != null) {
      query = query.where('category', isEqualTo: category);
    }
    return query
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .snapshots()
        .map(_toJobs);
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
  Stream<Job?> watchJob(String id) {
    return _jobs
        .doc(id)
        .snapshots()
        .map((doc) => doc.exists ? _fromDoc(doc) : null);
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

  @override
  Stream<List<JobEvent>> watchJobEvents(String jobId) {
    // Newest first, bounded. Note the pairing: this used to read ascending
    // with the UI calling .reversed to show newest first, so adding a limit
    // on top of that would have kept the OLDEST 50 events and dropped
    // everything recent. Ordering descending here is what makes the limit
    // correct, and the caller no longer reverses.
    return _jobs
        .doc(jobId)
        .collection('events')
        .orderBy('at', descending: true)
        .limit(_jobEventsLimit)
        .snapshots()
        .map((snapshot) => snapshot.docs.map((doc) {
              final data = Map<String, dynamic>.of(doc.data());
              data['at'] = (data['at'] as Timestamp?)?.toDate();
              return JobEvent.fromMap(doc.id, data);
            }).toList());
  }

  @override
  Stream<List<Job>> watchSavedJobs(List<String> jobIds) {
    if (jobIds.isEmpty) return Stream.value(const []);

    // Firestore's whereIn caps at 30 ids. This used to `take(30)`, so a user
    // who bookmarked a 31st job simply never saw it again - no message, no
    // truncation notice. Query in chunks of 30 instead and combine them.
    final chunks = chunkForWhereIn(jobIds);

    Stream<List<Job>> chunkStream(List<String> ids) =>
        _jobs.where(FieldPath.documentId, whereIn: ids).snapshots().map(_toJobs);

    // The overwhelmingly common case: one query, exactly as before.
    if (chunks.length == 1) return chunkStream(chunks.first).map(_byNewest);

    return _combineLatest(chunks.map(chunkStream).toList()).map(_byNewest);
  }

  /// Most recent timeline entries kept for a job. Events accumulate for the
  /// life of a job, and the activity list only ever shows the recent tail.
  static const _jobEventsLimit = 50;

  /// Newest first. Chunked queries resolve in arbitrary order, so without an
  /// explicit sort the saved list would reshuffle as chunks report.
  List<Job> _byNewest(List<Job> jobs) {
    final sorted = [...jobs];
    sorted.sort((a, b) {
      final at = a.createdAt;
      final bt = b.createdAt;
      if (at == null || bt == null) return 0;
      return bt.compareTo(at);
    });
    return sorted;
  }

  /// Emits the concatenation of the latest value from every stream in
  /// [streams], once all of them have produced one.
  ///
  /// `package:async` has no combineLatest and rxdart is not worth a dependency
  /// for one call site, so this is the minimal hand-rolled equivalent.
  Stream<List<Job>> _combineLatest(List<Stream<List<Job>>> streams) {
    final latest = List<List<Job>?>.filled(streams.length, null);
    final subscriptions = <StreamSubscription<List<Job>>>[];
    late final StreamController<List<Job>> controller;

    controller = StreamController<List<Job>>(
      onListen: () {
        for (var i = 0; i < streams.length; i++) {
          final index = i;
          subscriptions.add(streams[index].listen(
            (jobs) {
              latest[index] = jobs;
              // Hold the first emission until every chunk has reported, so
              // the list never renders a partial watchlist.
              if (latest.every((chunk) => chunk != null)) {
                controller.add([for (final chunk in latest) ...chunk!]);
              }
            },
            onError: controller.addError,
          ));
        }
      },
      onCancel: () async {
        for (final subscription in subscriptions) {
          await subscription.cancel();
        }
        subscriptions.clear();
      },
    );
    return controller.stream;
  }

  @override
  Future<void> setJobAddress(String jobId, ServiceAddress address) {
    return _jobs
        .doc(jobId)
        .collection('private')
        .doc('address')
        .set(address.toMap());
  }

  @override
  Stream<ServiceAddress?> watchJobAddress(String jobId) {
    return _jobs
        .doc(jobId)
        .collection('private')
        .doc('address')
        .snapshots()
        .map((doc) => ServiceAddress.fromMap(doc.data()));
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
