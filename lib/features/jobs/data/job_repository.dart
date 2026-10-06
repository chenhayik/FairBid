import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../domain/job.dart';
import '../domain/job_event.dart';
import '../domain/service_address.dart';
import 'bid_repository.dart' show InsufficientBalanceException;

/// Firestore's cap on the number of values in a `whereIn` filter.
const int kWhereInLimit = 30;

/// Splits [ids] into consecutive chunks of at most [limit], keeping order.
/// Needed because Firestore rejects `whereIn` with over [kWhereInLimit] values.
List<List<String>> chunkForWhereIn(List<String> ids, {int limit = kWhereInLimit}) {
  assert(limit > 0, 'limit must be positive');
  return [
    for (var i = 0; i < ids.length; i += limit)
      ids.sublist(i, i + limit > ids.length ? ids.length : i + limit),
  ];
}

/// How many open jobs the feed loads at a time. The feed grows this window
/// so the list stays live and the query stays bounded.
const int kOpenJobsPageSize = 30;

/// Reads and writes jobs. The UI uses this interface so tests can fake it.
abstract interface class JobRepository {
  /// Creates a new open job and returns its id.
  Future<String> create(Job job);

  /// Open jobs, newest first, up to [limit]. [category] filters on the server,
  /// so the limit can't hide jobs from other categories.
  Stream<List<Job>> watchOpenJobs({String? category, int limit});

  /// Streams the jobs posted by [requestorId] (newest first).
  Stream<List<Job>> watchMyJobs(String requestorId);

  /// Streams jobs a provider has won (newest first).
  Stream<List<Job>> watchAssignedJobs(String providerId);

  Stream<List<Job>> watchBundleTasks(String bundleId);

  /// One-shot read of [bundleId]'s tasks, ordered like [watchBundleTasks].
  /// Used where a live query might miss tasks, e.g. the bid sheet.
  Future<List<Job>> getBundleTasks(String bundleId);

  Future<Job?> getById(String id);

  /// Streams one job, emitting on every change; null when it doesn't exist.
  Stream<Job?> watchJob(String id);

  /// Cancels a still-open job. Rules only allow open to cancelled directly;
  /// later cancellations use the callables below.
  Future<void> cancelOpenJob(String id);

  /// Either party asks to cancel an in-progress job. Refused if escrow is held.
  Future<void> requestCancellation(String jobId, {String? reason});

  /// The other party answers a cancellation request: [accept] finishes it,
  /// otherwise the request is cleared.
  Future<void> respondToCancellation(String jobId, {required bool accept});

  /// Either party proposes a new price for an in-progress job.
  Future<void> requestPriceChange(String jobId,
      {required int newAmountSen, required String reason});

  /// The other party answers a price change. Accepting an increase can fail
  /// with `insufficient_balance`, like `acceptBid`.
  Future<void> respondToPriceChange(String jobId, {required bool accept});

  /// The proposer withdraws their pending price change.
  Future<void> withdrawPriceChange(String jobId);

  /// Streams a job's activity timeline (oldest first), written by the server.
  Stream<List<JobEvent>> watchJobEvents(String jobId);

  /// Streams the user's saved jobs for [jobIds], newest first (empty if none).
  /// Must return every id, working around Firestore's 30-id `whereIn` limit.
  Stream<List<Job>> watchSavedJobs(List<String> jobIds);

  /// Saves [jobId]'s private service address. Only the owner may write it.
  Future<void> setJobAddress(String jobId, ServiceAddress address);

  /// Streams [jobId]'s private service address (null if unset). Only the owner,
  /// accepted provider and admins can read it.
  Stream<ServiceAddress?> watchJobAddress(String jobId);
}

/// Firestore version of [JobRepository]. Jobs live in the `jobs` collection.
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
    // Both shapes use composite indexes in firestore.indexes.json:
    // (status, createdAt) and (status, category, createdAt).
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
  Stream<List<Job>> watchBundleTasks(String bundleId) {
    // Needs the (bundleId, bundleOrder) composite index.
    return _jobs
        .where('bundleId', isEqualTo: bundleId)
        .orderBy('bundleOrder')
        .snapshots()
        .map(_toJobs);
  }

  @override
  Future<List<Job>> getBundleTasks(String bundleId) async {
    final snapshot = await _jobs
        .where('bundleId', isEqualTo: bundleId)
        .orderBy('bundleOrder')
        .get();
    return _toJobs(snapshot);
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
  Future<void> requestPriceChange(String jobId,
      {required int newAmountSen, required String reason}) async {
    await _functions.httpsCallable('requestPriceChange').call<void>({
      'jobId': jobId,
      'newAmountSen': newAmountSen,
      'reason': reason,
    });
  }

  @override
  Future<void> respondToPriceChange(String jobId,
      {required bool accept}) async {
    try {
      await _functions.httpsCallable('respondToPriceChange').call<void>({
        'jobId': jobId,
        'accept': accept,
      });
    } on FirebaseFunctionsException catch (e) {
      final details = e.details;
      if (e.code == 'failed-precondition' &&
          details is Map &&
          details['reason'] == 'insufficient_balance') {
        throw InsufficientBalanceException(
          shortfallSen: (details['shortfallSen'] as num).toInt(),
          availableSen: (details['availableSen'] as num).toInt(),
          requiredSen: (details['requiredSen'] as num).toInt(),
        );
      }
      rethrow;
    }
  }

  @override
  Future<void> withdrawPriceChange(String jobId) async {
    await _functions
        .httpsCallable('withdrawPriceChange')
        .call<void>({'jobId': jobId});
  }

  @override
  Stream<List<JobEvent>> watchJobEvents(String jobId) {
    // Newest first, bounded. Descending order makes the limit keep the
    // recent events, so the caller doesn't reverse.
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

    // Firestore's whereIn allows 30 ids, so query in chunks of 30 and combine.
    final chunks = chunkForWhereIn(jobIds);

    Stream<List<Job>> chunkStream(List<String> ids) =>
        _jobs.where(FieldPath.documentId, whereIn: ids).snapshots().map(_toJobs);

    // The common case: a single query.
    if (chunks.length == 1) return chunkStream(chunks.first).map(_byNewest);

    return _combineLatest(chunks.map(chunkStream).toList()).map(_byNewest);
  }

  /// Most recent timeline entries kept for a job (the list shows the tail).
  static const _jobEventsLimit = 50;

  /// Newest first. Chunks finish in any order, so sort to keep the list steady.
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

  /// Emits the latest value of every stream in [streams] once all have emitted.
  /// A small hand-written combineLatest (rxdart isn't worth it for one use).
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
              // Wait until every chunk has reported, so the list isn't partial.
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

  /// Turns Firestore Timestamps into DateTime before building the [Job].
  Job _fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = Map<String, dynamic>.of(doc.data() ?? {});
    data['createdAt'] = (data['createdAt'] as Timestamp?)?.toDate();
    data['deadline'] = (data['deadline'] as Timestamp?)?.toDate();
    data['cancellationRequestedAt'] =
        (data['cancellationRequestedAt'] as Timestamp?)?.toDate();
    final pcr = data['priceChangeRequest'];
    if (pcr is Map) {
      data['priceChangeRequest'] = {
        ...Map<String, dynamic>.from(pcr),
        'requestedAt': (pcr['requestedAt'] as Timestamp?)?.toDate(),
      };
    }
    data['cancelledAt'] = (data['cancelledAt'] as Timestamp?)?.toDate();
    data['releasedAt'] = (data['releasedAt'] as Timestamp?)?.toDate();
    return Job.fromMap(doc.id, data);
  }
}
