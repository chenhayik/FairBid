import 'package:fairbid/features/jobs/domain/job.dart';
import 'package:fairbid/features/jobs/domain/milestone.dart';
import 'package:fairbid/features/profile/domain/review.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/builders.dart';
import 'helpers/fakes.dart';
import 'helpers/harness.dart';

void main() {
  group('Reviews', () {
    Future<void> giveStarsAndSubmit(WidgetTester tester, int stars) async {
      await tester.tap(find.byIcon(Icons.star_border_rounded).at(stars - 1));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Submit Review'));
      await tester.pumpAndSettle();
    }

    // A bundle task's extra "Part of a bundle" banner pushes the inline
    // review status card (slot 10) below the fold; scroll to it to check the
    // note it shows. The "Review X" button itself lives on the pinned bar.
    Future<void> scrollToReviewSection(WidgetTester tester) async {
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
      await tester.pumpAndSettle();
    }

    testWidgets(
      'releasing the last milestone completes the job and the requestor '
      'reviews the provider',
      (tester) async {

        final review = FakeReviewRepository();
        final job = sampleJob(
          status: JobStatus.inProgress,
          acceptedProviderId: 'prov-1',
          acceptedProviderName: 'Pro Fixer',
          acceptedBidAmountSen: 15000,
        );
        // The provider already delivered the (only) milestone.
        final milestone = Milestone(
          id: 'ms-1',
          jobId: 'job-1',
          providerId: 'prov-1',
          description: 'Full repair',
          amountSen: 15000,
          status: MilestoneStatus.submitted,
          createdAt: DateTime.now(),
        );
        await pumpApp(tester, buildApp(
            FakeAuthRepository(),
            jobs: [job],
            milestones: [milestone],
            review: review,
          ), size: const Size(500, 1600));
        await logIn(tester);

        await tester.tap(find.text('Fix leaking sink').first);
        await tester.pumpAndSettle();
        expect(find.text('Assigned provider'), findsOneWidget);
        expect(find.text('1. Full repair'), findsOneWidget);

        // Release the delivered milestone from the bottom bar (with
        // confirmation) - the last one, so the job completes.
        final releaseBtn = find.widgetWithText(
          FilledButton,
          'Release RM 150.00',
        );
        expect(find.widgetWithText(FilledButton, 'Release payment'),
            findsNothing);
        await tester.tap(releaseBtn);
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.widgetWithText(FilledButton, 'Release'),
          ),
        );
        await tester.pumpAndSettle();

        // Completed → review the provider with 5★ from the bottom bar.
        final reviewBtn = find.widgetWithText(FilledButton, 'Review Pro Fixer');
        expect(reviewBtn, findsOneWidget);
        await tester.tap(reviewBtn);
        await tester.pumpAndSettle();
        expect(find.text('Leave a Review'), findsOneWidget);
        await giveStarsAndSubmit(tester, 5);

        expect(review.left.single.rating, 5);
        await scrollToReviewSection(tester);
        expect(find.text('Review submitted'), findsOneWidget);
      },
    );

    testWidgets('accepted provider reviews the requestor on a completed job', (
      tester,
    ) async {

      final review = FakeReviewRepository();
      final job = sampleJob(
        requestorId: 'req-9',
        requestorName: 'Rita Client',
        status: JobStatus.completed,
        acceptedProviderId: 'uid-1',
        acceptedProviderName: 'New User',
        acceptedBidAmountSen: 15000,
      );
      final auth = FakeAuthRepository()
        ..verificationStatus = 'approved'
        ..baseLat = 3.139
        ..baseLng = 101.6869;
      await pumpApp(tester, buildApp(auth, jobs: [job], review: review), size: const Size(500, 1600));
      await openRegisterAs(tester, 'Work');

      // The provider reaches their won job via the My Jobs tab.
      await openTab(tester, 'My jobs');
      await tester.tap(find.text('Fix leaking sink').first);
      await tester.pumpAndSettle();

      // "Review Rita Client" is the bottom bar's button only.
      final reviewBtn = find.widgetWithText(FilledButton, 'Review Rita Client');
      expect(reviewBtn, findsOneWidget);
      await tester.tap(reviewBtn);
      await tester.pumpAndSettle();
      await giveStarsAndSubmit(tester, 4);

      expect(review.left.single.reviewerId, 'uid-1');
      expect(review.left.single.rating, 4);
    });

    testWidgets('a second review on the same job is rejected', (tester) async {

      final review = FakeReviewRepository();
      // The requestor already reviewed the provider on this job.
      await review.leaveReview(
        revieweeId: 'prov-1',
        review: const Review(
          id: '',
          reviewerId: 'uid-1',
          reviewerName: 'Test User',
          rating: 5,
          jobId: 'job-1',
        ),
      );
      final job = sampleJob(
        status: JobStatus.completed,
        acceptedProviderId: 'prov-1',
        acceptedProviderName: 'Pro Fixer',
        acceptedBidAmountSen: 15000,
      );
      await pumpApp(tester, buildApp(FakeAuthRepository(), jobs: [job], review: review), size: const Size(500, 1600));
      await logIn(tester);

      // Completed jobs are hidden from Active Jobs, so open it via My Jobs.
      await openTab(tester, 'My jobs');
      await tester.tap(find.text('Fix leaking sink').first);
      await tester.pumpAndSettle();

      // "Review Pro Fixer" is the bottom bar's button only.
      final reviewBtn = find.widgetWithText(FilledButton, 'Review Pro Fixer');
      expect(reviewBtn, findsOneWidget);
      await tester.tap(reviewBtn);
      await tester.pumpAndSettle();
      await giveStarsAndSubmit(tester, 5);

      expect(find.text('You have already reviewed this job.'), findsOneWidget);
    });

    for (final released in [false, true]) {
      testWidgets(
        'reviewing a completed ${released ? 'RELEASED' : 'live'} bundle task '
        'writes a bundle-keyed review id, not a job-keyed one - rules key on '
        'bundleId alone, not releasedAt',
        (tester) async {
          final review = FakeReviewRepository();
          final bundleTask = sampleJob(
            status: JobStatus.completed,
            acceptedProviderId: 'prov-1',
            acceptedProviderName: 'Pro Fixer',
            acceptedBidAmountSen: 15000,
            bundleId: 'bundle-1',
            bundleTaskCount: 1,
            releasedAt: released ? DateTime.now() : null,
          );
          await pumpApp(tester, buildApp(FakeAuthRepository(), jobs: [bundleTask], review: review), size: const Size(500, 1600));
          await logIn(tester);

          await openTab(tester, 'My jobs');
          await tester.tap(find.text('Fix leaking sink').first);
          await tester.pumpAndSettle();
          await scrollToReviewSection(tester);
          final reviewBtn = find
              .widgetWithText(FilledButton, 'Review Pro Fixer')
              .first;
          await tester.ensureVisible(reviewBtn);
          await tester.tap(reviewBtn);
          await tester.pumpAndSettle();
          await giveStarsAndSubmit(tester, 5);

          expect(review.left.single.jobId, 'job-1');
          expect(await review.hasReviewed(
            revieweeId: 'prov-1',
            jobId: 'job-1',
            reviewerId: 'uid-1',
            bundleId: 'bundle-1',
          ), isTrue);
          expect(await review.hasReviewed(
            revieweeId: 'prov-1',
            jobId: 'job-1',
            reviewerId: 'uid-1',
          ), isFalse);
        },
      );
    }

    testWidgets(
      "a completed bundle task's review waits while the provider still has "
      'another task in progress, then opens once every task is done',
      (tester) async {

        final review = FakeReviewRepository();
        final taskA = sampleJob(
          id: 'job-1',
          title: 'Fix leaking sink',
          status: JobStatus.completed,
          acceptedProviderId: 'prov-1',
          acceptedProviderName: 'Pro Fixer',
          acceptedBidAmountSen: 15000,
          bundleId: 'bundle-1',
          bundleOrder: 0,
          bundleTaskCount: 2,
        );
        final taskBInProgress = sampleJob(
          id: 'job-2',
          title: 'Retile the floor',
          status: JobStatus.inProgress,
          acceptedProviderId: 'prov-1',
          acceptedProviderName: 'Pro Fixer',
          acceptedBidAmountSen: 20000,
          bundleId: 'bundle-1',
          bundleOrder: 1,
          bundleTaskCount: 2,
        );
        final jobRepo = FakeJobRepository([taskA, taskBInProgress]);
        await pumpApp(tester, buildApp(
            FakeAuthRepository(),
            jobRepository: jobRepo,
            review: review,
          ), size: const Size(500, 1600));
        await logIn(tester);

        await openTab(tester, 'My jobs');
        await tester.tap(find.text('Fix leaking sink').first);
        await tester.pumpAndSettle();
        await scrollToReviewSection(tester);

        expect(
          find.text(
            'You can review Pro Fixer once all their tasks in this bundle '
            'are done.',
          ),
          findsOneWidget,
        );
        // Only the pinned bottom bar's button exists - the inline slot shows
        // the wait banner.
        expect(
          find.widgetWithText(FilledButton, 'Review Pro Fixer'),
          findsOneWidget,
        );

        // The provider's other task finishes too - leave and reopen the job
        // so the inline card's one-shot gate check runs again.
        jobRepo.complete('job-2');
        await tester.pageBack();
        await tester.pumpAndSettle();
        await tester.tap(find.text('Fix leaking sink').first);
        await tester.pumpAndSettle();
        await scrollToReviewSection(tester);

        expect(
          find.text(
            'You can review Pro Fixer once all their tasks in this bundle '
            'are done.',
          ),
          findsNothing,
        );
        // The wait banner is gone and the bar's button is what's left.
        expect(
          find.widgetWithText(FilledButton, 'Review Pro Fixer'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'reviewing one bundle task counts for the rest of the same provider\'s '
      'tasks in the bundle',
      (tester) async {

        final review = FakeReviewRepository();
        final taskA = sampleJob(
          id: 'job-1',
          title: 'Fix leaking sink',
          status: JobStatus.completed,
          acceptedProviderId: 'prov-1',
          acceptedProviderName: 'Pro Fixer',
          acceptedBidAmountSen: 15000,
          bundleId: 'bundle-1',
          bundleOrder: 0,
          bundleTaskCount: 2,
        );
        final taskB = sampleJob(
          id: 'job-2',
          title: 'Retile the floor',
          status: JobStatus.completed,
          acceptedProviderId: 'prov-1',
          acceptedProviderName: 'Pro Fixer',
          acceptedBidAmountSen: 20000,
          bundleId: 'bundle-1',
          bundleOrder: 1,
          bundleTaskCount: 2,
        );
        await pumpApp(tester, buildApp(
            FakeAuthRepository(),
            jobs: [taskA, taskB],
            review: review,
          ), size: const Size(500, 1600));
        await logIn(tester);

        await openTab(tester, 'My jobs');
        await tester.tap(find.text('Fix leaking sink').first);
        await tester.pumpAndSettle();
        await scrollToReviewSection(tester);
        final reviewBtn = find
            .widgetWithText(FilledButton, 'Review Pro Fixer')
            .first;
        await tester.ensureVisible(reviewBtn);
        await tester.tap(reviewBtn);
        await tester.pumpAndSettle();
        await giveStarsAndSubmit(tester, 5);
        await scrollToReviewSection(tester);
        expect(find.text('Review submitted'), findsOneWidget);

        // Leave and check task B - same provider, same bundle, already
        // reviewed via task A.
        await tester.pageBack();
        await tester.pumpAndSettle();
        await tester.tap(find.text('Retile the floor').first);
        await tester.pumpAndSettle();
        await scrollToReviewSection(tester);

        expect(find.text('Review submitted'), findsOneWidget);
        // Only the pinned bottom bar's button exists - the inline slot shows
        // the already-reviewed state.
        expect(
          find.widgetWithText(FilledButton, 'Review Pro Fixer'),
          findsOneWidget,
        );
      },
    );
  });
}
