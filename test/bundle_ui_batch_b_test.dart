import 'dart:async';

import 'package:fairbid/core/theme/app_theme.dart';
import 'package:fairbid/features/auth/domain/user_role.dart';
import 'package:fairbid/features/auth/presentation/auth_controller.dart';
import 'package:fairbid/features/jobs/data/bundle_bid_repository.dart';
import 'package:fairbid/features/jobs/data/bundle_repository.dart';
import 'package:fairbid/features/jobs/data/job_repository.dart';
import 'package:fairbid/features/jobs/domain/bundle.dart';
import 'package:fairbid/features/jobs/domain/bundle_award.dart';
import 'package:fairbid/features/jobs/domain/bundle_bid.dart';
import 'package:fairbid/features/jobs/domain/job.dart';
import 'package:fairbid/features/jobs/presentation/bundle/bundle_detail_screen.dart';
import 'package:fairbid/features/jobs/presentation/bundle/bundle_option_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'widget_test.dart';

/// A [BundleBidRepository] whose `watchBundleBids` is a live broadcast stream
/// - unlike the shared [FakeBundleBidRepository], which only ever emits once.
/// Only this file needs to push a bid update mid-test (to exercise the
/// "bids have changed" staleness banner), so it lives here rather than
/// widening the shared fake.
class _LiveBundleBidRepository implements BundleBidRepository {
  final _controller = StreamController<List<BundleBid>>.broadcast();
  List<BundleBid> _bids = const [];

  void push(List<BundleBid> bids) {
    _bids = bids;
    _controller.add(bids);
  }

  @override
  Stream<List<BundleBid>> watchBundleBids(String bundleId) async* {
    yield _bids;
    yield* _controller.stream;
  }

  @override
  Future<void> submit({
    required String bundleId,
    required Map<String, int> taskPrices,
    int? bundlePriceSen,
    required String estimatedDuration,
    String message = '',
  }) => throw UnimplementedError();

  @override
  Future<void> withdraw(String bundleId) => throw UnimplementedError();

  @override
  Stream<BundleBid?> watchMyBundleBid(String bundleId, String providerId) =>
      throw UnimplementedError();

  @override
  Future<BundleBid?> getMyBundleBid(String bundleId, String providerId) =>
      throw UnimplementedError();

  @override
  Stream<List<BundleBid>> watchMyBundleBids(String providerId) =>
      throw UnimplementedError();
}

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

  BundleBid bid({String providerId = 'prov-1', String providerName = 'Aida Renovation'}) =>
      BundleBid(
        bundleId: 'b1',
        providerId: providerId,
        providerName: providerName,
        taskPrices: const {'job-1': 37500, 'job-2': 52000},
        estimatedDuration: '1 week',
        createdAt: DateTime.now(),
      );

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
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final bundles = FakeBundleRepository([
      bundle ?? sampleBundle(id: 'b1', taskIds: const ['job-1', 'job-2']),
    ])..awardOptions = awardOptions;
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
                  Provider<JobRepository>.value(
                    value: FakeJobRepository(tasksOverride ?? tasks),
                  ),
                  Provider<BundleBidRepository>.value(
                    value: bundleBids ?? FakeBundleBidRepository(bids),
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
        GoRoute(
          path: '/jobs/:id',
          builder: (context, state) =>
              Scaffold(body: Text('Job detail: ${state.pathParameters['id']}')),
        ),
        GoRoute(
          path: '/users/:uid',
          builder: (context, state) =>
              Scaffold(body: Text('Profile: ${state.pathParameters['uid']}')),
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp.router(theme: AppTheme.light, routerConfig: router),
    );
    await tester.pumpAndSettle();
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
      ) => BundleBid(
        bundleId: 'b1',
        providerId: id,
        providerName: name,
        taskPrices: const {'job-1': 37500},
        estimatedDuration: '1 week',
        status: status,
        createdAt: DateTime.now(),
      );
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
      const cheapest = BundleAwardOption(
        key: 'cheapest',
        label: 'Cheapest',
        totalSen: 37500,
        providerCount: 1,
        premiumSen: 0,
        weightedTrust: 700,
        awards: [
          BundleAwardItem(
            providerId: 'prov-1',
            providerName: 'Aida Renovation',
            taskAmountsSen: {'job-1': 37500},
          ),
        ],
        uncoveredTaskIds: ['job-2'],
      );
      const fewest = BundleAwardOption(
        key: 'fewest',
        label: 'Fewest providers',
        totalSen: 37500,
        providerCount: 1,
        premiumSen: 0,
        weightedTrust: 700,
        awards: [
          BundleAwardItem(
            providerId: 'prov-1',
            providerName: 'Aida Renovation',
            taskAmountsSen: {'job-1': 37500},
          ),
        ],
        uncoveredTaskIds: ['job-2'],
      );
      const recommended = BundleAwardOption(
        key: 'recommended',
        label: 'Recommended',
        totalSen: 89500,
        providerCount: 2,
        premiumSen: 0,
        weightedTrust: 751,
        awards: [
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
        ],
      );

      await pumpBundle(
        tester,
        bids: [bid(), bid(providerId: 'prov-2', providerName: 'Dev Tiling')],
        awardOptions: [cheapest, fewest, recommended],
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Show award options'));
      await tester.pumpAndSettle();

      expect(find.text('Cheapest · Fewest providers'), findsOneWidget);
      expect(find.text('Recommended'), findsOneWidget);
      // Only the recommended card gets the filled Award button; the merged
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
      const recommended = BundleAwardOption(
        key: 'recommended',
        label: 'Recommended',
        totalSen: 89500,
        providerCount: 1,
        premiumSen: 0,
        weightedTrust: 700,
        awards: [
          BundleAwardItem(
            providerId: 'prov-1',
            providerName: 'Aida Renovation',
            taskAmountsSen: {'job-1': 37500, 'job-2': 52000},
          ),
        ],
      );
      final live = _LiveBundleBidRepository()..push([bid()]);
      final bundles = await pumpBundle(
        tester,
        bundleBids: live,
        awardOptions: [recommended],
      );

      await tester.tap(find.widgetWithText(FilledButton, 'Show award options'));
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(FilledButton, 'Award this option'),
        findsOneWidget,
      );

      // The provider edits their bid - createdAt is unchanged, but the price
      // and updatedAt move on.
      final edited = BundleBid(
        bundleId: 'b1',
        providerId: 'prov-1',
        providerName: 'Aida Renovation',
        taskPrices: const {'job-1': 30000, 'job-2': 52000},
        estimatedDuration: '1 week',
        createdAt: bid().createdAt,
        updatedAt: DateTime.now(),
      );
      live.push([edited]);
      await tester.pumpAndSettle();

      expect(find.textContaining('bids have changed'), findsOneWidget);
      final awardButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Award this option'),
      );
      expect(awardButton.onPressed, isNull);

      bundles.awardOptions = [recommended];
      await tester.tap(find.widgetWithText(TextButton, 'Refresh'));
      await tester.pumpAndSettle();

      final refreshedButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Award this option'),
      );
      expect(refreshedButton.onPressed, isNotNull);
    });
  });

  group('BundleOptionCard', () {
    Job task() => sampleJob(id: 'job-1', title: 'Waterproof the floor');
    const option = BundleAwardOption(
      key: 'recommended',
      label: 'Recommended',
      totalSen: 37500,
      providerCount: 1,
      premiumSen: 0,
      weightedTrust: 700,
      awards: [
        BundleAwardItem(
          providerId: 'prov-1',
          providerName: 'Aida Renovation',
          taskAmountsSen: {'job-1': 37500},
        ),
      ],
    );

    Future<void> pumpCard(
      WidgetTester tester, {
      required bool enabled,
      required bool primary,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: BundleOptionCard(
              merged: MergedBundleOption(option, const ['Recommended']),
              tasks: [task()],
              primary: primary,
              busy: false,
              enabled: enabled,
              onAward: () {},
            ),
          ),
        ),
      );
    }

    testWidgets('a disabled card cannot be awarded', (tester) async {
      await pumpCard(tester, enabled: false, primary: true);
      final button = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(button.onPressed, isNull);
    });

    testWidgets('an enabled, non-primary card uses an outlined button', (
      tester,
    ) async {
      await pumpCard(tester, enabled: true, primary: false);
      expect(find.byType(FilledButton), findsNothing);
      final button = tester.widget<OutlinedButton>(
        find.byType(OutlinedButton),
      );
      expect(button.onPressed, isNotNull);
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
      await pumpBundle(tester, bids: [bid()]);
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
        bids: [bid()],
      );
      expect(find.textContaining('1 task'), findsOneWidget);
      expect(find.textContaining('1 bid'), findsOneWidget);
    });
  });
  group('Package price and trust on the bundle page', () {
    testWidgets('an awarded task split by a package deal says so', (
      tester,
    ) async {
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
            acceptedBidAmountSen: 93334,
          ),
        ],
        bids: [
          BundleBid(
            bundleId: 'b1',
            providerId: 'p1',
            providerName: 'Worker One',
            taskPrices: const {'job-1': 100000, 'job-2': 50000},
            bundlePriceSen: 140000,
            estimatedDuration: '1 week',
            status: BundleBidStatus.accepted,
            createdAt: DateTime.now(),
          ),
        ],
      );

      expect(find.textContaining('Package deal price'), findsOneWidget);
      expect(find.textContaining('1,000.00 if hired for this task alone'),
          findsOneWidget);
    });

    testWidgets('no package note once the price was changed later', (
      tester,
    ) async {
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
            acceptedBidAmountSen: 100000,
            originalBidAmountSen: 93334,
          ),
        ],
        bids: [
          BundleBid(
            bundleId: 'b1',
            providerId: 'p1',
            providerName: 'Worker One',
            taskPrices: const {'job-1': 100000, 'job-2': 50000},
            bundlePriceSen: 140000,
            estimatedDuration: '1 week',
            status: BundleBidStatus.accepted,
            createdAt: DateTime.now(),
          ),
        ],
      );
      expect(find.textContaining('Package deal price'), findsNothing);
    });

    Future<void> pumpCard(WidgetTester tester, {required bool visible}) async {
      final option = BundleAwardOption(
        key: 'recommended',
        label: 'Recommended',
        totalSen: 140000,
        providerCount: 1,
        premiumSen: 0,
        weightedTrust: 608,
        trustVisible: visible,
      );
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: SingleChildScrollView(
            child: BundleOptionCard(
              merged: MergedBundleOption(option, const ['Recommended']),
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
      expect(find.textContaining('Trust'), findsNothing);
    });
  });
}
