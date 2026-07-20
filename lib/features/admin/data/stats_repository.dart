import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../domain/platform_stats.dart';

/// Loads the admin dashboard's platform statistics. UI depends on this
/// interface so tests can use a fake without Firestore.
abstract interface class StatsRepository {
  /// One-shot load (pull-to-refresh re-calls it; counts don't need realtime).
  Future<PlatformStats> load();

  /// Runs the `backfillTrust` Cloud Function: recounts every user's completed
  /// jobs and lost disputes so their Trust Score breakdown is recomputed.
  /// Idempotent. Returns the number of users processed.
  Future<int> recomputeTrustScores();
}

/// Firestore-backed [StatsRepository] built on server-side aggregation
/// queries — `count()`/`sum()` return a single number per query instead of
/// downloading every document, which is the correct way to count at scale.
class FirestoreStatsRepository implements StatsRepository {
  FirestoreStatsRepository(
      {FirebaseFirestore? firestore, FirebaseFunctions? functions})
      : _firestore = firestore ?? FirebaseFirestore.instance,
        _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFirestore _firestore;
  final FirebaseFunctions _functions;

  @override
  Future<int> recomputeTrustScores() async {
    final result =
        await _functions.httpsCallable('backfillTrust').call<Map>({});
    return (result.data['users'] as num?)?.toInt() ?? 0;
  }

  Future<int> _count(Query<Map<String, dynamic>> query) async =>
      (await query.count().get()).count ?? 0;

  @override
  Future<PlatformStats> load() async {
    final users = _firestore.collection('users');
    final jobs = _firestore.collection('jobs');

    // All aggregations run concurrently; each returns one number.
    final results = await Future.wait([
      _count(users.where('role', isEqualTo: 'requestor')),
      _count(users.where('role', isEqualTo: 'provider')),
      _count(jobs.where('status', isEqualTo: 'open')),
      _count(jobs.where('status', isEqualTo: 'in_progress')),
      _count(jobs.where('status', isEqualTo: 'completed')),
      _count(users.where('verificationStatus', isEqualTo: 'pending')),
      _count(_firestore
          .collection('disputes')
          .where('status', isEqualTo: 'open')),
      _firestore
          .collection('transactions')
          .where('type', isEqualTo: 'release')
          .aggregate(sum('amountSen'))
          .get()
          .then((s) => (s.getSum('amountSen') ?? 0).toInt()),
    ]);

    return PlatformStats(
      requestors: results[0],
      providers: results[1],
      openJobs: results[2],
      inProgressJobs: results[3],
      completedJobs: results[4],
      pendingVerifications: results[5],
      openDisputes: results[6],
      releasedVolumeSen: results[7],
    );
  }
}
