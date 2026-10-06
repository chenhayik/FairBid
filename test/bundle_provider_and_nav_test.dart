// The bundle screen for providers, the job <-> bundle back stack, and the
// "one primary action, in the bottom bar" rule on job detail. Reuses the
// fakes/helpers built up in widget_test.dart.
import 'package:fairbid/core/theme/app_theme.dart';
import 'package:fairbid/features/auth/domain/user_role.dart';
import 'package:fairbid/features/auth/presentation/auth_controller.dart';
import 'package:fairbid/features/jobs/data/bundle_bid_repository.dart';
import 'package:fairbid/features/jobs/data/bundle_repository.dart';
import 'package:fairbid/features/jobs/data/job_repository.dart';
import 'package:fairbid/features/jobs/domain/bundle.dart';
import 'package:fairbid/features/jobs/domain/bundle_bid.dart';
import 'package:fairbid/features/jobs/domain/job.dart';
import 'package:fairbid/features/jobs/domain/milestone.dart';
import 'package:fairbid/features/jobs/presentation/bid/submit_bundle_bid_sheet.dart';
import 'package:fairbid/features/jobs/presentation/bundle/bundle_detail_screen.dart';
import 'package:fairbid/features/jobs/presentation/detail/job_detail_screen.dart';
import 'package:fairbid/features/jobs/presentation/detail/photo_strip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'widget_test.dart';

/// A bundle bid repository that fails loudly if anyone subscribes to ALL of a
/// bundle's bids - rules only let the owner do that.
class _OwnerOnlyBidsRepository extends FakeBundleBidRepository {
  _OwnerOnlyBidsRepository([super.bids]);

  @override
  Stream<List<BundleBid>> watchBundleBids(String bundleId) =>
      throw StateError('only the bundle owner may read every bid');
}

/// A task of bundle `b1`, owned by someone else unless told otherwise.
Job _task(
  String id,
  String title, {
  String requestorId = 'req-9',
  String category = 'Painting',
  int order = 0,
  JobStatus status = JobStatus.open,
}) => Job(
  id: id,
  requestorId: requestorId,
  requestorName: 'Rita Client',
  title: title,
  description: 'Sand and paint the walls.',
  category: category,
  location: const JobLocation(lat: 3.14, lng: 101.7, address: 'Penang'),
  budget: const JobBudget(minSen: 10000, maxSen: 25000),
  createdAt: DateTime.now(),
  status: status,
  bundleId: 'b1',
  bundleOrder: order,
  bundleTaskCount: 2,
);

Bundle _bundle({
  String requestorId = 'req-9',
  BundleStatus status = BundleStatus.open,
  DateTime? deadline,
  List<String> photoUrls = const [],
}) => Bundle(
  id: 'b1',
  requestorId: requestorId,
  requestorName: 'Rita Client',
  title: 'Bathroom refresh',
  description: 'Small bathroom, about 4 square metres.',
  location: const JobLocation(lat: 3.14, lng: 101.7, address: 'Penang'),
  photoUrls: photoUrls,
  taskIds: const ['job-1', 'job-2'],
  createdAt: DateTime.now(),
  deadline: deadline,
  status: status,
);

BundleBid _myBid({BundleBidStatus status = BundleBidStatus.pending}) =>
    BundleBid(
      bundleId: 'b1',
      providerId: 'uid-1',
      providerName: 'New User',
      taskPrices: const {'job-1': 20000, 'job-2': 17500},
      estimatedDuration: '1 week',
      status: status,
    );

void main() {
  final tasks = [
    _task('job-1', 'Paint the walls'),
    _task('job-2', 'Tile the floor', order: 1, category: 'Electrical'),
  ];

  /// Pumps [BundleDetailScreen] on top of a placeholder job page, opened the
  /// way a job's "View bundle" does (`?fromTask=`) when [fromTaskId] is set.
  /// Signed in as uid-1, who owns the bundle only when [ownerId] is 'uid-1'.
  Future<void> pumpBundle(
    WidgetTester tester, {
    UserRole role = UserRole.provider,
    String verification = 'approved',
    String ownerId = 'req-9',
    Bundle? bundle,
    List<Job>? bundleTasks,
    BundleBidRepository? bids,
    String? fromTaskId,
  }) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final auth = FakeAuthRepository()..verificationStatus = verification;
    auth.seedSignedIn(role);
    final router = GoRouter(
      initialLocation: '/jobs/job-1',
      routes: [
        GoRoute(
          path: '/jobs/:id',
          builder: (context, state) =>
              Scaffold(body: Text('Job page ${state.uri}')),
        ),
        GoRoute(
          path: '/bundles/:id',
          builder: (context, state) => BundleDetailScreen(
            bundleId: 'b1',
            fromTaskId: state.uri.queryParameters['fromTask'],
          ),
        ),
        GoRoute(
          path: '/onboarding',
          builder: (context, state) => const Scaffold(body: Text('Onboarding')),
        ),
      ],
    );
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<BundleRepository>.value(
            value: FakeBundleRepository([bundle ?? _bundle(requestorId: ownerId)]),
          ),
          Provider<JobRepository>.value(
            value: FakeJobRepository(bundleTasks ?? tasks),
          ),
          Provider<BundleBidRepository>.value(
            value: bids ?? _OwnerOnlyBidsRepository(),
          ),
          ChangeNotifierProvider<AuthController>(
            create: (_) => AuthController(auth),
          ),
        ],
        child: MaterialApp.router(theme: AppTheme.light, routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    unawaitedPush(
      router,
      fromTaskId == null ? '/bundles/b1' : '/bundles/b1?fromTask=$fromTaskId',
    );
    await tester.pumpAndSettle();
  }

  group('Task taps on the bundle screen', () {
    testWidgets('a deep link pushes the task with ?from=bundle', (tester) async {
      await pumpBundle(tester);

      await tester.tap(find.text('Tile the floor'));
      await tester.pumpAndSettle();

      expect(find.text('Job page /jobs/job-2?from=bundle'), findsOneWidget);
      // The bundle screen is still underneath, to come back to.
      expect(find.byType(BundleDetailScreen, skipOffstage: false),
          findsOneWidget);
    });

    testWidgets('the task it was opened from pops instead of pushing', (
      tester,
    ) async {
      await pumpBundle(tester, fromTaskId: 'job-1');

      await tester.tap(find.text('Paint the walls'));
      await tester.pumpAndSettle();

      expect(find.byType(BundleDetailScreen, skipOffstage: false),
          findsNothing);
      expect(find.text('Job page /jobs/job-1'), findsOneWidget);
    });

    testWidgets('any other task still pushes, even with ?fromTask', (
      tester,
    ) async {
      await pumpBundle(tester, fromTaskId: 'job-1');

      await tester.tap(find.text('Tile the floor'));
      await tester.pumpAndSettle();

      expect(find.text('Job page /jobs/job-2?from=bundle'), findsOneWidget);
    });

    testWidgets('the owner\'s task list follows the same rule', (tester) async {
      await pumpBundle(
        tester,
        role: UserRole.requestor,
        ownerId: 'uid-1',
        bids: FakeBundleBidRepository(),
        fromTaskId: 'job-1',
      );

      await tester.tap(find.text('Paint the walls'));
      await tester.pumpAndSettle();

      expect(find.byType(BundleDetailScreen, skipOffstage: false),
          findsNothing);
    });
  });

  group('Provider view of a bundle', () {
    testWidgets('shows the bundle and every task, and only those', (
      tester,
    ) async {
      await pumpBundle(
        tester,
        bundle: _bundle(
          deadline: DateTime.now().add(const Duration(days: 3)),
          photoUrls: const ['https://example.com/a.jpg'],
        ),
        bundleTasks: [
          _task('job-1', 'Paint the walls'),
          _task('job-2', 'Tile the floor', order: 1, category: 'Electrical'),
        ],
      );

      expect(find.text('Bathroom refresh'), findsOneWidget); // app bar
      expect(find.text('Open'), findsOneWidget);
      expect(find.text('Small bathroom, about 4 square metres.'),
          findsOneWidget);
      expect(find.textContaining('Bidding closes'), findsOneWidget);
      expect(find.byType(PhotoStrip), findsOneWidget);
      expect(find.text('Paint the walls'), findsOneWidget);
      expect(find.text('Tile the floor'), findsOneWidget);
      expect(find.textContaining('Electrical • RM'), findsOneWidget);
      expect(find.textContaining('Energy Commission-registered'),
          findsOneWidget);

      // The description is collapsed until asked for.
      expect(find.text('Sand and paint the walls.'), findsNothing);
      await tester.tap(find.text('Show details').first);
      await tester.pumpAndSettle();
      expect(find.text('Sand and paint the walls.'), findsOneWidget);
      expect(find.text('Hide details'), findsOneWidget);

      // Nothing an owner alone may see or do.
      expect(find.text('Cancel bundle'), findsNothing);
      expect(find.text('Award'), findsNothing);
      expect(find.text('Show award options'), findsNothing);
      expect(find.text('Bids'), findsNothing);
    });

    testWidgets('a task card opens that job with ?from=bundle', (tester) async {
      await pumpBundle(tester);

      await tester.tap(find.text('Paint the walls'));
      await tester.pumpAndSettle();

      expect(find.text('Job page /jobs/job-1?from=bundle'), findsOneWidget);
    });

    testWidgets('shows the provider\'s own bundle bid with its status', (
      tester,
    ) async {
      await pumpBundle(tester, bids: _OwnerOnlyBidsRepository([_myBid()]));

      expect(
        find.text('Your bundle bid: RM 375.00 for 2 tasks'),
        findsOneWidget,
      );
      expect(find.text('Pending'), findsOneWidget);
    });

    testWidgets('one bottom action: bid, then edit once they have a bid', (
      tester,
    ) async {
      await pumpBundle(tester);
      expect(find.widgetWithText(FilledButton, 'Bid on this bundle'),
          findsOneWidget);
      expect(find.textContaining('Your bundle bid'), findsNothing);

      await tester.tap(find.widgetWithText(FilledButton, 'Bid on this bundle'));
      await tester.pumpAndSettle();
      expect(find.byType(SubmitBundleBidSheet), findsOneWidget);
    });

    testWidgets('an existing bid turns the action into Edit and prefills', (
      tester,
    ) async {
      await pumpBundle(tester, bids: _OwnerOnlyBidsRepository([_myBid()]));
      expect(find.widgetWithText(FilledButton, 'Bid on this bundle'),
          findsNothing);

      await tester.tap(find.widgetWithText(FilledButton, 'Edit bundle bid'));
      await tester.pumpAndSettle();

      expect(find.byType(SubmitBundleBidSheet), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Update bundle bid'),
          findsOneWidget);
    });

    testWidgets('no bid action once bidding has closed', (tester) async {
      await pumpBundle(
        tester,
        bundle: _bundle(deadline: DateTime.now().subtract(const Duration(days: 1))),
      );

      expect(find.text('Closed'), findsOneWidget);
      expect(find.byType(FilledButton), findsNothing);
    });

    testWidgets('no bid action once the bundle is awarded', (tester) async {
      await pumpBundle(tester, bundle: _bundle(status: BundleStatus.awarded));

      expect(find.text('Awarded'), findsOneWidget);
      expect(find.byType(FilledButton), findsNothing);
    });

    testWidgets('an unverified provider is sent to get verified instead', (
      tester,
    ) async {
      await pumpBundle(tester, verification: 'pending');

      expect(find.widgetWithText(FilledButton, 'Bid on this bundle'),
          findsNothing);
      await tester.tap(find.widgetWithText(FilledButton, 'Get verified to bid'));
      await tester.pumpAndSettle();
      expect(find.text('Onboarding'), findsOneWidget);
    });
  });

  group('Owner view of a bundle is unchanged', () {
    testWidgets('keeps the bids list, award and cancel, with no bid action', (
      tester,
    ) async {
      final bid = BundleBid(
        bundleId: 'b1',
        providerId: 'prov-1',
        providerName: 'Aida Renovation',
        taskPrices: const {'job-1': 37500, 'job-2': 52000},
        estimatedDuration: '1 week',
        createdAt: DateTime.now(),
      );
      await pumpBundle(
        tester,
        role: UserRole.requestor,
        ownerId: 'uid-1',
        bids: FakeBundleBidRepository([bid]),
      );

      expect(find.text('2 tasks  •  1 bid'), findsOneWidget);
      expect(find.text('Cancel bundle'), findsOneWidget);
      expect(find.text('Show award options'), findsOneWidget);
      // Bids open from a button near the top.
      expect(find.text('View all bids (1)'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Bid on this bundle'),
          findsNothing);
      expect(find.widgetWithText(FilledButton, 'Edit bundle bid'),
          findsNothing);
    });
  });

  group('Job <-> bundle back stack', () {
    Future<void> openFirstTask(WidgetTester tester, {required bool owner}) async {
      await tester.binding.setSurfaceSize(const Size(500, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final mine = owner ? 'uid-1' : 'req-9';
      final bundleTasks = [
        _task('job-1', 'Fix leaking sink', requestorId: mine),
        _task('job-2', 'Retile the floor', requestorId: mine, order: 1),
      ];
      final auth = FakeAuthRepository()
        ..verificationStatus = 'approved'
        ..baseLat = 3.139
        ..baseLng = 101.6869;
      await tester.pumpWidget(buildApp(
        auth,
        jobs: bundleTasks,
        bundle: FakeBundleRepository([_bundle(requestorId: mine)]),
      ));
      await tester.pumpAndSettle();
      if (owner) {
        await fillField(tester, 'Email', 'a@b.com');
        await fillField(tester, 'Password', 'secret123');
        await tester.tap(find.widgetWithText(FilledButton, 'Log In'));
        await tester.pumpAndSettle();
        await tester.tap(find.descendant(
            of: find.byType(NavigationBar), matching: find.text('My jobs')));
        await tester.pumpAndSettle();
      } else {
        await openRegisterAs(tester, 'Work');
      }
      await tester.tap(find.text('Fix leaking sink').first);
      await tester.pumpAndSettle();
    }

    int bundleScreens(WidgetTester tester) =>
        find.byType(BundleDetailScreen, skipOffstage: false).evaluate().length;
    int jobScreens(WidgetTester tester) =>
        find.byType(JobDetailScreen, skipOffstage: false).evaluate().length;

    testWidgets('the owner can loop job -> bundle -> job -> bundle without '
        'the back stack growing', (tester) async {
      await openFirstTask(tester, owner: true);

      // Job 1 -> bundle (pushed) -> job 2 (pushed with from=bundle).
      await tester.tap(find.widgetWithText(FilledButton, 'View bundle'));
      await tester.pumpAndSettle();
      expect(bundleScreens(tester), 1);
      await tester.tap(find.text('Retile the floor'));
      await tester.pumpAndSettle();
      expect(jobScreens(tester), 2);

      // "View bundle" on job 2 goes back to the bundle instead of stacking.
      await tester.tap(find.widgetWithText(FilledButton, 'View bundle'));
      await tester.pumpAndSettle();
      expect(bundleScreens(tester), 1);
      expect(jobScreens(tester), 1);

      // And the bundle's link to job 1 (where it came from) goes back too.
      await tester.tap(find.text('Fix leaking sink'));
      await tester.pumpAndSettle();
      expect(bundleScreens(tester), 0);
      expect(jobScreens(tester), 1);

      // One back press leaves the job for the list underneath.
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(jobScreens(tester), 0);
    });

    testWidgets('a provider gets a View bundle button on the banner, and the '
        'same loop is bounded', (tester) async {
      await openFirstTask(tester, owner: false);

      // The bar's one action is the bid; the banner holds "View bundle".
      expect(find.widgetWithText(FilledButton, 'Bid on this bundle'),
          findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'View bundle'), findsNothing);
      final viewBundle = find.widgetWithText(TextButton, 'View bundle');
      expect(viewBundle, findsOneWidget);

      await tester.tap(viewBundle);
      await tester.pumpAndSettle();
      // The provider's read-only bundle screen, with its own bid action.
      expect(bundleScreens(tester), 1);
      expect(find.widgetWithText(FilledButton, 'Bid on this bundle'),
          findsOneWidget);

      await tester.tap(find.text('Retile the floor'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'View bundle'));
      await tester.pumpAndSettle();
      expect(bundleScreens(tester), 1);
      expect(jobScreens(tester), 1);
    });
  });

  group('One primary action per screen (job detail)', () {
    Job inProgress({String requestorId = 'uid-1', String? acceptedId}) =>
        sampleJob(
          requestorId: requestorId,
          status: JobStatus.inProgress,
          acceptedProviderId: acceptedId ?? 'prov-1',
          acceptedProviderName: 'Pro Fixer',
          acceptedBidAmountSen: 15000,
        );

    Milestone milestone(MilestoneStatus status) => Milestone(
      id: 'ms-1',
      jobId: 'job-1',
      providerId: 'prov-1',
      description: 'Full repair',
      amountSen: 15000,
      status: status,
      createdAt: DateTime.now(),
    );

    Future<void> openAsOwner(
      WidgetTester tester,
      Job job,
      List<Milestone> milestones,
    ) async {
      await tester.binding.setSurfaceSize(const Size(500, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        buildApp(FakeAuthRepository(), jobs: [job], milestones: milestones),
      );
      await tester.pumpAndSettle();
      await fillField(tester, 'Email', 'a@b.com');
      await fillField(tester, 'Password', 'secret123');
      await tester.tap(find.widgetWithText(FilledButton, 'Log In'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fix leaking sink').first);
      await tester.pumpAndSettle();
    }

    Future<void> openAsProvider(
      WidgetTester tester,
      Job job,
      List<Milestone> milestones,
    ) async {
      await tester.binding.setSurfaceSize(const Size(500, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final auth = FakeAuthRepository()
        ..verificationStatus = 'approved'
        ..baseLat = 3.139
        ..baseLng = 101.6869;
      await tester.pumpWidget(
        buildApp(auth, jobs: [job], milestones: milestones),
      );
      await tester.pumpAndSettle();
      await openRegisterAs(tester, 'Work');
      await tester.tap(find.descendant(
          of: find.byType(NavigationBar), matching: find.text('My jobs')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fix leaking sink').first);
      await tester.pumpAndSettle();
    }

    testWidgets('a bidder\'s Withdraw lives on the bid card, not the bar', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(500, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final auth = FakeAuthRepository()
        ..verificationStatus = 'approved'
        ..baseLat = 3.139
        ..baseLng = 101.6869;
      await tester.pumpWidget(buildApp(
        auth,
        jobs: [sampleJob(requestorId: 'req-9', bidCount: 1)],
        bids: [sampleBid(providerId: 'uid-1', amountSen: 15000)],
      ));
      await tester.pumpAndSettle();
      await openRegisterAs(tester, 'Work');
      await tester.tap(find.text('Fix leaking sink').first);
      await tester.pumpAndSettle();

      expect(find.widgetWithText(OutlinedButton, 'Withdraw bid'),
          findsOneWidget);
      expect(find.text('Withdraw'), findsNothing);
    });

    testWidgets('a client with no stage yet messages from the bar only', (
      tester,
    ) async {
      await openAsOwner(tester, inProgress(), []);

      expect(find.widgetWithText(FilledButton, 'Message provider'),
          findsOneWidget);
      expect(find.text('Message Pro Fixer'), findsNothing);
    });

    testWidgets('while a milestone is in play the chat tile stays, since the '
        'bar is busy with the milestone', (tester) async {
      await openAsOwner(
        tester,
        inProgress(),
        [milestone(MilestoneStatus.funded)],
      );

      expect(find.widgetWithText(FilledButton, 'Message provider'),
          findsNothing);
      expect(find.text('Message Pro Fixer'), findsOneWidget);
    });

    testWidgets('the provider delivers from the bar only', (tester) async {
      await openAsProvider(
        tester,
        inProgress(acceptedId: 'uid-1', requestorId: 'req-9'),
        [milestone(MilestoneStatus.funded)],
      );

      expect(find.widgetWithText(FilledButton, 'Mark as delivered'),
          findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Mark as delivered'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Mark delivered'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Marked as delivered. Waiting for the client'),
          findsOneWidget);
    });

    testWidgets('a bundle task offers its bid action once, on the bar', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(500, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final auth = FakeAuthRepository()
        ..verificationStatus = 'approved'
        ..baseLat = 3.139
        ..baseLng = 101.6869;
      await tester.pumpWidget(buildApp(
        auth,
        jobs: [_task('job-1', 'Fix leaking sink')],
        bundle: FakeBundleRepository([_bundle()]),
      ));
      await tester.pumpAndSettle();
      await openRegisterAs(tester, 'Work');
      await tester.tap(find.text('Fix leaking sink').first);
      await tester.pumpAndSettle();

      expect(find.text('Bid on this bundle'), findsOneWidget);
    });
  });
}

/// Pushes [location] without awaiting the (never-completing-in-test) result.
void unawaitedPush(GoRouter router, String location) {
  router.push<void>(location);
}
