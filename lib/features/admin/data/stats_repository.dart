import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../domain/platform_stats.dart';

/// What:   Admin dashboard stats API.
/// Input:  Firestore aggregates via FirestoreStatsRepository; a fake in tests.
/// Output: PlatformStats and the Trust Score recompute.
abstract interface class StatsRepository {
  /// Loads the numbers once.
  Future<PlatformStats> load();

  /// Recounts every user's completed jobs and lost disputes (`backfillTrust`); returns the user count. It also moves any old wallet balance on the user doc into the private wallet. Safe to rerun.
  Future<int> recomputeTrustScores();
}

/// What:   Firestore [StatsRepository].
/// Input:  `count()` / `sum()` aggregate queries, so no documents are downloaded.
/// Output: PlatformStats.
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
    final bundles = _firestore.collection('bundles');
    final disputes = _firestore.collection('disputes');

    // Order matches the PlatformStats fields below.
    final results = await Future.wait([
      _count(users.where('role', isEqualTo: 'requestor')),
      _count(users.where('role', isEqualTo: 'provider')),
      _count(jobs.where('status', isEqualTo: 'open')),
      _count(jobs.where('status', isEqualTo: 'in_progress')),
      _count(jobs.where('status', isEqualTo: 'completed')),
      _count(users.where('verificationStatus', isEqualTo: 'pending')),
      _count(disputes.where('status', isEqualTo: 'open')),
      _firestore
          .collection('transactions')
          .where('type', isEqualTo: 'release')
          .aggregate(sum('amountSen'))
          .get()
          .then((s) => (s.getSum('amountSen') ?? 0).toInt()),
      _count(bundles.where('status', isEqualTo: 'awarded')),
      _count(bundles
          .where('status', isEqualTo: 'awarded')
          .where('splitAward', isEqualTo: true)),
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
      bundlesAwarded: results[8],
      splitAwards: results[9],
    );
  }
}
