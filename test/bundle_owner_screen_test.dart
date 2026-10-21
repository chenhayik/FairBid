import 'package:fairbid/core/theme/app_theme.dart';
import 'package:fairbid/features/jobs/data/bundle_bid_repository.dart';
import 'package:fairbid/features/jobs/data/bundle_repository.dart';
import 'package:fairbid/features/jobs/domain/bundle.dart';
import 'package:fairbid/features/jobs/domain/bundle_award.dart';
import 'package:fairbid/features/jobs/domain/bundle_bid.dart';
import 'package:fairbid/features/jobs/domain/job.dart';
import 'package:fairbid/features/jobs/presentation/bundle/bundle_option_card.dart';
import 'package:fairbid/features/jobs/presentation/bundle/bundle_pick_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/builders.dart';
import 'helpers/fakes.dart';
import 'helpers/harness.dart';

BundleAwardOption _option(
  String label,
  Map<String, String> providerByTask, {
  int totalSen = 30000,
}) => sampleOption(key: label, label: label, totalSen: totalSen, awards: [
    for (final entry in providerByTask.entries)
      BundleAwardItem(
        providerId: entry.value,
        providerName: entry.value,
        taskAmountsSen: {entry.key: 1000},
      ),
  ]);

void main() {
  final tasks = [
    sampleJob(
      id: 'job-1',
      title: 'Waterproof the floor',
      bundleId: 'b1',
      bundleOrder: 0,
      bundleTaskCount: 2,
    ),
    sampleJob(
      id: 'job-2',
      title: 'Tile the floor',
      bundleId: 'b1',
      bundleOrder: 1,
      bundleTaskCount: 2,
    ),
  ];

  /// Pumps [BundleDetailScreen] behind a nested route (so `context.pop()`
  /// and task/profile pushes have somewhere to go) with the given bundle,
  /// tasks and bids. Passing [bundleBids] lets a test use the live fake
  /// above instead of the static shared one.
  Future<FakeBundleRepository> pumpBundle(
    WidgetTester tester, {
    Bundle? bundle,
    List<Job>? tasksOverride,
    BundleBidRepository? bundleBids,
    List<BundleBid> bids = const [],
    List<BundleAwardOption> awardOptions = const [],
  }) async {
    final bundles = FakeBundleRepository([
      bundle ?? sampleBundle(id: 'b1', taskIds: const ['job-1', 'job-2']),
    ])..awardOptions = awardOptions;
    await pumpOwnerBundleScreen(
      tester,
      bundles: bundles,
      tasks: tasksOverride ?? tasks,
      bundleBids: bundleBids ?? FakeBundleBidRepository(bids),
    );
    return bundles;
  }

  group('Bundle header', () {
    testWidgets('shows the description, the deadline and a wrapped pill', (
      tester,
    ) async {
      final pastDeadline = DateTime.now().subtract(const Duration(days: 1));
      await pumpBundle(
        tester,
        bundle: sampleBundle(
          id: 'b1',
          taskIds: const ['job-1', 'job-2'],
          deadline: pastDeadline,
        ),
      );

      expect(
        find.textContaining('Small bathroom, about 4 square metres.'),
        findsOneWidget,
      );
      expect(find.textContaining('Bidding closed'), findsWidgets);
      // Still nominally "open" in storage, but the deadline has passed, so
      // the pill reads "Closed" rather than "Open".
      expect(find.text('Closed'), findsOneWidget);
      expect(find.text('Open'), findsNothing);
    });

    testWidgets('a future deadline reads "Bidding closes" while open', (
      tester,
    ) async {
      await pumpBundle(
        tester,
        bundle: sampleBundle(
          id: 'b1',
          taskIds: const ['job-1', 'job-2'],
          deadline: DateTime.now().add(const Duration(days: 3)),
        ),
      );

      expect(find.textContaining('Bidding closes'), findsOneWidget);
    });

    testWidgets('an awarded bundle shows no deadline line at all', (
      tester,
    ) async {
      await pumpBundle(
        tester,
        bundle: sampleBundle(
          id: 'b1',
          taskIds: const ['job-1', 'job-2'],
          status: BundleStatus.awarded,
          deadline: DateTime.now().add(const Duration(days: 3)),
        ),
      );

      expect(find.textContaining('Bidding closes'), findsNothing);
      expect(find.textContaining('Bidding closed'), findsNothing);
    });

    testWidgets('an open bundle within its deadline reads "Open"', (
      tester,
    ) async {
      await pumpBundle(tester);
      expect(find.text('Open'), findsOneWidget);
      expect(find.text('Closed'), findsNothing);
    });
  });

  group('Cancel bundle', () {
    testWidgets('the owner can cancel an open bundle, before or after the '
        'deadline', (tester) async {
      final bundles = await pumpBundle(
        tester,
        bundle: sampleBundle(
          id: 'b1',
          taskIds: const ['job-1', 'job-2'],
          deadline: DateTime.now().subtract(const Duration(days: 1)),
        ),
      );

      await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel bundle'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Cancel bundle'));
      await tester.pumpAndSettle();

      expect(bundles.cancelled, ['b1']);
    });

    testWidgets('a rejected cancel shows the server message', (tester) async {
      final bundles = await pumpBundle(tester);
      bundles.cancelError = const BundleRejectedException(
        'Too late to cancel.',
      );

      await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel bundle'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Cancel bundle'));
      await tester.pumpAndSettle();

      expect(find.text('Too late to cancel.'), findsOneWidget);
    });

    testWidgets('not shown once the bundle is awarded', (tester) async {
      await pumpBundle(
        tester,
        bundle: sampleBundle(id: 'b1', status: BundleStatus.awarded),
      );
      expect(find.widgetWithText(OutlinedButton, 'Cancel bundle'), findsNothing);
    });
  });

  group('Awarded bundle', () {
    testWidgets('shows each task\'s own outcome instead of the bid list, and '
        'hides the Award section', (tester) async {
      final awardedTasks = [
        sampleJob(
          id: 'job-1',
          title: 'Waterproof the floor',
          bundleId: 'b1',
          status: JobStatus.inProgress,
          acceptedProviderId: 'prov-1',
          acceptedProviderName: 'Aida Renovation',
          acceptedBidAmountSen: 37500,
        ),
        sampleJob(
          id: 'job-2',
          title: 'Tile the floor',
          bundleId: 'b1',
          status: JobStatus.open,
          releasedAt: DateTime.now(),
        ),
      ];
      await pumpBundle(
        tester,
        bundle: sampleBundle(id: 'b1', status: BundleStatus.awarded),
        tasksOverride: awardedTasks,
      );

      // Category, status and winner share one line.
      expect(find.textContaining('Aida Renovation', findRichText: true),
          findsOneWidget);
      expect(find.textContaining('RM 375.00'), findsOneWidget);
      expect(
        find.textContaining('Released to ordinary bidding', findRichText: true),
        findsOneWidget,
      );
      expect(find.text('Award'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Show award options'),
          findsNothing);

      await tester.tap(find.text('Waterproof the floor'));
      await tester.pumpAndSettle();
      expect(find.text('Job detail: job-1'), findsOneWidget);
    });
  });

  group('Bids list after the award', () {
    testWidgets('each bid card shows its own outcome pill, and a pending bid '
        'shows none', (tester) async {
      BundleBid withStatus(
        String id,
        String name,
        BundleBidStatus status,
      ) => sampleBundleBid(providerId: id, providerName: name, taskPrices: const {'job-1': 37500}, status: status);
      await pumpBundle(
        tester,
        bundle: sampleBundle(id: 'b1', status: BundleStatus.awarded),
        bids: [
          withStatus('p1', 'Aida Renovation', BundleBidStatus.accepted),
          withStatus('p2', 'Dev Tiling', BundleBidStatus.rejected),
          withStatus('p3', 'Lim Plumbing', BundleBidStatus.partlyAccepted),
          withStatus('p4', 'Sam Paint', BundleBidStatus.closed),
        ],
      );

      await tester.tap(find.text('View all bids (4)'));
      await tester.pumpAndSettle();
      for (final label in [
        'Accepted',
        'Rejected',
        'Partly accepted',
        'Closed',
      ]) {
        await tester.ensureVisible(find.text(label));
        expect(find.text(label), findsOneWidget);
      }
      expect(find.text('Pending'), findsNothing);
    });
  });

  group('Merged award options', () {
    testWidgets('two options with the same award are shown as one card', (
      tester,
    ) async {
      final cheapest = sampleOption(key: 'cheapest', label: 'Lowest total', uncoveredTaskIds: ['job-2']);
      final fewest = sampleOption(key: 'fewest', label: 'Fewest providers', uncoveredTaskIds: ['job-2']);
      final bestValue = sampleOption(totalSen: 89500, providerCount: 2, weightedTrust: 751, awards: [
          BundleAwardItem(
            providerId: 'prov-1',
            providerName: 'Aida Renovation',
            taskAmountsSen: {'job-1': 37500},
          ),
          BundleAwardItem(
            providerId: 'prov-2',
            providerName: 'Dev Tiling',
            taskAmountsSen: {'job-2': 52000},
          ),
        ]);

      await pumpBundle(
        tester,
        bids: [sampleBundleBid(), sampleBundleBid(providerId: 'prov-2', providerName: 'Dev Tiling')],
        awardOptions: [cheapest, fewest, bestValue],
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Show award options'));
      await tester.pumpAndSettle();

      expect(find.text('Compare award options'), findsOneWidget);
      expect(
        find.text('Each option covers as many tasks as the bids allow. '
            'Compare total price, number of providers and Trust Score.'),
        findsOneWidget,
      );
      expect(find.text('Lowest total · Fewest providers'), findsOneWidget);
      expect(find.text('Best Value'), findsOneWidget);
      // Each card explains itself; a merged card shows its top-priority line.
      expect(find.text('The cheapest way to cover every task.'),
          findsOneWidget);
      expect(
        find.text('Balances total price (60%) and Trust Score (40%), the same '
            'as single jobs.'),
        findsOneWidget,
      );
      // Only the Best Value card gets the filled Award button; the merged
      // one is outlined.
      expect(find.widgetWithText(FilledButton, 'Award this option'),
          findsOneWidget);
      expect(
        find.widgetWithText(OutlinedButton, 'Award this option'),
        findsOneWidget,
      );
    });
  });

  group('Stale award options', () {
    testWidgets('an edited bid disables Award until Refresh is pressed', (
      tester,
    ) async {
      final bestValue = sampleOption(totalSen: 89500, awards: [
          BundleAwardItem(
            providerId: 'prov-1',
            providerName: 'Aida Renovation',
            taskAmountsSen: {'job-1': 37500, 'job-2': 52000},
          ),
        ]);
      final live = FakeBundleBidRepository()..push([sampleBundleBid()]);
      final bundles = await pumpBundle(
        tester,
        bundleBids: live,
        awardOptions: [bestValue],
      );

      await tester.tap(find.widgetWithText(FilledButton, 'Show award options'));
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(FilledButton, 'Award this option'),
        findsOneWidget,
      );

      // The provider edits their bid - createdAt is unchanged, but the price
      // and updatedAt move on.
      final edited = sampleBundleBid(taskPrices: const {'job-1': 30000, 'job-2': 52000}, createdAt: sampleBundleBid().createdAt, updatedAt: DateTime.now());
      live.push([edited]);
      await tester.pumpAndSettle();

      expect(find.textContaining('bids have changed'), findsOneWidget);
      final awardButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Award this option'),
      );
      expect(awardButton.onPressed, isNull);

      bundles.awardOptions = [bestValue];
      await tester.tap(find.widgetWithText(TextButton, 'Refresh'));
      await tester.pumpAndSettle();

      final refreshedButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Award this option'),
      );
      expect(refreshedButton.onPressed, isNotNull);
    });
  });

  group('Manual pick section', () {
    testWidgets('hidden entirely when nobody has bid yet', (tester) async {
      await pumpBundle(tester, bids: const []);
      expect(find.text('Pick providers yourself'), findsNothing);
    });

    testWidgets('the sticky bar only appears once a task is picked', (
      tester,
    ) async {
      await pumpBundle(tester, bids: [sampleBundleBid()]);
      expect(find.text('Award your pick'), findsNothing);

      await tester.tap(find.text('Waterproof the floor'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Aida Renovation').last);
      await tester.pumpAndSettle();

      expect(find.text('Award your pick'), findsOneWidget);
    });
  });

  group('Plurals', () {
    testWidgets('the summary line reads "1 task" and "1 bid" in the '
        'singular', (tester) async {
      await pumpBundle(
        tester,
        bundle: sampleBundle(id: 'b1', taskIds: const ['job-1']),
        tasksOverride: [tasks.first],
        bids: [sampleBundleBid()],
      );
      expect(find.textContaining('1 task'), findsOneWidget);
      expect(find.textContaining('1 bid'), findsOneWidget);
    });
  });
  group('Package price and trust on the bundle page', () {
    for (final (name, accepted, original, shown) in [
      ('an awarded task split by a package deal says so', 93334, null, true),
      ('no package note once the price was changed later', 100000, 93334, false),
    ]) {
      testWidgets(name, (tester) async {
        await pumpBundle(
          tester,
          bundle: sampleBundle(id: 'b1', status: BundleStatus.awarded),
          tasksOverride: [
            sampleJob(
              id: 'job-1',
              title: 'Broken roof tiles',
              bundleId: 'b1',
              status: JobStatus.inProgress,
              acceptedProviderId: 'p1',
              acceptedProviderName: 'Worker One',
              acceptedBidAmountSen: accepted,
              originalBidAmountSen: original,
            ),
          ],
          bids: [
            sampleBundleBid(
              providerId: 'p1',
              providerName: 'Worker One',
              taskPrices: const {'job-1': 100000, 'job-2': 50000},
              bundlePriceSen: 140000,
              status: BundleBidStatus.accepted,
            ),
          ],
        );

        expect(
          find.textContaining('Package deal price'),
          shown ? findsOneWidget : findsNothing,
        );
        if (shown) {
          expect(find.textContaining('1,000.00 if hired for this task alone'),
              findsOneWidget);
        }
      });
    }

    Future<void> pumpCard(WidgetTester tester, {required bool visible}) async {
      final option = sampleOption(totalSen: 140000, weightedTrust: 608, trustVisible: visible, awards: const []);
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: SingleChildScrollView(
            child: BundleOptionCard(
              merged: MergedBundleOption(option, const ['Best Value']),
              tasks: const [],
              primary: true,
              busy: false,
              enabled: true,
              onAward: () {},
            ),
          ),
        ),
      ));
    }

    testWidgets('trust reads out of 100 when every provider has a score', (
      tester,
    ) async {
      await pumpCard(tester, visible: true);
      expect(find.textContaining('Trust 61/100'), findsOneWidget);
    });

    testWidgets('trust is hidden while any provider is new', (tester) async {
      await pumpCard(tester, visible: false);
      expect(find.textContaining('/100'), findsNothing);
      expect(find.textContaining('Includes a new provider'), findsOneWidget);
    });

    testWidgets('every card shows total, premium, providers and trust', (
      tester,
    ) async {
      final lowest = sampleOption(
        key: 'cheapest',
        label: 'Lowest total',
        totalSen: 100000,
        weightedTrust: 700,
        trustVisible: true,
      );
      final pricier = sampleOption(
        key: 'bestValue',
        label: 'Best Value',
        totalSen: 110000,
        premiumSen: 10000,
        providerCount: 2,
        weightedTrust: 850,
        trustVisible: true,
        awards: const [
          BundleAwardItem(
            providerId: 'prov-2',
            providerName: 'Dev Tiling',
            taskAmountsSen: {'job-1': 110000},
          ),
        ],
      );
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: SingleChildScrollView(
            child: Column(
              children: [
                for (final merged in mergeBundleOptions([lowest, pricier]))
                  BundleOptionCard(
                    merged: merged,
                    tasks: const [],
                    primary: merged.isBestValue,
                    busy: false,
                    enabled: true,
                    onAward: () {},
                  ),
              ],
            ),
          ),
        ),
      ));

      expect(find.text('RM 1,000.00'), findsOneWidget);
      // The 2nd total also appears as that provider's row.
      expect(find.text('RM 1,100.00'), findsWidgets);
      expect(find.textContaining('1 provider  •  Lowest  •  Trust 70/100'),
          findsOneWidget);
      expect(
        find.textContaining(
            '2 providers  •  +RM 100.00 vs lowest  •  Trust 85/100'),
        findsOneWidget,
      );
      expect(find.text('The cheapest way to cover every task.'),
          findsOneWidget);
    });

    test('a merged card keys off bestValue, not the label text', () {
      final merged = mergeBundleOptions([
        sampleOption(key: 'cheapest', label: 'Lowest total'),
        sampleOption(key: 'bestValue', label: 'Anything'),
      ]).single;
      expect(merged.combinedLabel, 'Lowest total · Anything');
      expect(merged.isBestValue, isTrue);
      expect(merged.explanation, startsWith('Balances total price (60%)'));

      final other = mergeBundleOptions([
        sampleOption(key: 'fewest', label: 'Best Value'),
      ]).single;
      expect(other.isBestValue, isFalse);
    });
  });

  group('Award layout', () {
    final tasks = [
      sampleJob(id: 'job-1', title: 'Waterproof the floor', bundleId: 'b1'),
      sampleJob(id: 'job-2', title: 'Tile the floor', bundleId: 'b1'),
      sampleJob(id: 'job-3', title: 'Paint the wall', bundleId: 'b1'),
      sampleJob(id: 'job-4', title: 'Seal the wall', bundleId: 'b1'),
    ];
    final aida = sampleBundleBid(taskPrices: {
      'job-1': 37500,
      'job-2': 52000,
      'job-3': 10000,
      'job-4': 12000,
    }, bundlePriceSen: 100000);
    // Dev bids on only two of the four tasks.
    final dev = sampleBundleBid(providerId: 'prov-2', providerName: 'Dev Tiling', taskPrices: {'job-1': 30000, 'job-3': 9000});

    Future<FakeBundleRepository> pump(
      WidgetTester tester, {
      List<BundleAwardOption> awardOptions = const [],
      BundleAwardOption? manualOption,
    }) async {
      final bundles =
          FakeBundleRepository([
              sampleBundle(
                id: 'b1',
                taskIds: const ['job-1', 'job-2', 'job-3', 'job-4'],
              ),
            ])
            ..awardOptions = awardOptions
            ..manualOption = manualOption;
      await pumpOwnerBundleScreen(
        tester,
        bundles: bundles,
        tasks: tasks,
        bundleBids: FakeBundleBidRepository([aida, dev]),
        size: const Size(800, 2400),
      );
      return bundles;
    }

    group('By-task pick list', () {
      testWidgets('rows show the current pick, "Not awarded" at first', (
        tester,
      ) async {
        await pump(tester);
        expect(find.text('Pick providers yourself'), findsOneWidget);
        // One row per task.
        expect(find.text('Not awarded'), findsNWidgets(4));
        expect(find.text('Your pick'), findsNothing);
      });

      testWidgets('tapping a row lists bids cheapest first; choosing one '
          'sets the pick and prices it', (tester) async {
        final bundles = await pump(
          tester,
          manualOption: _option('Your pick', {'job-1': 'prov-2'}),
        );

        await tester.tap(find.text('Waterproof the floor'));
        await tester.pumpAndSettle();

        final dev = tester.getTopLeft(find.text('Dev Tiling')).dy;
        final aida = tester.getTopLeft(find.text('Aida Renovation')).dy;
        expect(dev, lessThan(aida));
        expect(find.text('Lowest price'), findsOneWidget);
        expect(
          find.textContaining('if they win all 4 tasks'),
          findsOneWidget,
        );
        expect(find.text("Don't award"), findsOneWidget);

        await tester.tap(find.text('Dev Tiling'));
        await tester.pumpAndSettle();

        expect(bundles.lastManualPicks, {'job-1': 'prov-2'});
        // The row now reads the provider, and the bar shows the server total.
        expect(find.text('Dev Tiling'), findsOneWidget);
        expect(find.textContaining('Your pick: RM'), findsOneWidget);
        expect(find.text('Award your pick'), findsOneWidget);
      });

      testWidgets('"Use this option" fills the picks from that option', (
        tester,
      ) async {
        final bundles = await pump(
          tester,
          awardOptions: [
            _option('Best Value', {'job-1': 'prov-2', 'job-2': 'prov-1'}),
          ],
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Show award options'));
        await tester.pumpAndSettle();

        await tester.tap(find.widgetWithText(OutlinedButton, 'Use this option'));
        await tester.pumpAndSettle();

        expect(bundles.lastManualPicks, {'job-1': 'prov-2', 'job-2': 'prov-1'});
        expect(find.text('Dev Tiling'), findsOneWidget);
        expect(find.text('Aida Renovation'), findsOneWidget);
      });

      testWidgets('picking part of a bundle-price bid shows the hint', (
        tester,
      ) async {
        await pump(tester);
        await tester.tap(find.text('Tile the floor'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Aida Renovation'));
        await tester.pumpAndSettle();

        expect(find.textContaining('drops their bundle price'), findsOneWidget);
      });
    });

    group('Bids section', () {
      testWidgets('opens every bid in a sheet from the top button', (
        tester,
      ) async {
        await pump(tester);
        expect(find.text('View all bids (2)'), findsOneWidget);
        expect(find.textContaining('Bundle price (all tasks)'), findsNothing);

        await tester.tap(find.text('View all bids (2)'));
        await tester.pumpAndSettle();
        expect(find.textContaining('Bundle price (all tasks)'), findsOneWidget);
      });
    });

    group('pickHints', () {
      final bids = [aida, dev];

      test('no hints when the bundle bid is won in full or not at all', () {
        expect(pickHints({}, bids), isEmpty);
        expect(
          pickHints({
            'job-1': 'prov-1',
            'job-2': 'prov-1',
            'job-3': 'prov-1',
            'job-4': 'prov-1',
          }, bids),
          isEmpty,
        );
      });

      test('warns when a bundle price is dropped', () {
        final hints = pickHints(
          {'job-1': 'prov-1'},
          [sampleBundleBid(providerName: 'Aida', taskPrices: {'job-1': 1, 'job-2': 2}, bundlePriceSen: 2)],
        );
        expect(hints, [
          "Picking fewer than all of Aida's tasks drops their bundle price.",
        ]);
      });
    });
  });
}
