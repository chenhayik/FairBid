/// One snapshot of the marketplace's headline numbers, read via Firestore
/// server-side aggregation queries (no documents are downloaded).
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
    required this.handoverDisputes,
  });

  final int requestors;
  final int providers;
  final int openJobs;
  final int inProgressJobs;
  final int completedJobs;
  final int pendingVerifications;
  final int openDisputes;

  /// Total escrow ever released to providers (the `release` ledger rows), in
  /// sen - the money the marketplace has actually moved.
  final int releasedVolumeSen;

  /// Bundles that reached `status: awarded`.
  final int bundlesAwarded;

  /// Of those, how many were split across more than one provider.
  final int splitAwards;

  /// Disputes flagged as a handover dispute (follows a split bundle award).
  final int handoverDisputes;

  int get totalUsers => requestors + providers;
  int get totalJobs => openJobs + inProgressJobs + completedJobs;

  /// Share of awarded bundles that were split, 0 when none were awarded yet.
  double get splitAwardRate =>
      bundlesAwarded == 0 ? 0 : splitAwards / bundlesAwarded;
}
