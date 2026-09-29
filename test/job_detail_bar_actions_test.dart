// Regression: the job detail's bottom bar drives the milestone and review
// sections through GlobalKeys, which silently did nothing on a phone-sized
// screen while those sections were built lazily (off-screen, so unmounted).
import 'dart:async';

import 'package:fairbid/core/util/money.dart';
import 'package:fairbid/core/widgets/app_widgets.dart';
import 'package:fairbid/features/auth/domain/app_user.dart';
import 'package:fairbid/features/auth/domain/user_role.dart';
import 'package:fairbid/features/jobs/domain/job.dart';
import 'package:fairbid/features/jobs/domain/milestone.dart';
import 'package:fairbid/features/jobs/presentation/detail/job_detail_view_model.dart';
import 'package:fairbid/features/profile/presentation/leave_review_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'widget_test.dart';

const _longDescription =
    'What needs doing\nThe kitchen sink leaks under the cabinet and the '
    'cabinet floor is swollen.\n\nAccess & details\nGround floor unit, '
    'parking outside. Weekdays after 6pm or Saturday morning.\n\n'
    'Expected outcome\nNo leaks, cabinet base replaced, area cleaned.';

/// Photos plus a long description push the milestone and review sections
/// well below the fold of a 360x780 screen.
Job _tallJob({
  required bool owner,
  JobStatus status = JobStatus.inProgress,
}) => Job(
  id: 'job-1',
  requestorId: owner ? 'uid-1' : 'req-9',
  requestorName: 'Rita Client',
  title: 'Fix leaking sink',
  description: _longDescription,
  category: 'Plumbing',
  location: const JobLocation(lat: 3.14, lng: 101.7, address: 'Bangsar, KL'),
  budget: const JobBudget(minSen: 10000, maxSen: 25000),
  photoUrls: const [
    'https://example.com/a.jpg',
    'https://example.com/b.jpg',
  ],
  createdAt: DateTime.now(),
  status: status,
  acceptedProviderId: owner ? 'prov-1' : 'uid-1',
  acceptedProviderName: 'Pro Fixer',
  acceptedBidAmountSen: 15000,
);

Milestone _milestone(MilestoneStatus status, {required bool owner}) =>
    Milestone(
      id: 'ms-1',
      jobId: 'job-1',
      providerId: owner ? 'prov-1' : 'uid-1',
      description: 'Full repair',
      amountSen: 15000,
      order: 0,
      status: status,
      createdAt: DateTime.now(),
    );

/// A release that stays in flight until [gate] completes.
class _SlowReleaseRepository extends FakeMilestoneRepository {
  _SlowReleaseRepository(super.jobs, super.seed);
  final gate = Completer<void>();

  @override
  Future<void> releaseMilestone(String jobId, String milestoneId) async {
    await gate.future;
    return super.releaseMilestone(jobId, milestoneId);
  }
}

void main() {
  /// Opens `/jobs/job-1` at 360x780, text scale 1.3, and never scrolls.
  Future<void> open(
    WidgetTester tester, {
    required bool owner,
    required MilestoneStatus? milestone,
    JobStatus status = JobStatus.inProgress,
    FakeMilestoneRepository Function(
      FakeJobRepository jobs,
      List<Milestone> seed,
    )?
    repo,
  }) async {
    tester.view.physicalSize = const Size(360, 780) * 2;
    tester.view.devicePixelRatio = 2;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.reset);
    // The test font is far wider than a real one, so unrelated RenderFlex
    // overflows would otherwise fail these behaviour tests.
    final onError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (!details.exceptionAsString().contains('overflowed')) {
        onError?.call(details);
      }
    };
    addTearDown(() => FlutterError.onError = onError);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    // Providers must be verified, or the app routes them to onboarding.
    final auth = FakeAuthRepository()
      ..verificationStatus = 'approved'
      ..seedSignedIn(owner ? UserRole.requestor : UserRole.provider);
    final job = _tallJob(owner: owner, status: status);
    final seed = [if (milestone != null) _milestone(milestone, owner: owner)];
    final jobs = FakeJobRepository([job]);
    await tester.pumpWidget(
      buildApp(
        auth,
        jobRepository: jobs,
        milestoneRepository: repo?.call(jobs, seed) ??
            FakeMilestoneRepository(jobs, seed),
      ),
    );
    await tester.pumpAndSettle();
    GoRouter.of(tester.element(find.byType(Scaffold).first))
        .push<void>('/jobs/job-1');
    await tester.pumpAndSettle();
  }

  group('bottom bar actions work without scrolling (360x780, 1.3x)', () {
    testWidgets('owner Approve plan opens the confirm', (tester) async {
      await open(tester, owner: true, milestone: MilestoneStatus.proposed);
      await tester.tap(find.widgetWithText(FilledButton, 'Approve plan'));
      await tester.pumpAndSettle();
      expect(find.text('Approve this plan?'), findsOneWidget);
    });

    testWidgets('owner Fund opens the confirm', (tester) async {
      await open(tester, owner: true, milestone: MilestoneStatus.pending);
      await tester.tap(find.widgetWithText(FilledButton, 'Fund ${formatRm(15000)}'));
      await tester.pumpAndSettle();
      expect(find.text('Fund this milestone?'), findsOneWidget);
    });

    testWidgets('owner Release opens the confirm', (tester) async {
      await open(tester, owner: true, milestone: MilestoneStatus.submitted);
      await tester.tap(find.widgetWithText(FilledButton, 'Release ${formatRm(15000)}'));
      await tester.pumpAndSettle();
      expect(find.text('Release payment?'), findsOneWidget);
    });

    testWidgets('provider Mark as delivered opens the confirm', (
      tester,
    ) async {
      await open(tester, owner: false, milestone: MilestoneStatus.funded);
      await tester.tap(find.widgetWithText(FilledButton, 'Mark as delivered'));
      await tester.pumpAndSettle();
      expect(find.text('Mark as delivered?'), findsOneWidget);
    });

    testWidgets('owner Review opens the sheet on a completed job', (
      tester,
    ) async {
      await open(
        tester,
        owner: true,
        status: JobStatus.completed,
        milestone: MilestoneStatus.released,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Review Pro Fixer'));
      await tester.pumpAndSettle();
      expect(find.byType(LeaveReviewSheet), findsOneWidget);
    });
  });

  testWidgets('bar button shows busy and ignores taps while a release runs', (
    tester,
  ) async {
    late _SlowReleaseRepository slow;
    await open(
      tester,
      owner: true,
      milestone: MilestoneStatus.submitted,
      repo: (jobs, seed) => slow = _SlowReleaseRepository(jobs, seed),
    );
    final bar = find.widgetWithText(PrimaryButton, 'Release ${formatRm(15000)}');
    await tester.tap(bar);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Release').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // In flight: the bar shows a spinner and a repeat tap opens nothing.
    final busyBar = find.byWidgetPredicate(
      (w) => w is PrimaryButton && w.busy,
    );
    expect(busyBar, findsOneWidget);
    await tester.tap(busyBar);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Release payment?'), findsNothing);

    slow.gate.complete();
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate((w) => w is PrimaryButton && w.busy),
      findsNothing,
    );
  });

  test('owner headline agrees with the bundle bid count', () {
    Job task(int bids) => Job(
      id: 'job-1',
      requestorId: 'uid-1',
      requestorName: 'Rita Client',
      title: 'Paint',
      description: 'Paint the walls.',
      category: 'Painting',
      location: const JobLocation(lat: 3.14, lng: 101.7, address: 'Penang'),
      budget: const JobBudget(minSen: 10000, maxSen: 25000),
      createdAt: DateTime.now(),
      status: JobStatus.open,
      bundleId: 'b1',
      bundleOrder: 0,
      bundleTaskCount: 2,
      bidCount: bids,
    );
    String headline(int n) =>
        buildJobDetailVm(
          task(n),
          const AppUser(
            uid: 'uid-1',
            email: 'uid-1@fairbid.app',
            displayName: 'Rita Client',
            role: UserRole.requestor,
          ),
          null,
        ).statusHeadline;
    expect(headline(1), '1 bundle bid covers this task.');
    expect(headline(3), '3 bundle bids cover this task.');
  });
}
