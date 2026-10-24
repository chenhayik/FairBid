import '../../domain/bundle_bid.dart';
import '../../domain/job.dart';

/// What:   Title of one task.
/// Input:  [tasks] and task [id].
/// Output: The title, or `'a task'`.
String taskTitle(List<Job> tasks, String id) =>
    tasks.where((t) => t.id == id).firstOrNull?.title ?? 'a task';

/// What:   Bids that can win a task.
/// Input:  [bids] and [taskId].
/// Output: Pending bids covering it, cheapest first.
List<BundleBid> bidsCoveringTask(List<BundleBid> bids, String taskId) => [
  for (final bid in bids)
    if (bid.status == BundleBidStatus.pending && bid.coversTask(taskId)) bid,
]..sort((a, b) => a.priceFor(taskId)!.compareTo(b.priceFor(taskId)!));

/// What:   Discount a bid's bundle deal gives on an award.
/// Input:  [bid] and the [taskAmountsSen] it would be paid.
/// Output: Sen saved versus its single-task prices (0 or less when there is no deal).
int bundleSavingSen(BundleBid bid, Map<String, int> taskAmountsSen) =>
    taskAmountsSen.entries.fold(
      0,
      (sum, e) => sum + (bid.priceFor(e.key) ?? e.value) - e.value,
    );

/// What:   Warnings about the client's picks.
/// Input:  [picks] (task id to provider id) and [bids].
/// Output: One hint per provider with a bundle price whose tasks are only partly picked, since that drops the bundle price.
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
