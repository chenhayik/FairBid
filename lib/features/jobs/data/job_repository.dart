import 'dart:async';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../domain/job.dart';
import '../domain/job_event.dart';
import '../domain/service_address.dart';
import 'bid_repository.dart' show InsufficientBalanceException;

const int kWhereInLimit = 30;

/// Splits [ids] into ordered chunks of at most [kWhereInLimit], Firestore's `whereIn` cap.
List<List<String>> chunkForWhereIn(List<String> ids) => [
      for (var i = 0; i < ids.length; i += kWhereInLimit)
        ids.sublist(i, min(i + kWhereInLimit, ids.length)),
    ];

/// Open jobs the feed loads per page; the feed grows the window.
const int kOpenJobsPageSize = 30;

/// What:   Job reads and writes, behind an interface so tests can fake it.
/// Input:  Firestore `jobs` plus callables, via FirestoreJobRepository.
/// Output: Job streams/reads, cancellations, price changes, visit scheduling, private address.
abstract interface class JobRepository {
  /// Creates an open job; returns its id.
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
  Future<List<Job>> getBundleTasks(String bundleId);

  /// Streams one job; null when it doesn't exist.
  Stream<Job?> watchJob(String id);

  /// Cancels a still-open job. Rules only allow open to cancelled directly;
  /// later cancellations use the callables below.
  Future<void> cancelOpenJob(String id);

  /// Either party asks to cancel an in-progress job. Refused while a stage is delivered or disputed.
  Future<void> requestCancellation(String jobId, {String? reason});

  /// The other party answers a cancellation request: [accept] finishes it,
  /// otherwise the request is cleared.
  Future<void> respondToCancellation(String jobId, {required bool accept});

  /// Either party proposes a new price for an in-progress job.
  Future<void> requestPriceChange(String jobId,
      {required int newAmountSen, required String reason});

  /// The other party answers a price change; accepting an increase can fail with `insufficient_balance`.
  Future<void> respondToPriceChange(String jobId, {required bool accept});

  /// The proposer withdraws their pending price change.
  Future<void> withdrawPriceChange(String jobId);

  /// What:   Proposes 1-3 visit times; the other party confirms one.
  /// Input:  Callable `proposeAppointment` (functions/scheduling.js).
  /// Output: Replaces any pending proposal; [endAt] is the finish time.
  ///         [alsoJobIds] are sibling bundle tasks that get the same times.
  Future<void> proposeAppointment(String jobId,
      {required List<DateTime> options,
      DateTime? endAt,
      String? note,
      List<String> alsoJobIds = const []});

  /// What:   Confirms the proposed time at [optionIndex].
  /// Input:  Callable `respondToAppointment` (functions/scheduling.js).
  /// Output: Sets the job's appointment and clears the proposal.
  Future<void> respondToAppointment(String jobId, int optionIndex);

  /// What:   Takes back the caller's pending visit proposal.
  /// Input:  Callable `withdrawAppointmentProposal` (functions/scheduling.js).
  /// Output: Clears the proposal.
  Future<void> withdrawAppointmentProposal(String jobId);

  /// What:   Tells the requestor the provider is heading to the visit.
  /// Input:  Callable `markOnTheWay` (functions/scheduling.js); [etaMinutes] is 15/30/45/60.
  /// Output: Sets onTheWayAt and etaMinutes; callable again to update the ETA.
  Future<void> markOnTheWay(String jobId, int etaMinutes);

  /// What:   Tells the requestor the provider has arrived.
  /// Input:  Callable `markArrived` (functions/scheduling.js).
  /// Output: Sets arrivedAt.
  Future<void> markArrived(String jobId);

  /// Streams a job's activity timeline (oldest first), written by the server.
  Stream<List<JobEvent>> watchJobEvents(String jobId);

  /// Streams the saved jobs for [jobIds], newest first; handles lists over the `whereIn` cap.
  Stream<List<Job>> watchSavedJobs(List<String> jobIds);

  /// Saves [jobId]'s private service address. Only the owner may write it.
  Future<void> setJobAddress(String jobId, ServiceAddress address);

  /// Streams [jobId]'s private address (null if unset); readable by the owner, accepted provider and admins.
  Stream<ServiceAddress?> watchJobAddress(String jobId);
}

/// What:   Firestore implementation of [JobRepository].
/// Input:  `jobs` collection (and its `events` and `private` subcollections); Cloud Functions callables.
/// Output: Jobs with Timestamps converted to DateTime.
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
    // Needs composite indexes (status, createdAt) and (status, category, createdAt).
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
      final shortfall = InsufficientBalanceException.from(e);
      if (shortfall != null) throw shortfall;
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
  Future<void> proposeAppointment(String jobId,
      {required List<DateTime> options,
      DateTime? endAt,
      String? note,
      List<String> alsoJobIds = const []}) async {
    await _functions.httpsCallable('proposeAppointment').call<void>({
      'jobId': jobId,
      'options': [for (final o in options) o.millisecondsSinceEpoch],
      if (endAt != null) 'endAt': endAt.millisecondsSinceEpoch,
      if (note != null && note.isNotEmpty) 'note': note,
      if (alsoJobIds.isNotEmpty) 'alsoJobIds': alsoJobIds,
    });
  }

  @override
  Future<void> respondToAppointment(String jobId, int optionIndex) async {
    await _functions.httpsCallable('respondToAppointment').call<void>({
      'jobId': jobId,
      'optionIndex': optionIndex,
    });
  }

  @override
  Future<void> withdrawAppointmentProposal(String jobId) async {
    await _functions
        .httpsCallable('withdrawAppointmentProposal')
        .call<void>({'jobId': jobId});
  }

  @override
  Future<void> markOnTheWay(String jobId, int etaMinutes) async {
    await _functions
        .httpsCallable('markOnTheWay')
        .call<void>({'jobId': jobId, 'etaMinutes': etaMinutes});
  }

  @override
  Future<void> markArrived(String jobId) async {
    await _functions.httpsCallable('markArrived').call<void>({'jobId': jobId});
  }

  @override
  Stream<List<JobEvent>> watchJobEvents(String jobId) {
    // Descending, so the limit keeps the newest events.
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

    final chunks = chunkForWhereIn(jobIds);

    Stream<List<Job>> chunkStream(List<String> ids) =>
        _jobs.where(FieldPath.documentId, whereIn: ids).snapshots().map(_toJobs);

    if (chunks.length == 1) return chunkStream(chunks.first).map(_byNewest);

    return _combineLatest(chunks.map(chunkStream).toList()).map(_byNewest);
  }

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

  /// combineLatest: emits once every stream in [streams] has emitted (no rxdart dependency).
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
              // Wait for every chunk so the list isn't partial.
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

  Job _fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) => Job.fromMap(
        doc.id,
        _toDates(doc.data() ?? {}) as Map<String, dynamic>,
      );

  /// What:   Converts every Timestamp inside [value] (maps and lists too).
  /// Input:  A Firestore field value.
  /// Output: The same shape with DateTimes.
  Object? _toDates(Object? value) => switch (value) {
        Timestamp t => t.toDate(),
        Map m => {
            for (final e in m.entries) e.key as String: _toDates(e.value),
          },
        List l => [for (final v in l) _toDates(v)],
        _ => value,
      };
}
