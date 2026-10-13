import '../../domain/bundle_bid.dart';
import '../../domain/job.dart';

/// Title of task [id] in [tasks], or `'a task'`.
String taskTitle(List<Job> tasks, String id) =>
    tasks.where((t) => t.id == id).firstOrNull?.title ?? 'a task';

/// Pending bids covering [taskId], cheapest first.
List<BundleBid> bidsCoveringTask(List<BundleBid> bids, String taskId) => [
  for (final bid in bids)
    if (bid.status == BundleBidStatus.pending && bid.coversTask(taskId)) bid,
]..sort((a, b) => a.priceFor(taskId)!.compareTo(b.priceFor(taskId)!));

/// Warnings about [picks] (task id -> provider id): picking part of a bid drops its bundle price.
List<String> pickHints(Map<String, String?> picks, List<BundleBid> bids) {
  final hints = <String>[];
  for (final bid in bids) {
    if (bid.status != BundleBidStatus.pending) continue;
    final won = bid.taskPrices.keys
        .where((id) => picks[id] == bid.providerId)
        .length;
    if (won == 0 || won == bid.taskCount) continue;
    if (bid.bundlePriceSen != null) {
      hints.add(
        "Picking fewer than all of ${bid.providerName}'s tasks drops their "
        'bundle price.',
      );
    }
  }
  return hints;
}
