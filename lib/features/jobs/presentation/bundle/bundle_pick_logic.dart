import '../../../../core/util/money.dart';
import '../../domain/bundle_bid.dart';

/// What [bid] charges for [taskIds] taken together (their task prices).
int bidPriceFor(BundleBid bid, List<String> taskIds) =>
    taskIds.fold(0, (sum, id) => sum + (bid.priceFor(id) ?? 0));

/// Pending bids covering every task in [taskIds], cheapest first.
List<BundleBid> bidsCoveringAll(List<BundleBid> bids, List<String> taskIds) {
  final covering = [
    for (final bid in bids)
      if (bid.status == BundleBidStatus.pending &&
          taskIds.every(bid.coversTask))
        bid,
  ];
  covering.sort(
    (a, b) => bidPriceFor(a, taskIds).compareTo(bidPriceFor(b, taskIds)),
  );
  return covering;
}

/// Warnings about [picks] (task id -> provider id) that the bids alone show:
/// a lost bundle price.
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

/// Small tags for a bid in the pick sheet.
List<String> bidTags(BundleBid bid) => [
  if (bid.bundlePriceSen != null)
    'Bundle price ${formatRm(bid.bundlePriceSen!)} if they win all '
        '${bid.taskCount} tasks',
];
