import 'package:fairbid/features/auth/domain/app_user.dart';
import 'package:fairbid/features/auth/domain/user_role.dart';
import 'package:fairbid/features/jobs/domain/job.dart';
import 'package:fairbid/features/jobs/presentation/detail/job_detail_view_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/builders.dart';

void main() {
  group('Job detail view model', () {
    // Pure-function tests (no widget pumping) over the role × status matrix
    // that drives the job detail screen's fixed slot order and its bottom
    // bar's single CTA.
    AppUser testUser({
      String uid = 'me',
      UserRole role = UserRole.requestor,
      String verificationStatus = 'none',
    }) => AppUser(
      uid: uid,
      email: '$uid@fairbid.app',
      displayName: uid,
      role: role,
      verificationStatus: verificationStatus,
    );

    test('owner + open with bids: primary action compares them', () {
      final job = sampleJob(requestorId: 'me', bidCount: 3);
      final vm = buildJobDetailVm(job, testUser(), null);

      expect(vm.role, JobViewerRole.owner);
      expect(vm.primaryAction?.kind, JobActionKind.compareBids);
      expect(vm.primaryAction?.label, 'Compare 3 bids');
      expect(vm.showBids, isTrue);
      expect(vm.showMilestones, isFalse);
      expect(vm.showCancel, isTrue);
    });

    test('owner + open with no bids: no action, a waiting line instead', () {
      final job = sampleJob(requestorId: 'me');
      final vm = buildJobDetailVm(job, testUser(), null);

      expect(vm.primaryAction, isNull);
      expect(vm.waitingLine, isNotNull);
    });

    test('owner + in progress: message the provider, milestones and address '
        'show', () {
      final job = sampleJob(
        requestorId: 'me',
        status: JobStatus.inProgress,
        acceptedProviderId: 'prov-1',
        acceptedProviderName: 'Pro Fixer',
        acceptedBidAmountSen: 15000,
      );
      final vm = buildJobDetailVm(job, testUser(), null);

      expect(vm.role, JobViewerRole.owner);
      expect(vm.primaryAction?.kind, JobActionKind.message);
      expect(vm.primaryAction?.label, 'Message provider');
      expect(vm.showMilestones, isTrue);
      expect(vm.showAddress, isTrue);
      expect(vm.showCancel, isTrue);
      expect(vm.showCancellationResponse, isFalse);
    });

    test('owner + in progress with a pending cancellation: the response card '
        'shows', () {
      final job = Job(
        id: 'job-1',
        requestorId: 'me',
        requestorName: 'Test User',
        title: 'Fix leaking sink',
        description: 'Kitchen sink is leaking under the cabinet.',
        category: 'Plumbing',
        location: const JobLocation(
          lat: 3.14,
          lng: 101.7,
          address: 'Bangsar, KL',
        ),
        status: JobStatus.inProgress,
        acceptedProviderId: 'prov-1',
        acceptedProviderName: 'Pro Fixer',
        acceptedBidAmountSen: 15000,
        cancellationRequestedBy: 'provider',
      );
      final vm = buildJobDetailVm(job, testUser(), null);

      expect(vm.showCancellationResponse, isTrue);
      expect(vm.statusHeadline, contains('cancellation'));
    });

    test('owner + completed: leave-a-review is the primary action', () {
      final job = sampleJob(
        requestorId: 'me',
        status: JobStatus.completed,
        acceptedProviderId: 'prov-1',
        acceptedProviderName: 'Pro Fixer',
        acceptedBidAmountSen: 15000,
      );
      final vm = buildJobDetailVm(job, testUser(), null);

      expect(vm.primaryAction?.kind, JobActionKind.leaveReview);
      expect(vm.primaryAction?.label, 'Review Pro Fixer');
      expect(vm.showReviewPrompt, isTrue);
      expect(vm.showCancel, isFalse);
    });

    test('owner + cancelled: no primary action', () {
      final job = sampleJob(requestorId: 'me', status: JobStatus.cancelled);
      final vm = buildJobDetailVm(job, testUser(), null);

      expect(vm.primaryAction, isNull);
      expect(vm.showMilestones, isFalse);
      expect(vm.showCancel, isFalse);
    });

    test('accepted provider + in progress: message the client', () {
      final job = sampleJob(
        status: JobStatus.inProgress,
        acceptedProviderId: 'me',
        acceptedProviderName: 'Pro Fixer',
        acceptedBidAmountSen: 15000,
      );
      final vm = buildJobDetailVm(job, testUser(role: UserRole.provider), null);

      expect(vm.role, JobViewerRole.acceptedProvider);
      expect(vm.primaryAction?.kind, JobActionKind.message);
      expect(vm.primaryAction?.label, 'Message client');
      expect(vm.showMilestones, isTrue);
      expect(vm.showAddress, isTrue);
    });

    test(
      'accepted provider + completed: leave-a-review is the primary action',
      () {
        final job = sampleJob(
          status: JobStatus.completed,
          acceptedProviderId: 'me',
          acceptedProviderName: 'Pro Fixer',
          acceptedBidAmountSen: 15000,
        );
        final vm = buildJobDetailVm(
          job,
          testUser(role: UserRole.provider),
          null,
        );

        expect(vm.primaryAction?.kind, JobActionKind.leaveReview);
        expect(vm.showReviewPrompt, isTrue);
      },
    );

    test('bidder: shows the placed bid', () {
      final job = sampleJob(requestorId: 'req-9');
      final bid = sampleBid(providerId: 'me', amountSen: 15000);
      final vm = buildJobDetailVm(job, testUser(role: UserRole.provider), bid);

      expect(vm.role, JobViewerRole.bidder);
      expect(vm.primaryAction?.kind, JobActionKind.editBid);
      expect(vm.primaryAction?.label, 'Edit bid');
      expect(vm.showBids, isTrue);
    });

    test('browser: a verified provider can submit a bid', () {
      final job = sampleJob(requestorId: 'req-9');
      final vm = buildJobDetailVm(
        job,
        testUser(role: UserRole.provider, verificationStatus: 'approved'),
        null,
      );

      expect(vm.role, JobViewerRole.browser);
      expect(vm.primaryAction?.kind, JobActionKind.submitBid);
    });

    test('browser: an unverified provider is routed to get verified', () {
      final job = sampleJob(requestorId: 'req-9');
      final vm = buildJobDetailVm(job, testUser(role: UserRole.provider), null);

      expect(vm.primaryAction?.kind, JobActionKind.getVerified);
    });

    test('browser: bidding is closed once the deadline has passed', () {
      final job = sampleJob(
        requestorId: 'req-9',
        deadline: DateTime.now().subtract(const Duration(hours: 1)),
      );
      final vm = buildJobDetailVm(
        job,
        testUser(role: UserRole.provider, verificationStatus: 'approved'),
        null,
      );

      expect(vm.primaryAction, isNull);
    });

    test('browser: a non-provider viewer gets no bidding action', () {
      final job = sampleJob(requestorId: 'req-9');
      final vm = buildJobDetailVm(job, testUser(), null);

      expect(vm.role, JobViewerRole.browser);
      expect(vm.primaryAction, isNull);
    });

    test('outsider: no relation to a job that has moved on', () {
      final job = sampleJob(
        requestorId: 'req-9',
        status: JobStatus.inProgress,
        acceptedProviderId: 'prov-1',
        acceptedProviderName: 'Pro Fixer',
      );
      final vm = buildJobDetailVm(job, testUser(role: UserRole.provider), null);

      expect(vm.role, JobViewerRole.outsider);
      expect(vm.primaryAction, isNull);
      expect(vm.showBids, isFalse);
    });

    test('outsider: a cancelled job says so plainly', () {
      final job = sampleJob(requestorId: 'req-9', status: JobStatus.cancelled);
      final vm = buildJobDetailVm(job, testUser(role: UserRole.provider), null);

      expect(vm.statusHeadline, 'This job was cancelled.');
    });

    test('not signed in: browsing an open job with no bidding action', () {
      final job = sampleJob(requestorId: 'req-9');
      final vm = buildJobDetailVm(job, null, null);

      expect(vm.role, JobViewerRole.browser);
      expect(vm.primaryAction, isNull);
    });

    test('owner + open live bundle task: headline counts bundle bids, '
        'action opens the bundle', () {
      final job = sampleJob(
        requestorId: 'me',
        bundleId: 'b1',
        bundleOrder: 0,
        bundleTaskCount: 2,
        bidCount: 2,
      );
      final vm = buildJobDetailVm(job, testUser(), null);

      expect(vm.role, JobViewerRole.owner);
      expect(vm.statusHeadline, '2 bundle bids cover this task.');
      expect(vm.primaryAction?.kind, JobActionKind.viewBundle);
      expect(vm.primaryAction?.label, 'View bundle');
      // The per-job bid list is always empty for a live bundle task - the
      // bundle screen is where its bids actually live.
      expect(vm.showBids, isFalse);
    });

    test('owner + open live bundle task with no bids yet', () {
      final job = sampleJob(
        requestorId: 'me',
        bundleId: 'b1',
        bundleOrder: 0,
        bundleTaskCount: 2,
      );
      final vm = buildJobDetailVm(job, testUser(), null);

      expect(vm.statusHeadline, 'Waiting for providers to bid on this bundle.');
    });

    test('owner + open RELEASED bundle task: reads exactly like an ordinary '
        'job', () {
      final job = sampleJob(
        requestorId: 'me',
        bundleId: 'b1',
        bundleOrder: 0,
        bundleTaskCount: 2,
        bidCount: 1,
        releasedAt: DateTime.now(),
      );
      final vm = buildJobDetailVm(job, testUser(), null);

      expect(vm.primaryAction?.kind, JobActionKind.compareBids);
      expect(vm.primaryAction?.label, 'View 1 bid');
      expect(vm.showBids, isTrue);
    });

    test(
      'browser + live bundle task with a pending covering bundle bid: '
      'edits it instead of being treated as a new bidder',
      () {
        final job = sampleJob(
          requestorId: 'req-9',
          bundleId: 'b1',
          bundleOrder: 0,
          bundleTaskCount: 2,
        );
        final myBundleBid = sampleBundleBid(providerId: 'me', providerName: 'Pro Fixer', taskPrices: const {'job-1': 15000, 'job-2': 20000});
        final vm = buildJobDetailVm(
          job,
          testUser(role: UserRole.provider, verificationStatus: 'approved'),
          null,
          myBundleBid: myBundleBid,
        );

        expect(vm.role, JobViewerRole.browser);
        expect(
          vm.statusHeadline,
          'You bid RM\u00A0150.00 on this task as part of a bundle bid.',
        );
        expect(vm.primaryAction?.kind, JobActionKind.submitBid);
        expect(vm.primaryAction?.label, 'Edit bundle bid');
      },
    );

    test(
      "browser + live bundle task: a bundle bid that doesn't cover this "
      'task is still edited, not re-bid',
      () {
        final job = sampleJob(
          requestorId: 'req-9',
          bundleId: 'b1',
          bundleOrder: 0,
          bundleTaskCount: 2,
        );
        final myBundleBid = sampleBundleBid(providerId: 'me', providerName: 'Pro Fixer', taskPrices: const {'job-2': 20000});
        final vm = buildJobDetailVm(
          job,
          testUser(role: UserRole.provider, verificationStatus: 'approved'),
          null,
          myBundleBid: myBundleBid,
        );

        expect(vm.primaryAction?.kind, JobActionKind.submitBid);
        expect(vm.primaryAction?.label, 'Edit bundle bid');
        expect(
          vm.statusHeadline,
          "Your bundle bid doesn't include this task yet. "
          'Edit it to add this task.',
        );
      },
    );
  });
}
