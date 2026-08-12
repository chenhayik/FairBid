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

  int get totalUsers => requestors + providers;
  int get totalJobs => openJobs + inProgressJobs + completedJobs;
}
