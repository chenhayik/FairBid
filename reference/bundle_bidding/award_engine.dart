// Choosing who wins which task in a bundle.
//
// The engine answers two questions from docs/BUNDLE_BIDDING.md:
//  * what are the three options to show the requestor (Cheapest, Fewest
//    providers, Recommended)?
//  * is an award the requestor assembled by hand actually allowed, and what
//    does it cost?
//
// Everything is pure Dart, so it runs without Firebase. In the app this logic
// belongs in the `previewBundleAward` and `awardBundle` Cloud Functions, so
// the prices come from stored bids rather than from the client.

import 'models.dart';

/// How much more than the cheapest award the requestor is offered in exchange
/// for using fewer providers. Both limits apply and the smaller one wins.
///
/// In the app these two numbers live in `PlatformConfig`, with the Cloud
/// Function keeping its own copy in sync. The 5% start comes from the research
/// note in the spec; the ringgit ceiling is still an open decision, so RM 200
/// here is a placeholder.
class ConsolidationCap {
  const ConsolidationCap({this.percent = 5, this.ceilingSen = 20000});

  final int percent;
  final int ceilingSen;

  /// The most a fewer-provider option may cost above [cheapestSen].
  int allowanceSen(int cheapestSen) {
    final byPercent = cheapestSen * percent ~/ 100;
    return byPercent < ceilingSen ? byPercent : ceilingSen;
  }
}

/// The result of checking an award the requestor picked by hand.
class ManualAwardCheck {
  const ManualAwardCheck({required this.awards, required this.problems});

  final List<Award> awards;
  final List<String> problems;

  bool get isValid => problems.isEmpty;
}

/// One thing a provider is willing to be awarded: a set of tasks at a price.
class _Offer {
  const _Offer({
    required this.providerId,
    required this.taskAmountsSen,
    required this.taskMask,
    required this.priceSen,
  });

  final String providerId;
  final Map<String, int> taskAmountsSen;

  /// Which tasks this offer covers, one bit per task.
  final int taskMask;
  final int priceSen;
}

/// A part-built award, while the engine works through the bids.
class _Partial {
  const _Partial({required this.costSen, required this.awards});

  final int costSen;
  final List<Award> awards;
}

/// Builds the three options the requestor chooses between.
///
/// Coverage comes first and money second, so an option is never cheap merely
/// because it leaves work undone. Returns an empty list when nothing can be
/// awarded at all.
List<AwardScenario> buildAwardScenarios({
  required List<BundleTask> tasks,
  required List<PackageBid> bids,
  ConsolidationCap cap = const ConsolidationCap(),
}) {
  final trustByProvider = {
    for (final bid in bids) bid.providerId: bid.trustScore,
  };
  final taskIndex = <String, int>{};
  for (var i = 0; i < tasks.length; i++) {
    taskIndex[tasks[i].id] = i;
  }

  final maskCount = 1 << tasks.length;

  // best[which tasks are covered][how many providers] = cheapest way there.
  // "Which tasks are covered" is a bit per task, so 4 tasks means 16 entries.
  var best = List.generate(
    maskCount,
    (_) => List<_Partial?>.filled(tasks.length + 1, null),
  );
  best[0][0] = const _Partial(costSen: 0, awards: []);

  // One bid at a time, reading the old table and writing a new one, so a
  // provider can never appear twice in the same award.
  for (final bid in bids) {
    final offers = _offersFor(bid, tasks, taskIndex);
    final next = List.generate(
      maskCount,
      (mask) => List<_Partial?>.of(best[mask]),
    );
    for (var mask = 0; mask < maskCount; mask++) {
      for (var providerCount = 0;
          providerCount < tasks.length;
          providerCount++) {
        final soFar = best[mask][providerCount];
        if (soFar == null) {
          continue;
        }
        for (final offer in offers) {
          if (mask & offer.taskMask != 0) {
            continue; // one of these tasks is already taken
          }
          final grownMask = mask | offer.taskMask;
          final candidate = _Partial(
            costSen: soFar.costSen + offer.priceSen,
            awards: [
              ...soFar.awards,
              Award(
                providerId: offer.providerId,
                taskAmountsSen: offer.taskAmountsSen,
              ),
            ],
          );
          if (_beats(
            candidate,
            next[grownMask][providerCount + 1],
            trustByProvider,
          )) {
            next[grownMask][providerCount + 1] = candidate;
          }
        }
      }
    }
    best = next;
  }

  // Coverage first: the most tasks any combination of these bids can cover.
  var bestCoverage = 0;
  for (var mask = 0; mask < maskCount; mask++) {
    final reachable = best[mask].any((partial) => partial != null);
    if (reachable && _countBits(mask) > bestCoverage) {
      bestCoverage = _countBits(mask);
    }
  }

  // Of the awards reaching that coverage, keep the cheapest for each number
  // of providers. Index 1 is "one provider", index 2 "two providers", and so
  // on, which is what makes "fewest providers" a simple scan from the left.
  final cheapestByProviderCount = List<_Partial?>.filled(tasks.length + 1, null);
  for (var mask = 0; mask < maskCount; mask++) {
    if (_countBits(mask) != bestCoverage) {
      continue;
    }
    for (var providerCount = 0;
        providerCount <= tasks.length;
        providerCount++) {
      final partial = best[mask][providerCount];
      if (partial == null) {
        continue;
      }
      if (_beats(
        partial,
        cheapestByProviderCount[providerCount],
        trustByProvider,
      )) {
        cheapestByProviderCount[providerCount] = partial;
      }
    }
  }

  _Partial? cheapestOrNull;
  for (final partial in cheapestByProviderCount) {
    if (partial != null && _beats(partial, cheapestOrNull, trustByProvider)) {
      cheapestOrNull = partial;
    }
  }
  if (cheapestOrNull == null) {
    return const [];
  }
  final cheapest = cheapestOrNull;

  _Partial fewestProviders = cheapest;
  for (final partial in cheapestByProviderCount) {
    if (partial != null) {
      fewestProviders = partial;
      break;
    }
  }

  // Recommended: the fewest providers whose total still sits inside the cap.
  // The cheapest award always qualifies, so this loop always finds something.
  final allowance = cap.allowanceSen(cheapest.costSen);
  var recommended = cheapest;
  for (final partial in cheapestByProviderCount) {
    if (partial == null) {
      continue;
    }
    if (partial.costSen <= cheapest.costSen + allowance) {
      recommended = partial;
      break;
    }
  }

  return [
    _toScenario(
      label: 'Cheapest',
      partial: cheapest,
      tasks: tasks,
      trustByProvider: trustByProvider,
      cheapestCostSen: cheapest.costSen,
    ),
    _toScenario(
      label: 'Fewest providers',
      partial: fewestProviders,
      tasks: tasks,
      trustByProvider: trustByProvider,
      cheapestCostSen: cheapest.costSen,
    ),
    _toScenario(
      label: 'Recommended',
      partial: recommended,
      tasks: tasks,
      trustByProvider: trustByProvider,
      cheapestCostSen: cheapest.costSen,
    ),
  ];
}

/// Prices and checks an award the requestor put together by hand, the same way
/// the server has to re-check whatever the app sends it.
///
/// [providerByTaskId] maps a task to the provider who should win it; leaving a
/// task out means "award this to nobody". Wallet balance and who owns the
/// bundle are separate server checks and are not repeated here.
ManualAwardCheck checkManualAward({
  required List<BundleTask> tasks,
  required List<PackageBid> bids,
  required Map<String, String> providerByTaskId,
}) {
  final problems = <String>[];
  final bidByProvider = {for (final bid in bids) bid.providerId: bid};
  final taskById = {for (final task in tasks) task.id: task};

  // Collect the picks per provider, so each provider is checked once.
  final taskIdsByProvider = <String, List<String>>{};
  for (final entry in providerByTaskId.entries) {
    if (!taskById.containsKey(entry.key)) {
      problems.add('Unknown task "${entry.key}".');
      continue;
    }
    taskIdsByProvider.putIfAbsent(entry.value, () => []).add(entry.key);
  }

  final awards = <Award>[];
  for (final entry in taskIdsByProvider.entries) {
    final bid = bidByProvider[entry.key];
    if (bid == null) {
      problems.add('No bid from provider "${entry.key}".');
      continue;
    }
    final wonTaskIds = entry.value;

    final unpriced =
        wonTaskIds.where((taskId) => !bid.taskPrices.containsKey(taskId));
    if (unpriced.isNotEmpty) {
      final titles =
          unpriced.map((taskId) => taskById[taskId]!.title).join(', ');
      problems.add('${bid.providerName} never priced $titles.');
      continue;
    }

    final isWholeBid = wonTaskIds.length == bid.taskPrices.length;
    if (bid.allOrNothing && !isWholeBid) {
      problems.add('${bid.providerName} bid all or nothing, so they take '
          'every task they priced or none of them.');
      continue;
    }
    if (_splitsALot(wonTaskIds, tasks)) {
      problems.add('${bid.providerName} would take only part of a lot, and '
          'tasks in a lot go to one provider.');
      continue;
    }

    final Map<String, int> amounts;
    if (isWholeBid && bid.bundlePriceSen != null) {
      amounts = splitBundlePrice(bid.taskPrices, bid.bundlePriceSen!);
    } else {
      amounts = {
        for (final taskId in wonTaskIds) taskId: bid.taskPrices[taskId]!,
      };
    }
    awards.add(Award(providerId: bid.providerId, taskAmountsSen: amounts));
  }

  return ManualAwardCheck(awards: awards, problems: problems);
}

/// Every set of tasks [bid] would accept, with the price for each set.
///
/// A bid on 3 tasks without all-or-nothing accepts any of its 7 non-empty
/// subsets, so the engine prices a partial award at the task prices and the
/// whole bid at the bundle price.
List<_Offer> _offersFor(
  PackageBid bid,
  List<BundleTask> tasks,
  Map<String, int> taskIndex,
) {
  final pricedTaskIds = bid.taskPrices.keys.toList();
  final offers = <_Offer>[];
  final subsetCount = 1 << pricedTaskIds.length;

  for (var subset = 1; subset < subsetCount; subset++) {
    final chosenTaskIds = <String>[];
    for (var i = 0; i < pricedTaskIds.length; i++) {
      if ((subset >> i) & 1 == 1) {
        chosenTaskIds.add(pricedTaskIds[i]);
      }
    }

    final isWholeBid = chosenTaskIds.length == pricedTaskIds.length;
    if (bid.allOrNothing && !isWholeBid) {
      continue;
    }
    if (_splitsALot(chosenTaskIds, tasks)) {
      continue;
    }

    final Map<String, int> amounts;
    if (isWholeBid && bid.bundlePriceSen != null) {
      amounts = splitBundlePrice(bid.taskPrices, bid.bundlePriceSen!);
    } else {
      amounts = {
        for (final taskId in chosenTaskIds) taskId: bid.taskPrices[taskId]!,
      };
    }

    var mask = 0;
    for (final taskId in chosenTaskIds) {
      mask |= 1 << taskIndex[taskId]!;
    }

    offers.add(_Offer(
      providerId: bid.providerId,
      taskAmountsSen: amounts,
      taskMask: mask,
      priceSen: amounts.values.fold(0, (running, amount) => running + amount),
    ));
  }

  return offers;
}

/// True when [chosenTaskIds] takes part of a lot but not all of it.
bool _splitsALot(List<String> chosenTaskIds, List<BundleTask> tasks) {
  final chosen = chosenTaskIds.toSet();
  final lotIds = <String>{};
  for (final task in tasks) {
    if (task.lotId != null) {
      lotIds.add(task.lotId!);
    }
  }
  for (final lotId in lotIds) {
    final lotTaskIds =
        tasks.where((task) => task.lotId == lotId).map((task) => task.id);
    final takenCount = lotTaskIds.where(chosen.contains).length;
    if (takenCount > 0 && takenCount < lotTaskIds.length) {
      return true;
    }
  }
  return false;
}

/// Turns a part-built award into the card the requestor sees.
AwardScenario _toScenario({
  required String label,
  required _Partial partial,
  required List<BundleTask> tasks,
  required Map<String, int> trustByProvider,
  required int cheapestCostSen,
}) {
  final providerByTaskId = <String, String>{};
  for (final award in partial.awards) {
    for (final taskId in award.taskAmountsSen.keys) {
      providerByTaskId[taskId] = award.providerId;
    }
  }

  final uncovered = [
    for (final task in tasks)
      if (!providerByTaskId.containsKey(task.id)) task.id,
  ];

  final warnings = <String>[];
  for (final task in tasks) {
    final earlierTaskId = task.startsAfterTaskId;
    if (earlierTaskId == null) {
      continue;
    }
    final thisProvider = providerByTaskId[task.id];
    final earlierProvider = providerByTaskId[earlierTaskId];
    if (thisProvider == null ||
        earlierProvider == null ||
        thisProvider == earlierProvider) {
      continue;
    }
    final earlierTitle =
        tasks.firstWhere((other) => other.id == earlierTaskId).title;
    warnings.add('${task.title} starts after $earlierTitle, but they go to '
        'different providers.');
  }

  return AwardScenario(
    label: label,
    awards: partial.awards,
    uncoveredTaskIds: uncovered,
    weightedTrust: _weightedTrust(partial.awards, trustByProvider),
    premiumSen: partial.costSen - cheapestCostSen,
    warnings: warnings,
  );
}

/// Trust Score weighted by how much money each provider is paid, so the
/// provider doing RM 800 of work counts for more than one doing RM 100.
int _weightedTrust(List<Award> awards, Map<String, int> trustByProvider) {
  var moneyTotal = 0;
  var weighted = 0;
  for (final award in awards) {
    final trust = trustByProvider[award.providerId] ?? 0;
    moneyTotal += award.totalSen;
    weighted += trust * award.totalSen;
  }
  if (moneyTotal == 0) {
    return 0;
  }
  return weighted ~/ moneyTotal;
}

/// True when [candidate] is the better award: cheaper wins, and on an exact
/// tie the one whose providers carry the higher weighted Trust Score.
bool _beats(
  _Partial candidate,
  _Partial? existing,
  Map<String, int> trustByProvider,
) {
  if (existing == null) {
    return true;
  }
  if (candidate.costSen != existing.costSen) {
    return candidate.costSen < existing.costSen;
  }
  return _weightedTrust(candidate.awards, trustByProvider) >
      _weightedTrust(existing.awards, trustByProvider);
}

/// How many tasks a coverage mask holds, i.e. how many bits are set.
int _countBits(int value) {
  var count = 0;
  var rest = value;
  while (rest != 0) {
    count += rest & 1;
    rest >>= 1;
  }
  return count;
}
