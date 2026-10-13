/// What:   Snapshot of the marketplace's main numbers.
/// Input:  Aggregate queries in FirestoreStatsRepository.load() (stats_repository.dart).
/// Output: Counts and released volume for PlatformStatsScreen.
class PlatformStats {
  const PlatformStats({
    required this.requestors,
    required this.providers,
    required this.openJobs,
    required this.inProgressJobs,
    required this.completedJobs,
    required this.pendingVerifications,
    required this.openDisputes,
    required this.releasedVolumeSen,
    required this.bundlesAwarded,
    required this.splitAwards,
  });

  final int requestors;
  final int providers;
  final int openJobs;
  final int inProgressJobs;
  final int completedJobs;
  final int pendingVerifications;
  final int openDisputes;

  /// Money released to providers, in sen.
  final int releasedVolumeSen;

  final int bundlesAwarded;

  /// Awarded bundles split across providers.
  final int splitAwards;

  int get totalUsers => requestors + providers;

  /// Share of awarded bundles that were split; 0 if none.
  double get splitAwardRate =>
      bundlesAwarded == 0 ? 0 : splitAwards / bundlesAwarded;
}
