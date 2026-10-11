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

import 'helpers/builders.dart';
import 'helpers/fakes.dart';
import 'helpers/harness.dart';

const _longDescription =
    'What needs doing\nThe kitchen sink leaks under the cabinet and the '
    'cabinet floor is swollen.\n\nAccess & details\nGround floor unit, '
    'parking outside. Weekdays after 6pm or Saturday morning.\n\n'
    'Expected outcome\nNo leaks, cabinet base replaced, area cleaned.';

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
  /// Photos plus a long description push the milestone and review sections
  /// well below the fold of a 360x780 screen at text scale 1.3.
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
  }) => pumpJobDetail(
    tester,
    testJob(
      owner: owner,
      status: status,
      description: _longDescription,
      budget: const JobBudget(minSen: 10000, maxSen: 25000),
      photoUrls: const ['https://example.com/a.jpg', 'https://example.com/b.jpg'],
    ),
    owner: owner,
    milestones: [if (milestone != null) sampleMilestone(status: milestone, owner: owner)],
    milestoneRepo: repo,
    textScale: 1.3,
  );

  group('bottom bar actions work without scrolling (360x780, 1.3x)', () {
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
