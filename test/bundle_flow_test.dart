import 'package:fairbid/core/location/penang_districts.dart';
import 'package:fairbid/core/theme/app_theme.dart';
import 'package:fairbid/core/widgets/app_widgets.dart';
import 'package:fairbid/features/auth/domain/user_role.dart';
import 'package:fairbid/features/jobs/data/bid_repository.dart';
import 'package:fairbid/features/jobs/data/bundle_repository.dart';
import 'package:fairbid/features/jobs/domain/bundle.dart';
import 'package:fairbid/features/jobs/domain/bundle_award.dart';
import 'package:fairbid/features/jobs/domain/bundle_bid.dart';
import 'package:fairbid/features/jobs/domain/job.dart';
import 'package:fairbid/features/jobs/presentation/bid/submit_bundle_bid_sheet.dart';
import 'package:fairbid/features/jobs/presentation/widgets/job_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/builders.dart';
import 'helpers/fakes.dart';
import 'helpers/harness.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await PenangDistricts.instance.ensureLoaded();
  });

  // -------------------------------------------------------------------------
  // Bundle bidding (docs/BUNDLE_BIDDING.md phase 2): a provider prices the
  // tasks of a bundle they can do, as one package bid.
  // -------------------------------------------------------------------------
  group('Bundle bidding', () {
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

    /// Fills in everything the form needs beyond the task prices.
    Future<void> fillRest(WidgetTester tester) async {
      await tapAt(tester, find.byType(DropdownButtonFormField<String>));
      await tester.tap(find.text('Less than 1 week').last);
      await tester.pumpAndSettle();
      await fillField(tester, 'Proposal message', 'I can do this.');
      await tapAt(tester, find.byType(CheckboxListTile).last);
    }

    testWidgets('a bundle task card says how big its bundle is', (
      tester,
    ) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: JobCard(
            job: sampleJob(bundleId: 'b1', bundleOrder: 0, bundleTaskCount: 3),
          ),
        ),
      ));

      expect(find.text('Part of a 3-task bundle'), findsOneWidget);
    });

    testWidgets('an ordinary job card carries no bundle pill', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(body: JobCard(job: sampleJob())),
      ));

      expect(find.textContaining('bundle'), findsNothing);
    });

    testWidgets('submitting with no task picked is refused', (tester) async {
      final bundleBids = await pumpBundleBidSheet(tester, tasks: tasks);

      await tapAt(
          tester, find.widgetWithText(PrimaryButton, 'Submit bundle bid'));

      expect(find.text('Pick at least one task to bid on.'), findsOneWidget);
      expect(bundleBids.lastSubmission, isNull);
    });

    testWidgets('one picked task is sent with its price in sen', (
      tester,
    ) async {
      final bundleBids = await pumpBundleBidSheet(tester, tasks: tasks);

      await tapAt(
          tester, find.widgetWithText(CheckboxListTile, 'Tile the floor'));
      await fillField(tester, 'Price if you get only this task (RM)', '150.50');
      await fillRest(tester);
      await tapAt(
          tester, find.widgetWithText(PrimaryButton, 'Submit bundle bid'));

      expect(bundleBids.lastSubmission?['taskPrices'], {'job-2': 15050});
      expect(bundleBids.lastSubmission?['bundlePriceSen'], isNull);
      expect(
          bundleBids.lastSubmission?['estimatedDuration'], 'Less than 1 week');
    });

    testWidgets('a bundle price at or above the task total is refused', (
      tester,
    ) async {
      final bundleBids = await pumpBundleBidSheet(tester, tasks: tasks);

      // Bundle price only makes sense once two or more tasks are picked.
      await tapAt(tester,
          find.widgetWithText(CheckboxListTile, 'Waterproof the floor'));
      await tapAt(
          tester, find.widgetWithText(CheckboxListTile, 'Tile the floor'));
      // Two task price fields now share a label; fill each by position.
      final priceFields = find.byType(TextFormField);
      await tester.ensureVisible(priceFields.at(0));
      await tester.enterText(priceFields.at(0), '50.00');
      await tester.ensureVisible(priceFields.at(1));
      await tester.enterText(priceFields.at(1), '50.00');
      await tester.pumpAndSettle();
      await tapAt(tester, find.text('+ Add a package deal (optional)'));
      await fillField(tester, 'Price if you win all 2 tasks (RM)', '100.00');
      await fillRest(tester);
      await tapAt(
          tester, find.widgetWithText(PrimaryButton, 'Submit bundle bid'));

      expect(
        find.textContaining('Must be under RM 100.00 (your task total)'),
        findsOneWidget,
      );
      expect(bundleBids.lastSubmission, isNull);
    });

    testWidgets('the sheet opens with a one-line tip', (tester) async {
      await pumpBundleBidSheet(tester, tasks: tasks);

      expect(
        find.text('Tip: covering more tasks can win you the whole bundle.'),
        findsOneWidget,
      );
    });

    testWidgets(
      'a partial read of the bundle tasks blocks the sheet with a snackbar',
      (tester) async {

        final auth = FakeAuthRepository()
          ..verificationStatus = 'approved'
          ..baseLat = 3.139
          ..baseLng = 101.6869;
        // Only job-1 is seeded, even though the bundle claims two tasks - a
        // stand-in for a `getBundleTasks` read landing before every task
        // document has synced.
        final job = sampleJob(
          requestorId: 'req-9',
          bundleId: 'b1',
          bundleOrder: 0,
          bundleTaskCount: 2,
        );
        final bundles = FakeBundleRepository(
          [sampleBundle(id: 'b1', taskIds: const ['job-1', 'job-2'])],
        );
        await pumpApp(tester, buildApp(auth, jobs: [job], bundle: bundles), size: const Size(500, 1600));
        await openRegisterAs(tester, 'Work');
        await tester.tap(find.text('Fix leaking sink').first);
        await tester.pumpAndSettle();

        await tester.tap(
          find.widgetWithText(FilledButton, 'Bid on this bundle').first,
        );
        await tester.pumpAndSettle();

        expect(
          find.text(
            "Couldn't load every task in this bundle. Check your "
            'connection and try again.',
          ),
          findsOneWidget,
        );
        expect(find.byType(SubmitBundleBidSheet), findsNothing);
      },
    );
  });

  // -------------------------------------------------------------------------
  // A provider's package bids belong on their "Pending Bids" list alongside
  // their ordinary per-job bids (docs/BUNDLE_BIDDING.md) - both the Provider
  // Home stat and the My Jobs section.
  // -------------------------------------------------------------------------
  group('Pending bundle bids', () {
    testWidgets(
      'a pending bundle bid counts toward Pending Bids and shows in My '
      'Jobs, but a closed one does not',
      (tester) async {

        final pending = sampleBundleBid(providerId: 'uid-1', providerName: 'New User', bundleTitle: 'Bathroom refresh');
        final closed = sampleBundleBid(bundleId: 'b2', providerId: 'uid-1', providerName: 'New User', taskPrices: const {'job-3': 10000}, status: BundleBidStatus.closed, bundleTitle: 'Kitchen refresh');
        final auth = FakeAuthRepository()..verificationStatus = 'approved';
        await pumpApp(tester, buildApp(
          auth,
          bundleBid: FakeBundleBidRepository([pending, closed]),
        ), size: const Size(500, 1600));
        await openRegisterAs(tester, 'Work');

        // Provider Home's "Pending Bids" stat counts only the pending one.
        expect(find.widgetWithText(StatCard, '1'), findsOneWidget);

        await openTab(tester, 'My jobs');

        // The tile's primary line is now the quoted amount, with the bundle
        // title folded into a "<title> • N tasks" caption underneath.
        expect(find.textContaining('Bathroom refresh'), findsOneWidget);
        expect(find.textContaining('Kitchen refresh'), findsNothing);
      },
    );
  });

  // -------------------------------------------------------------------------
  // My Jobs groups a bundle's tasks under one card (bundle phase 4).
  // -------------------------------------------------------------------------
  group('My Jobs bundle grouping', () {
    testWidgets(
      "a requestor's bundle shows as one card with a progress line, "
      'and plain jobs stay unchanged',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(500, 1600));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final tasks = [
          sampleJob(id: 'job-1', title: 'Waterproofing', bundleId: 'b1',
              bundleOrder: 0, bundleTaskCount: 3, status: JobStatus.completed),
          sampleJob(id: 'job-2', title: 'Tiling', bundleId: 'b1',
              bundleOrder: 1, bundleTaskCount: 3, status: JobStatus.inProgress),
          sampleJob(id: 'job-3', title: 'Electrical fittings', bundleId: 'b1',
              bundleOrder: 2, bundleTaskCount: 3, status: JobStatus.open),
          sampleJob(id: 'job-4', title: 'Fix the fence'),
        ];
        final auth = FakeAuthRepository()..seedSignedIn(UserRole.requestor);
        final bundles = FakeBundleRepository([
          sampleBundle(
              id: 'b1',
              title: 'Bathroom refresh',
              taskIds: const ['job-1', 'job-2', 'job-3']),
        ]);
        await tester
            .pumpWidget(buildApp(auth, jobs: tasks, bundle: bundles));
        await tester.pumpAndSettle();
        await openTab(tester, 'My jobs');

        expect(find.text('Bathroom refresh'), findsOneWidget);
        expect(find.text('3 tasks · 1 in progress · 1 done · '
            '1 open'), findsOneWidget);
        expect(find.text('Waterproofing'), findsOneWidget);
        expect(find.text('Tiling'), findsOneWidget);
        expect(find.text('Electrical fittings'), findsOneWidget);
        // A plain job (no bundleId) still renders as its own ordinary card.
        expect(find.text('Fix the fence'), findsOneWidget);
      },
    );

    testWidgets(
      'a status filter narrows a bundle to its matching tasks, and hides '
      "the card entirely if none match",
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(500, 1600));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final tasks = [
          sampleJob(id: 'job-1', title: 'Waterproofing', bundleId: 'b1',
              bundleOrder: 0, bundleTaskCount: 3, status: JobStatus.completed),
          sampleJob(id: 'job-2', title: 'Tiling', bundleId: 'b1',
              bundleOrder: 1, bundleTaskCount: 3, status: JobStatus.inProgress),
          sampleJob(id: 'job-3', title: 'Electrical fittings', bundleId: 'b1',
              bundleOrder: 2, bundleTaskCount: 3, status: JobStatus.open),
          sampleJob(id: 'job-4', title: 'Roof repair', bundleId: 'b2',
              bundleOrder: 0, bundleTaskCount: 1, status: JobStatus.open),
        ];
        final auth = FakeAuthRepository()..seedSignedIn(UserRole.requestor);
        final bundles = FakeBundleRepository([
          sampleBundle(
              id: 'b1',
              title: 'Bathroom refresh',
              taskIds: const ['job-1', 'job-2', 'job-3']),
          sampleBundle(
              id: 'b2', title: 'Roofing', taskIds: const ['job-4']),
        ]);
        await tester
            .pumpWidget(buildApp(auth, jobs: tasks, bundle: bundles));
        await tester.pumpAndSettle();
        await openTab(tester, 'My jobs');

        final chip = find.widgetWithText(ChoiceChip, 'Completed');
        await tester.ensureVisible(chip);
        await tester.tap(chip);
        await tester.pumpAndSettle();

        // Only the matching task shows, but the progress line still counts
        // every task in the bundle.
        expect(find.text('Bathroom refresh'), findsOneWidget);
        expect(find.text('3 tasks · 1 in progress · 1 done · '
            '1 open'), findsOneWidget);
        expect(find.text('Waterproofing'), findsOneWidget);
        expect(find.text('Tiling'), findsNothing);
        expect(find.text('Electrical fittings'), findsNothing);
        // No task in "Roofing" is completed, so the card is hidden entirely.
        expect(find.text('Roofing'), findsNothing);
      },
    );
  });

  // -------------------------------------------------------------------------
  // A task `awardBundle` left unawarded (docs/BUNDLE_BIDDING.md): from then
  // on it is an ordinary job, not a bundle task, for both bidding and
  // cancelling - even though `bundleId` is still set.
  // -------------------------------------------------------------------------
  group('Released bundle tasks', () {
    testWidgets(
      "a released task's bid sheet is the ordinary one, not the bundle's",
      (tester) async {

        final auth = FakeAuthRepository()
          ..verificationStatus = 'approved'
          ..baseLat = 3.139
          ..baseLng = 101.6869;
        final job = sampleJob(
          requestorId: 'req-9',
          bundleId: 'b1',
          bundleOrder: 0,
          bundleTaskCount: 2,
          releasedAt: DateTime.now(),
        );
        final bundles = FakeBundleRepository(
            [sampleBundle(id: 'b1', status: BundleStatus.awarded)]);
        await pumpApp(tester, buildApp(auth, jobs: [job], bundle: bundles), size: const Size(500, 1600));
        await openRegisterAs(tester, 'Work');
        await tester.tap(find.text('Fix leaking sink').first);
        await tester.pumpAndSettle();

        expect(find.text('Released from its bundle'), findsOneWidget);

        await tester.tap(find.widgetWithText(FilledButton, 'Submit a bid').first);
        await tester.pumpAndSettle();

        expect(find.widgetWithText(FilledButton, 'Submit bid'), findsOneWidget);
        expect(find.widgetWithText(PrimaryButton, 'Submit bundle bid'),
            findsNothing);
      },
    );

    testWidgets(
      "the owner cancels a released task like an ordinary job, not the "
      'bundle',
      (tester) async {

        final auth = FakeAuthRepository()..walletBalanceSen = 20000;
        final job = sampleJob(
          bundleId: 'b1',
          bundleOrder: 0,
          bundleTaskCount: 2,
          releasedAt: DateTime.now(),
        );
        final bundles = FakeBundleRepository(
            [sampleBundle(id: 'b1', status: BundleStatus.awarded)]);
        await pumpApp(tester, buildApp(auth, jobs: [job], bundle: bundles), size: const Size(500, 1600));
        await logIn(tester);

        await tester.tap(find.text('Fix leaking sink').first);
        await tester.pumpAndSettle();

        final problem = find.text('Problem with this job?');
        await tester.ensureVisible(problem);
        await tester.pumpAndSettle();
        await tester.tap(problem);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel job'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Cancel job'));
        await tester.pumpAndSettle();

        expect(bundles.cancelled, isEmpty);
        expect(find.text('This job was cancelled.'), findsOneWidget);
      },
    );
  });

  // -------------------------------------------------------------------------
  // Awarding a bundle (phase 3): the requestor's screen turns the server's
  // three options into one award action.
  // -------------------------------------------------------------------------
  group('Bundle award', () {
    final tasks = [
      sampleJob(id: 'job-1', title: 'Waterproof the floor', bundleId: 'b1',
          bundleOrder: 0, bundleTaskCount: 2),
      sampleJob(id: 'job-2', title: 'Tile the floor', bundleId: 'b1',
          bundleOrder: 1, bundleTaskCount: 2),
    ];

    final bestValue = sampleOption(totalSen: 87500, providerCount: 2, premiumSen: 3500, weightedTrust: 751, awards: [
        BundleAwardItem(
          providerId: 'prov-1',
          providerName: 'Aida Renovation',
          taskAmountsSen: {'job-1': 37500},
        ),
        BundleAwardItem(
          providerId: 'prov-2',
          providerName: 'Dev Tiling',
          taskAmountsSen: {'job-2': 50000},
        ),
      ]);

    Future<FakeBundleRepository> pumpBundle(
      WidgetTester tester, {
      Bundle? bundle,
    }) async {
      final bundles = FakeBundleRepository([
        bundle ?? sampleBundle(id: 'b1', taskIds: const ['job-1', 'job-2']),
      ])..awardOptions = [bestValue];
      await pumpOwnerBundleScreen(
        tester,
        bundles: bundles,
        tasks: tasks,
        bundleBids: FakeBundleBidRepository([sampleBundleBid()]),
      );
      return bundles;
    }

    testWidgets('awarding an option sends its picks and total', (
      tester,
    ) async {
      final bundles = await pumpBundle(tester);

      await tester.tap(find.widgetWithText(FilledButton,
          'Show award options'));
      await tester.pumpAndSettle();
      expect(find.text('Best Value'), findsOneWidget);
      expect(find.textContaining('+RM 35.00 vs lowest'),
          findsOneWidget);
      expect(find.textContaining('2 providers'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Award this option'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Award'));
      await tester.pumpAndSettle();

      expect(bundles.lastAward?['providerByTaskId'],
          {'job-1': 'prov-1', 'job-2': 'prov-2'});
      expect(bundles.lastAward?['expectedTotalSen'], 87500);
    });

    testWidgets('a partial award can drop the tasks it leaves out', (
      tester,
    ) async {
      final bundles = await pumpBundle(tester);
      // Options are fetched on demand, so swapping them after pumping works.
      bundles.awardOptions = [
        sampleOption(weightedTrust: 751, uncoveredTaskIds: ['job-2']),
      ];

      await tester.tap(find.widgetWithText(FilledButton,
          'Show award options'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Award this option'));
      await tester.pumpAndSettle();

      // Posting separately is the default, so the deadline row shows first.
      expect(find.textContaining('Released back until'), findsOneWidget);
      await tester.tap(find.text('Drop'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Released back until'), findsNothing);
      expect(find.text('It will be cancelled.'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Award'));
      await tester.pumpAndSettle();

      expect(bundles.lastAward?['providerByTaskId'], {'job-1': 'prov-1'});
      expect(bundles.lastAward?['dropUnawarded'], true);
      expect(bundles.lastAward?['releasedDeadline'], isNull);
    });

    testWidgets('a closed bundle hides the award buttons and explains why', (
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

      expect(find.widgetWithText(FilledButton, 'Show award options'),
          findsNothing);
      expect(find.textContaining('Bidding closed on'), findsOneWidget);
      expect(find.textContaining('can no longer be awarded'), findsOneWidget);
    });

    testWidgets('a rejected award brings back "Show award options"', (
      tester,
    ) async {
      final bundles = await pumpBundle(tester);
      bundles.awardError = const BundleRejectedException('The bids changed.');

      await tester.tap(
          find.widgetWithText(FilledButton, 'Show award options'));
      await tester.pumpAndSettle();
      await tester.tap(
          find.widgetWithText(FilledButton, 'Award this option'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Award'));
      await tester.pumpAndSettle();

      expect(find.text('The bids changed.'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Show award options'),
          findsOneWidget);
      expect(find.text('Best Value'), findsNothing);
    });

    testWidgets('an insufficient balance shows the Top up dialog', (
      tester,
    ) async {
      final bundles = await pumpBundle(tester);
      bundles.awardError = const InsufficientBalanceException(
        shortfallSen: 5000,
        availableSen: 30000,
        requiredSen: 35000,
      );

      await tester.tap(
          find.widgetWithText(FilledButton, 'Show award options'));
      await tester.pumpAndSettle();
      await tester.tap(
          find.widgetWithText(FilledButton, 'Award this option'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Award'));
      await tester.pumpAndSettle();

      expect(find.text('Not enough balance'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Top up'), findsOneWidget);
    });

    /// Opens the task row titled [task] and picks [label] in its sheet.
    Future<void> pickManual(
      WidgetTester tester,
      String task,
      String label,
    ) async {
      await tester.ensureVisible(find.text(task));
      await tester.tap(find.text(task));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

    final manualPick = sampleOption(key: 'manual', label: 'Your pick', totalSen: 89500, premiumSen: 2000, awards: [
        BundleAwardItem(
          providerId: 'prov-1',
          providerName: 'Aida Renovation',
          taskAmountsSen: {'job-1': 37500, 'job-2': 52000},
        ),
      ]);

    testWidgets('a manual pick the server refuses shows its problems', (
      tester,
    ) async {
      final bundles = await pumpBundle(tester);
      bundles.manualProblems = const ['Prov-1 already covers job-2 elsewhere.'];

      await pickManual(tester, 'Waterproof the floor', 'Aida Renovation');

      expect(find.text('Prov-1 already covers job-2 elsewhere.'),
          findsOneWidget);
      final award = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Award your pick'));
      expect(award.onPressed, isNull);
    });

    testWidgets('clearing every pick removes the bar', (tester) async {
      final bundles = await pumpBundle(tester);
      bundles.manualOption = manualPick;

      await pickManual(tester, 'Waterproof the floor', 'Aida Renovation');
      expect(find.text('Award your pick'), findsOneWidget);

      await pickManual(tester, 'Waterproof the floor', "Don't award");
      expect(find.text('Award your pick'), findsNothing);
    });
  });
}
