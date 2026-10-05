// The owner's bundle award screen: award options, the by-task pick list with
// its bids sheet, the pick hints, and the collapsed bids section. Reuses the
// fakes in widget_test.dart.
import 'package:fairbid/core/theme/app_theme.dart';
import 'package:fairbid/features/auth/domain/user_role.dart';
import 'package:fairbid/features/auth/presentation/auth_controller.dart';
import 'package:fairbid/features/jobs/data/bundle_bid_repository.dart';
import 'package:fairbid/features/jobs/data/bundle_repository.dart';
import 'package:fairbid/features/jobs/data/job_repository.dart';
import 'package:fairbid/features/jobs/domain/bundle_award.dart';
import 'package:fairbid/features/jobs/domain/bundle_bid.dart';
import 'package:fairbid/features/jobs/presentation/bundle/bundle_detail_screen.dart';
import 'package:fairbid/features/jobs/presentation/bundle/bundle_pick_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'widget_test.dart';

BundleBid _bid(
  String providerId,
  String name,
  Map<String, int> prices, {
  int? bundlePriceSen,
}) => BundleBid(
  bundleId: 'b1',
  providerId: providerId,
  providerName: name,
  taskPrices: prices,
  bundlePriceSen: bundlePriceSen,
  estimatedDuration: '1 week',
  createdAt: DateTime.now(),
);

BundleAwardOption _option(
  String label,
  Map<String, String> providerByTask, {
  int totalSen = 30000,
}) => BundleAwardOption(
  key: label,
  label: label,
  totalSen: totalSen,
  providerCount: 1,
  premiumSen: 0,
  weightedTrust: 700,
  awards: [
    for (final entry in providerByTask.entries)
      BundleAwardItem(
        providerId: entry.value,
        providerName: entry.value,
        taskAmountsSen: {entry.key: 1000},
      ),
  ],
);

void main() {
  final tasks = [
    sampleJob(id: 'job-1', title: 'Waterproof the floor', bundleId: 'b1'),
    sampleJob(id: 'job-2', title: 'Tile the floor', bundleId: 'b1'),
    sampleJob(id: 'job-3', title: 'Paint the wall', bundleId: 'b1'),
    sampleJob(id: 'job-4', title: 'Seal the wall', bundleId: 'b1'),
  ];
  final aida = _bid('prov-1', 'Aida Renovation', {
    'job-1': 37500,
    'job-2': 52000,
    'job-3': 10000,
    'job-4': 12000,
  }, bundlePriceSen: 100000);
  // Dev bids on only two of the four tasks.
  final dev = _bid('prov-2', 'Dev Tiling', {'job-1': 30000, 'job-3': 9000});

  Future<FakeBundleRepository> pump(
    WidgetTester tester, {
    List<BundleAwardOption> awardOptions = const [],
    BundleAwardOption? manualOption,
  }) async {
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final bundles =
        FakeBundleRepository([
            sampleBundle(
              id: 'b1',
              taskIds: const ['job-1', 'job-2', 'job-3', 'job-4'],
            ),
          ])
          ..awardOptions = awardOptions
          ..manualOption = manualOption;
    final router = GoRouter(
      initialLocation: '/bundle',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(body: SizedBox()),
          routes: [
            GoRoute(
              path: 'bundle',
              builder: (context, state) => MultiProvider(
                providers: [
                  Provider<BundleRepository>.value(value: bundles),
                  Provider<JobRepository>.value(value: FakeJobRepository(tasks)),
                  Provider<BundleBidRepository>.value(
                    value: FakeBundleBidRepository([aida, dev]),
                  ),
                  ChangeNotifierProvider<AuthController>(
                    create: (_) => AuthController(
                      FakeAuthRepository()..seedSignedIn(UserRole.requestor),
                    ),
                  ),
                ],
                child: const BundleDetailScreen(bundleId: 'b1'),
              ),
            ),
          ],
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp.router(theme: AppTheme.light, routerConfig: router),
    );
    await tester.pumpAndSettle();
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
          _option('Recommended', {'job-1': 'prov-2', 'job-2': 'prov-1'}),
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
        [_bid('prov-1', 'Aida', {'job-1': 1, 'job-2': 2}, bundlePriceSen: 2)],
      );
      expect(hints, [
        "Picking fewer than all of Aida's tasks drops their bundle price.",
      ]);
    });
  });
}
