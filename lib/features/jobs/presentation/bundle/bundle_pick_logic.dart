import '../../../../core/config/platform_config.dart';
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

/// What:   Best Value score for one package bid, the same 60/40 blend single jobs use.
/// Input:  [bid] and [cheapestByTask] (task id to the lowest price any bid offers for it).
/// Output: PlatformConfig.priceWeight * (cheapest cost of the same tasks / the bid's quoted total)
///         + trustWeight * trust (scaled to 0-1); cheaper and more trusted scores higher.
/// Notes:  Bids can cover different tasks, so price is compared task by task, not by raw total.
///         A "New" provider counts as the neutral baseline, as on single jobs.
double bundleBidValueScore(BundleBid bid, Map<String, int> cheapestByTask) {
  final quoted = bid.quotedTotalSen;
  final cheapest = bid.taskPrices.keys.fold(
    0,
    (sum, id) => sum + (cheapestByTask[id] ?? bid.taskPrices[id]!),
  );
  final priceScore = quoted <= 0 ? 0.0 : cheapest / quoted;
  final trust = (bid.providerScoreVisible
          ? bid.providerTrustScore
          : PlatformConfig.neutralTrustScore) /
      1000;
  return PlatformConfig.priceWeight * priceScore +
      PlatformConfig.trustWeight * trust;
}

/// What:   Package bids in Best Value order.
/// Input:  [bids] (any status).
/// Output: A new list, highest bundleBidValueScore() first.
List<BundleBid> rankBundleBidsByValue(List<BundleBid> bids) {
  final cheapestByTask = <String, int>{};
  for (final bid in bids) {
    bid.taskPrices.forEach((id, price) {
      final lowest = cheapestByTask[id];
      if (lowest == null || price < lowest) cheapestByTask[id] = price;
    });
  }
  final scores = {
    for (final bid in bids)
      bid.providerId: bundleBidValueScore(bid, cheapestByTask),
  };
  return [...bids]
    ..sort((a, b) => scores[b.providerId]!.compareTo(scores[a.providerId]!));
}
