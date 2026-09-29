// UI fixes for job detail, handover, My Jobs, feed card and admin stats
// (batch C). Reuses the fakes/helpers already built up in widget_test.dart
// rather than duplicating them.
import 'package:fairbid/core/widgets/app_widgets.dart';
import 'package:fairbid/features/jobs/domain/bundle_bid.dart';
import 'package:fairbid/features/jobs/domain/job.dart';
import 'package:fairbid/features/jobs/domain/job_event.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'widget_test.dart';

void main() {
  group('Browser with a pending bundle bid covering an open task', () {
    testWidgets(
      'sees a "Your bundle bid" card instead of Submit a bid, and only the '
      'bottom bar offers to edit the bundle bid',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(500, 1600));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final task = sampleJob(
          requestorId: 'req-9',
          bundleId: 'b1',
          bundleOrder: 0,
          bundleTaskCount: 2,
        );
        final myBundleBid = BundleBid(
          bundleId: 'b1',
          providerId: 'uid-1',
          providerName: 'New User',
          taskPrices: const {'job-1': 15000},
          estimatedDuration: '1 week',
        );
        final auth = FakeAuthRepository()
          // A newly-registered provider with the default 'none' status is
          // routed into onboarding instead of the main shell.
          ..verificationStatus = 'approved'
          ..baseLat = 3.139
          ..baseLng = 101.6869;
        await tester.pumpWidget(buildApp(
          auth,
          jobs: [task],
          bundleBid: FakeBundleBidRepository([myBundleBid]),
        ));
        await tester.pumpAndSettle();
        await openRegisterAs(tester, 'Work');
        await tester.tap(find.text('Fix leaking sink').first);
        await tester.pumpAndSettle();

        // The inline bid-list slot never shows the ordinary "Submit a bid"
        // action for this provider on this task.
        expect(find.text('Submit a bid'), findsNothing);
        expect(
          find.textContaining('for this task (part of your bundle bid)'),
          findsOneWidget,
        );
        expect(find.text('Your bundle bid'), findsOneWidget);
        // The card has no button of its own: editing is the pinned bottom
        // bar's action, and it appears exactly once.
        expect(find.widgetWithText(OutlinedButton, 'Edit bundle bid'),
            findsNothing);
        expect(
          find.widgetWithText(FilledButton, 'Edit bundle bid'),
          findsOneWidget,
        );
      },
    );
  });

  group('Awarded bundle task banner', () {
    testWidgets(
      'an in-progress bundle task shows "Awarded as part of ..." instead '
      'of the bidding-time explanation',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(500, 1600));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final task = sampleJob(
          requestorId: 'req-9',
          status: JobStatus.inProgress,
          acceptedProviderId: 'uid-1',
          acceptedProviderName: 'New User',
          acceptedBidAmountSen: 15000,
          bundleId: 'b1',
          bundleOrder: 0,
          bundleTaskCount: 2,
        );
        final auth = FakeAuthRepository()
          ..verificationStatus = 'approved'
          ..baseLat = 3.139
          ..baseLng = 101.6869;
        await tester.pumpWidget(buildApp(
          auth,
          jobs: [task],
          bundle: FakeBundleRepository(
            [sampleBundle(id: 'b1', title: 'Bathroom refresh')],
          ),
        ));
        await tester.pumpAndSettle();
        await openRegisterAs(tester, 'Work');
        await tester.tap(
          find.descendant(
            of: find.byType(NavigationBar),
            matching: find.text('My jobs'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Fix leaking sink').first);
        await tester.pumpAndSettle();

        expect(find.textContaining('Awarded as part of "Bathroom refresh"'),
            findsOneWidget);
        // The bidding-time sentence is gone now that the task is awarded.
        expect(find.textContaining('Providers bid on the'), findsNothing);
      },
    );

    testWidgets(
      "a cancelled bundle task that was never awarded shows no "
      '"Awarded as part of ..." banner',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(500, 1600));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        // Still "live" (never released) but cancelled along with its
        // bundle, and never awarded to anyone.
        final task = sampleJob(
          status: JobStatus.cancelled,
          bundleId: 'b1',
          bundleOrder: 0,
          bundleTaskCount: 2,
        );
        await tester.pumpWidget(buildApp(
          FakeAuthRepository(),
          jobs: [task],
          bundle: FakeBundleRepository(
            [sampleBundle(id: 'b1', title: 'Bathroom refresh')],
          ),
        ));
        await tester.pumpAndSettle();
        await fillField(tester, 'Email', 'a@b.com');
        await fillField(tester, 'Password', 'secret123');
        await tester.tap(find.widgetWithText(FilledButton, 'Log In'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byType(NavigationBar),
            matching: find.text('My jobs'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Fix leaking sink').first);
        await tester.pumpAndSettle();

        expect(find.text('This job was cancelled.'), findsOneWidget);
        expect(find.textContaining('Awarded as part of'), findsNothing);
        expect(find.textContaining('Providers bid on the'), findsNothing);
        expect(find.text('Part of a bundle'), findsNothing);
      },
    );
  });

  group('"View bundle" on the bundle banners', () {
    /// Signs a requestor in (uid-1, owner of [sampleJob]) and opens [task].
    Future<void> openAsOwner(WidgetTester tester, Job task) async {
      await tester.binding.setSurfaceSize(const Size(500, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(buildApp(
        FakeAuthRepository(),
        jobs: [task],
        bundle: FakeBundleRepository(
          [sampleBundle(id: 'b1', title: 'Bathroom refresh')],
        ),
      ));
      await tester.pumpAndSettle();
      await fillField(tester, 'Email', 'a@b.com');
      await fillField(tester, 'Password', 'secret123');
      await tester.tap(find.widgetWithText(FilledButton, 'Log In'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('My jobs'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fix leaking sink').first);
      await tester.pumpAndSettle();
    }

    testWidgets(
      'an open bundle task offers it once, in the bottom bar only',
      (tester) async {
        await openAsOwner(
          tester,
          sampleJob(bundleId: 'b1', bundleOrder: 0, bundleTaskCount: 2),
        );

        expect(find.text('Part of a bundle'), findsOneWidget);
        expect(find.text('View bundle'), findsOneWidget);
        expect(find.widgetWithText(FilledButton, 'View bundle'), findsOneWidget);
      },
    );

    testWidgets(
      'an awarded bundle task puts it in the banner, under the text',
      (tester) async {
        await openAsOwner(
          tester,
          sampleJob(
            status: JobStatus.inProgress,
            acceptedProviderId: 'prov-1',
            acceptedProviderName: 'Aida Renovation',
            acceptedBidAmountSen: 15000,
            bundleId: 'b1',
            bundleOrder: 0,
            bundleTaskCount: 2,
          ),
        );

        final button = find.descendant(
          of: find.byType(InfoBanner),
          matching: find.widgetWithText(TextButton, 'View bundle'),
        );
        expect(button, findsOneWidget);
        expect(find.text('View bundle'), findsOneWidget);
        final body = find.textContaining('Awarded as part of');
        expect(
          tester.getTopLeft(button).dy,
          greaterThanOrEqualTo(tester.getBottomLeft(body).dy),
        );
      },
    );

    testWidgets(
      'a released task keeps it in the banner, under the text',
      (tester) async {
        await openAsOwner(
          tester,
          sampleJob(
            bundleId: 'b1',
            bundleOrder: 0,
            bundleTaskCount: 2,
            releasedAt: DateTime.now(),
          ),
        );

        final button = find.descendant(
          of: find.byType(InfoBanner),
          matching: find.widgetWithText(TextButton, 'View bundle'),
        );
        expect(button, findsOneWidget);
        expect(
          tester.getTopLeft(button).dy,
          greaterThanOrEqualTo(
            tester.getBottomLeft(find.textContaining("wasn't awarded")).dy,
          ),
        );
      },
    );
  });

  group('Bidding fact only while a job is open', () {
    testWidgets('an in-progress job with a deadline hides the Bidding fact',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final job = sampleJob(
        status: JobStatus.inProgress,
        acceptedProviderId: 'prov-1',
        acceptedProviderName: 'Pro Fixer',
        acceptedBidAmountSen: 15000,
        deadline: DateTime.now().add(const Duration(days: 4)),
      );
      await tester.pumpWidget(buildApp(FakeAuthRepository(), jobs: [job]));
      await tester.pumpAndSettle();
      await fillField(tester, 'Email', 'a@b.com');
      await fillField(tester, 'Password', 'secret123');
      await tester.tap(find.widgetWithText(FilledButton, 'Log In'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fix leaking sink').first);
      await tester.pumpAndSettle();

      expect(find.text('BIDDING'), findsNothing);
    });

    testWidgets('the same job while still open shows the Bidding fact',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final job = sampleJob(
        deadline: DateTime.now().add(const Duration(days: 4)),
      );
      await tester.pumpWidget(buildApp(FakeAuthRepository(), jobs: [job]));
      await tester.pumpAndSettle();
      await fillField(tester, 'Email', 'a@b.com');
      await fillField(tester, 'Password', 'secret123');
      await tester.tap(find.widgetWithText(FilledButton, 'Log In'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fix leaking sink').first);
      await tester.pumpAndSettle();

      expect(find.text('BIDDING'), findsOneWidget);
    });
  });

  group('Pending bundle bid tile', () {
    testWidgets(
      'opens the covered task with the lowest bundleOrder, not whichever '
      'key a Firestore map happens to iterate first',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(500, 1600));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final second = sampleJob(
          id: 'job-1',
          title: 'Second task',
          requestorId: 'req-9',
          bundleId: 'b1',
          bundleOrder: 1,
          bundleTaskCount: 2,
        );
        final first = sampleJob(
          id: 'job-2',
          title: 'First task',
          requestorId: 'req-9',
          bundleId: 'b1',
          bundleOrder: 0,
          bundleTaskCount: 2,
        );
        // Declared job-1 (the higher bundleOrder) first, so a naive
        // `taskPrices.keys.first` would open the wrong task.
        final bid = BundleBid(
          bundleId: 'b1',
          providerId: 'uid-1',
          providerName: 'New User',
          taskPrices: const {'job-1': 15000, 'job-2': 20000},
          estimatedDuration: '1 week',
          bundleTitle: 'Reno bundle',
        );
        final auth = FakeAuthRepository()
          ..verificationStatus = 'approved'
          ..baseLat = 3.139
          ..baseLng = 101.6869;
        await tester.pumpWidget(buildApp(
          auth,
          jobs: [second, first],
          bundleBid: FakeBundleBidRepository([bid]),
        ));
        await tester.pumpAndSettle();
        await openRegisterAs(tester, 'Work');
        await tester.tap(
          find.descendant(
            of: find.byType(NavigationBar),
            matching: find.text('My jobs'),
          ),
        );
        await tester.pumpAndSettle();

        // The tile's primary line is the quoted amount now (aligned with
        // the per-job pending-bid tile), so the bundle title only appears
        // as part of a longer caption - match on a substring.
        await tester.tap(find.textContaining('Reno bundle'));
        await tester.pumpAndSettle();

        expect(find.text('First task'), findsOneWidget);
        expect(find.text('Second task'), findsNothing);
      },
    );
  });

  group('Handover banner names the previous task', () {
    testWidgets(
      'names the predecessor task when it can be loaded, with warning '
      'styling and the action below the text',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(500, 1600));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final predecessor = sampleJob(
          id: 'job-0',
          title: 'Waterproofing',
          requestorId: 'req-9',
          status: JobStatus.completed,
        );
        final dependent = sampleJob(
          requestorId: 'req-9',
          status: JobStatus.inProgress,
          acceptedProviderId: 'uid-1',
          acceptedProviderName: 'New User',
          acceptedBidAmountSen: 15000,
          startsAfterJobId: 'job-0',
        );
        final auth = FakeAuthRepository()
          ..verificationStatus = 'approved'
          ..baseLat = 3.139
          ..baseLng = 101.6869;
        await tester.pumpWidget(
          buildApp(auth, jobs: [predecessor, dependent]),
        );
        await tester.pumpAndSettle();
        await openRegisterAs(tester, 'Work');
        await tester.tap(
          find.descendant(
            of: find.byType(NavigationBar),
            matching: find.text('My jobs'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Fix leaking sink').first);
        await tester.pumpAndSettle();

        expect(find.text('Site handover needed'), findsOneWidget);
        expect(
          find.textContaining(
            'Record the site handover before you start. This task follows '
            '"Waterproofing".',
          ),
          findsOneWidget,
        );
        expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
        expect(find.widgetWithText(TextButton, 'Record handover'),
            findsOneWidget);
      },
    );
  });

  group('Handover timeline entry', () {
    testWidgets(
      'names who recorded it when it was the accepted provider',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(500, 1600));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final job = sampleJob(
          status: JobStatus.completed,
          acceptedProviderId: 'prov-1',
          acceptedProviderName: 'Pro Fixer',
          acceptedBidAmountSen: 15000,
        );
        final jobs = FakeJobRepository([job], {
          'job-1': [
            JobEvent(
              id: 'handover',
              type: 'handover',
              title: 'Site handover recorded',
              at: DateTime.now(),
              note: 'Site is clear.',
              by: 'prov-1',
            ),
          ],
        });
        await tester.pumpWidget(
          buildApp(FakeAuthRepository(), jobRepository: jobs),
        );
        await tester.pumpAndSettle();
        await fillField(tester, 'Email', 'a@b.com');
        await fillField(tester, 'Password', 'secret123');
        await tester.tap(find.widgetWithText(FilledButton, 'Log In'));
        await tester.pumpAndSettle();
        // Completed jobs are hidden from the Home "Active Jobs" list, so
        // open it via My Jobs instead.
        await tester.tap(
          find.descendant(
            of: find.byType(NavigationBar),
            matching: find.text('My jobs'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Fix leaking sink').first);
        await tester.pumpAndSettle();

        await tester.tap(find.text('Activity'));
        await tester.pumpAndSettle();

        expect(find.text('Recorded by Pro Fixer'), findsOneWidget);
      },
    );
  });
}
