// Bundle tasks on job detail, My Jobs and the feed card: banners, the
// "View bundle" link and pending bundle bids.
import 'package:fairbid/core/widgets/app_widgets.dart';
import 'package:fairbid/features/jobs/domain/job.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/builders.dart';
import 'helpers/fakes.dart';
import 'helpers/harness.dart';

void main() {
  group('Browser with a pending bundle bid covering an open task', () {
    testWidgets(
      'sees a "Your bundle bid" card instead of Submit a bid, and only the '
      'bottom bar offers to edit the bundle bid',
      (tester) async {

        final task = sampleJob(
          requestorId: 'req-9',
          bundleId: 'b1',
          bundleOrder: 0,
          bundleTaskCount: 2,
        );
        final myBundleBid = sampleBundleBid(providerId: 'uid-1', providerName: 'New User', taskPrices: const {'job-1': 15000});
        final auth = FakeAuthRepository()
          // A newly-registered provider with the default 'none' status is
          // routed into onboarding instead of the main shell.
          ..verificationStatus = 'approved'
          ..baseLat = 3.139
          ..baseLng = 101.6869;
        await pumpApp(tester, buildApp(
          auth,
          jobs: [task],
          bundleBid: FakeBundleBidRepository([myBundleBid]),
        ), size: const Size(500, 1600));
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
        await pumpApp(tester, buildApp(
          auth,
          jobs: [task],
          bundle: FakeBundleRepository(
            [sampleBundle(id: 'b1', title: 'Bathroom refresh')],
          ),
        ), size: const Size(500, 1600));
        await openRegisterAs(tester, 'Work');
        await openTab(tester, 'My jobs');
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

        // Still "live" (never released) but cancelled along with its
        // bundle, and never awarded to anyone.
        final task = sampleJob(
          status: JobStatus.cancelled,
          bundleId: 'b1',
          bundleOrder: 0,
          bundleTaskCount: 2,
        );
        await pumpApp(tester, buildApp(
          FakeAuthRepository(),
          jobs: [task],
          bundle: FakeBundleRepository(
            [sampleBundle(id: 'b1', title: 'Bathroom refresh')],
          ),
        ), size: const Size(500, 1600));
        await logIn(tester);
        await openTab(tester, 'My jobs');
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
      await pumpApp(tester, buildApp(
        FakeAuthRepository(),
        jobs: [task],
        bundle: FakeBundleRepository(
          [sampleBundle(id: 'b1', title: 'Bathroom refresh')],
        ),
      ), size: const Size(500, 1600));
      await logIn(tester);
      await openTab(tester, 'My jobs');
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

    for (final (name, task, body) in [
      (
        'an awarded bundle task puts it in the banner, under the text',
        sampleJob(
          status: JobStatus.inProgress,
          acceptedProviderId: 'prov-1',
          acceptedProviderName: 'Aida Renovation',
          acceptedBidAmountSen: 15000,
          bundleId: 'b1',
          bundleOrder: 0,
          bundleTaskCount: 2,
        ),
        'Awarded as part of',
      ),
      (
        'a released task keeps it in the banner, under the text',
        sampleJob(
          bundleId: 'b1',
          bundleOrder: 0,
          bundleTaskCount: 2,
          releasedAt: DateTime.now(),
        ),
        "wasn't awarded",
      ),
    ]) {
      testWidgets(name, (tester) async {
        await openAsOwner(tester, task);

        final button = find.descendant(
          of: find.byType(InfoBanner),
          matching: find.widgetWithText(TextButton, 'View bundle'),
        );
        expect(button, findsOneWidget);
        expect(find.text('View bundle'), findsOneWidget);
        expect(
          tester.getTopLeft(button).dy,
          greaterThanOrEqualTo(
            tester.getBottomLeft(find.textContaining(body)).dy,
          ),
        );
      });
    }
  });

  group('Bidding fact only while a job is open', () {
    testWidgets('an in-progress job with a deadline hides the Bidding fact',
        (tester) async {

      final job = sampleJob(
        status: JobStatus.inProgress,
        acceptedProviderId: 'prov-1',
        acceptedProviderName: 'Pro Fixer',
        acceptedBidAmountSen: 15000,
        deadline: DateTime.now().add(const Duration(days: 4)),
      );
      await pumpApp(tester, buildApp(FakeAuthRepository(), jobs: [job]), size: const Size(500, 1600));
      await logIn(tester);
      await tester.tap(find.text('Fix leaking sink').first);
      await tester.pumpAndSettle();

      expect(find.text('BIDDING'), findsNothing);
    });

    testWidgets('the same job while still open shows the Bidding fact',
        (tester) async {

      final job = sampleJob(
        deadline: DateTime.now().add(const Duration(days: 4)),
      );
      await pumpApp(tester, buildApp(FakeAuthRepository(), jobs: [job]), size: const Size(500, 1600));
      await logIn(tester);
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
        final bid = sampleBundleBid(providerId: 'uid-1', providerName: 'New User', taskPrices: const {'job-1': 15000, 'job-2': 20000}, bundleTitle: 'Reno bundle');
        final auth = FakeAuthRepository()
          ..verificationStatus = 'approved'
          ..baseLat = 3.139
          ..baseLng = 101.6869;
        await pumpApp(tester, buildApp(
          auth,
          jobs: [second, first],
          bundleBid: FakeBundleBidRepository([bid]),
        ), size: const Size(500, 1600));
        await openRegisterAs(tester, 'Work');
        await openTab(tester, 'My jobs');

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
}
