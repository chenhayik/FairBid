/// A snapshot of the marketplace's main numbers.
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

  /// Total money released to providers, in sen.
  final int releasedVolumeSen;

  /// Bundles with `status: awarded`.
  final int bundlesAwarded;

  /// How many of those went to more than one provider.
  final int splitAwards;

  int get totalUsers => requestors + providers;
  int get totalJobs => openJobs + inProgressJobs + completedJobs;

  /// Share of awarded bundles that were split. 0 if none were awarded.
  double get splitAwardRate =>
      bundlesAwarded == 0 ? 0 : splitAwards / bundlesAwarded;
}
