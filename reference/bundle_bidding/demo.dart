// A runnable walk-through of the bundle award rules.
//
// Run it with:  dart run reference/bundle_bidding/demo.dart
//
// It builds one bathroom-renovation bundle, prints the bids, then prints the
// three award options, a bundle where one task attracts no bids, and three
// awards the requestor picks by hand (one allowed, two refused).
//
// The demo writes to stdout, which the project's lints discourage inside the
// app, so print is allowed just for this file.
// ignore_for_file: avoid_print

import 'award_engine.dart';
import 'models.dart';

void main() {
  final tasks = _bathroomTasks();
  final bids = _bathroomBids();

  print('=== The bundle ===');
  for (final task in tasks) {
    final lot = task.lotId == null ? '' : '  [lot ${task.lotId}]';
    final after = task.startsAfterTaskId == null
        ? ''
        : '  (starts after ${task.startsAfterTaskId})';
    print('  ${task.id.padRight(12)} ${task.title}$lot$after');
  }

  print('');
  print('=== Bids ===');
  _printBidMatrix(tasks, bids);

  final problems = <String>[];
  for (final bid in bids) {
    problems.addAll(validatePackageBid(bid, tasks));
  }
  print('');
  print(problems.isEmpty
      ? 'Bid validation: every bid is valid.'
      : 'Bid validation: ${problems.join(' ')}');

  print('');
  print('=== Award options ===');
  _printScenarios(buildAwardScenarios(tasks: tasks, bids: bids), tasks, bids);

  print('');
  print('=== Coverage gap: only the plumber and the tiler bid ===');
  final thinBids = bids
      .where((bid) => bid.providerId == 'budi' || bid.providerId == 'dev')
      .toList();
  _printScenarios(
    buildAwardScenarios(tasks: tasks, bids: thinBids),
    tasks,
    thinBids,
  );

  print('');
  print('=== Awards the requestor picks by hand ===');
  _printManualCheck('Split by trade', tasks, bids, {
    'plumbing': 'budi',
    'electrical': 'chandran',
    'waterproof': 'dev',
    'tiling': 'dev',
  });
  _printManualCheck('Just the tiling, from Dev', tasks, bids, {
    'tiling': 'dev',
  });
  _printManualCheck('Plumbing, from the electrician', tasks, bids, {
    'plumbing': 'chandran',
  });
}

/// A four-task bathroom bundle. Waterproofing and tiling form a lot, so they
/// always go to one provider; waterproofing follows the plumbing.
List<BundleTask> _bathroomTasks() => const [
      BundleTask(id: 'plumbing', title: 'Plumbing rough-in'),
      BundleTask(id: 'electrical', title: 'Electrical points'),
      BundleTask(
        id: 'waterproof',
        title: 'Waterproofing',
        lotId: 'wetWorks',
        startsAfterTaskId: 'plumbing',
      ),
      BundleTask(
        id: 'tiling',
        title: 'Tiling',
        lotId: 'wetWorks',
        startsAfterTaskId: 'waterproof',
      ),
    ];

/// One generalist who prices everything and offers a bundle discount, two
/// single-trade specialists, and a tiler who only wants the wet works as a
/// package.
List<PackageBid> _bathroomBids() => const [
      PackageBid(
        providerId: 'aida',
        providerName: 'Aida Renovation',
        trustScore: 820,
        taskPrices: {
          'plumbing': 18500,
          'electrical': 19000,
          'waterproof': 25000,
          'tiling': 33000,
        },
        bundlePriceSen: 90000,
      ),
      PackageBid(
        providerId: 'budi',
        providerName: 'Budi Plumbing',
        trustScore: 760,
        taskPrices: {'plumbing': 18000},
      ),
      PackageBid(
        providerId: 'chandran',
        providerName: 'Chandran Electrical',
        trustScore: 900,
        taskPrices: {'electrical': 16000},
      ),
      PackageBid(
        providerId: 'dev',
        providerName: 'Dev Tiling Works',
        trustScore: 700,
        taskPrices: {'waterproof': 22000, 'tiling': 30000},
        allOrNothing: true,
        bundlePriceSen: 50000,
      ),
    ];

/// Prints the provider-by-task price grid the requestor would see.
void _printBidMatrix(List<BundleTask> tasks, List<PackageBid> bids) {
  final header = StringBuffer('Provider'.padRight(22));
  for (final task in tasks) {
    header.write(task.title.padLeft(20));
  }
  print(header);

  for (final bid in bids) {
    final row = StringBuffer(bid.providerName.padRight(22));
    for (final task in tasks) {
      final price = bid.taskPrices[task.id];
      row.write((price == null ? '-' : formatRm(price)).padLeft(20));
    }
    final notes = <String>[];
    if (bid.allOrNothing) {
      notes.add('all or nothing');
    }
    if (bid.bundlePriceSen != null) {
      notes.add('all its tasks for ${formatRm(bid.bundlePriceSen!)}');
    }
    if (notes.isNotEmpty) {
      row.write('   (${notes.join('; ')})');
    }
    print(row);
  }
}

/// Prints each award option with its price, providers, trust and warnings.
void _printScenarios(
  List<AwardScenario> scenarios,
  List<BundleTask> tasks,
  List<PackageBid> bids,
) {
  if (scenarios.isEmpty) {
    print('  Nothing was bid on, so there is nothing to award.');
    return;
  }

  final taskTitles = {for (final task in tasks) task.id: task.title};
  final providerNames = {
    for (final bid in bids) bid.providerId: bid.providerName,
  };
  final cheapestTotal = scenarios.first.totalSen;

  for (final scenario in scenarios) {
    final percent =
        cheapestTotal == 0 ? 0.0 : scenario.premiumSen * 100 / cheapestTotal;
    final extra = scenario.premiumSen == 0
        ? ''
        : '  +${formatRm(scenario.premiumSen)} '
            '(${percent.toStringAsFixed(1)}%)';
    print('${scenario.label.padRight(18)}'
        '${formatRm(scenario.totalSen).padLeft(11)}'
        '  ${scenario.providerCount} provider(s)'
        '  trust ${scenario.weightedTrust}$extra');

    for (final award in scenario.awards) {
      final pieces = award.taskAmountsSen.entries
          .map((entry) => '${taskTitles[entry.key]} ${formatRm(entry.value)}')
          .join(' + ');
      print('    ${providerNames[award.providerId]}: $pieces');
    }
    for (final taskId in scenario.uncoveredTaskIds) {
      print('    left open: ${taskTitles[taskId]}');
    }
    for (final warning in scenario.warnings) {
      print('    warning: $warning');
    }
  }
}

/// Runs one hand-picked award through the same checks the server would use.
void _printManualCheck(
  String label,
  List<BundleTask> tasks,
  List<PackageBid> bids,
  Map<String, String> providerByTaskId,
) {
  final check = checkManualAward(
    tasks: tasks,
    bids: bids,
    providerByTaskId: providerByTaskId,
  );
  final taskTitles = {for (final task in tasks) task.id: task.title};
  final providerNames = {
    for (final bid in bids) bid.providerId: bid.providerName,
  };

  print('$label:');
  if (check.isValid) {
    for (final award in check.awards) {
      final pieces = award.taskAmountsSen.entries
          .map((entry) => '${taskTitles[entry.key]} ${formatRm(entry.value)}')
          .join(' + ');
      print('    allowed - ${providerNames[award.providerId]}: $pieces');
    }
  } else {
    for (final problem in check.problems) {
      print('    refused - $problem');
    }
  }
}
