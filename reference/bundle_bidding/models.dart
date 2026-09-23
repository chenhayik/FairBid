// Domain types for bundled job postings with partial bids.
//
// Pure Dart on purpose: no Flutter and no Firebase, so the award rules in
// `award_engine.dart` can be read and run on their own. The behaviour here
// follows docs/BUNDLE_BIDDING.md.

/// Biggest amount one task price may carry: RM 1,000,000 in sen. The app's
/// existing bid rules already cap a single bid at this.
const int maxTaskPriceSen = 100000000;

/// One task inside a bundle. In the real app each task is a child job.
class BundleTask {
  const BundleTask({
    required this.id,
    required this.title,
    this.lotId,
    this.startsAfterTaskId,
  });

  final String id;
  final String title;

  /// Tasks sharing a lot id must be bid on together and awarded to the same
  /// provider - e.g. waterproofing and tiling, where a leak turns into two
  /// trades blaming each other.
  final String? lotId;

  /// The task that must finish before this one starts. Used here only to warn
  /// when an award splits the pair between providers; the real scheduling
  /// (gap days) plays no part in choosing a winner.
  final String? startsAfterTaskId;
}

/// One provider's single package bid on a whole bundle.
class PackageBid {
  const PackageBid({
    required this.providerId,
    required this.providerName,
    required this.trustScore,
    required this.taskPrices,
    this.allOrNothing = false,
    this.bundlePriceSen,
  });

  final String providerId;
  final String providerName;

  /// 0-1000, the same scale as the app's Trust Score.
  final int trustScore;

  /// Task id -> "price if you get only this task", in sen.
  final Map<String, int> taskPrices;

  /// When true the requestor may award every task in [taskPrices] or none of
  /// them. This is what stops a provider being left holding one task they
  /// priced cheaply only because they expected to win the rest.
  final bool allOrNothing;

  /// Optional lower total, charged only when the provider wins every task in
  /// [taskPrices].
  final int? bundlePriceSen;

  /// What the tasks cost added up one by one, with no bundle discount.
  int get taskPriceTotalSen =>
      taskPrices.values.fold(0, (running, price) => running + price);
}

/// What one provider wins in an award, and what they are paid per task.
class Award {
  const Award({required this.providerId, required this.taskAmountsSen});

  final String providerId;

  /// Task id -> amount charged for that task, in sen. Each amount lands on one
  /// child job as its accepted bid amount, so the amounts must add up exactly
  /// to what the provider is owed.
  final Map<String, int> taskAmountsSen;

  int get totalSen =>
      taskAmountsSen.values.fold(0, (running, amount) => running + amount);
}

/// One option offered to the requestor.
class AwardScenario {
  const AwardScenario({
    required this.label,
    required this.awards,
    required this.uncoveredTaskIds,
    required this.weightedTrust,
    required this.premiumSen,
    required this.warnings,
  });

  final String label;
  final List<Award> awards;

  /// Tasks nobody would be awarded. The spec releases these as standalone
  /// jobs once the bundle is awarded.
  final List<String> uncoveredTaskIds;

  /// Trust Score weighted by how much money each provider is paid.
  final int weightedTrust;

  /// How much more than the cheapest option this one costs.
  final int premiumSen;

  final List<String> warnings;

  int get totalSen =>
      awards.fold(0, (running, award) => running + award.totalSen);

  int get providerCount => awards.length;
}

/// Formats sen as ringgit: 84000 becomes "RM 840.00".
String formatRm(int sen) => 'RM ${(sen / 100).toStringAsFixed(2)}';

/// Splits [bundlePriceSen] across the tasks in [taskPrices] in proportion to
/// their own prices, in whole sen that add up to exactly the bundle price.
///
/// The last task absorbs the rounding remainder, so no sen is lost or
/// invented: every child job's amount has to carry a milestone plan that
/// totals it exactly.
Map<String, int> splitBundlePrice(
  Map<String, int> taskPrices,
  int bundlePriceSen,
) {
  final taskIds = taskPrices.keys.toList();
  final priceTotal =
      taskPrices.values.fold(0, (running, price) => running + price);
  final amounts = <String, int>{};
  var allocated = 0;
  for (var i = 0; i < taskIds.length; i++) {
    final taskId = taskIds[i];
    if (i == taskIds.length - 1) {
      amounts[taskId] = bundlePriceSen - allocated;
    } else {
      final share = bundlePriceSen * taskPrices[taskId]! ~/ priceTotal;
      amounts[taskId] = share;
      allocated += share;
    }
  }
  return amounts;
}

/// Lists what is wrong with [bid] against [tasks]. An empty list means the bid
/// is valid. These are the same checks the server has to repeat before it
/// trusts a stored bid.
List<String> validatePackageBid(PackageBid bid, List<BundleTask> tasks) {
  final problems = <String>[];
  final taskById = {for (final task in tasks) task.id: task};

  if (bid.taskPrices.isEmpty) {
    problems.add('${bid.providerName} priced no tasks.');
  }

  for (final entry in bid.taskPrices.entries) {
    final task = taskById[entry.key];
    if (task == null) {
      problems.add('${bid.providerName} priced unknown task "${entry.key}".');
      continue;
    }
    if (entry.value <= 0 || entry.value > maxTaskPriceSen) {
      problems.add('${bid.providerName} priced ${task.title} outside '
          'RM 0.01 - RM 1,000,000.');
    }
  }

  // A lot must be priced whole: every task in it, or none of them.
  final lotIds = <String>{};
  for (final task in tasks) {
    if (task.lotId != null) {
      lotIds.add(task.lotId!);
    }
  }
  for (final lotId in lotIds) {
    final lotTaskIds =
        tasks.where((task) => task.lotId == lotId).map((task) => task.id);
    final pricedCount = lotTaskIds.where(bid.taskPrices.containsKey).length;
    if (pricedCount > 0 && pricedCount < lotTaskIds.length) {
      problems.add('${bid.providerName} must price all ${lotTaskIds.length} '
          'tasks of lot "$lotId", or none of them.');
    }
  }

  final bundlePrice = bid.bundlePriceSen;
  if (bundlePrice != null) {
    if (bundlePrice >= bid.taskPriceTotalSen) {
      problems.add('${bid.providerName} bundle price must be lower than the '
          'task prices added up.');
    }
    if (bundlePrice < bid.taskPrices.length) {
      problems.add('${bid.providerName} bundle price is too small to leave '
          'every task at least 1 sen.');
    }
  }

  return problems;
}
