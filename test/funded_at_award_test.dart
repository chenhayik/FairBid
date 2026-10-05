// A job funded at award has one funded "Full job" stage from the start, so
// nobody is ever asked to propose, approve, fund or amend a plan.
import 'package:fairbid/core/util/money.dart';
import 'package:fairbid/features/auth/domain/user_role.dart';
import 'package:fairbid/features/jobs/domain/job.dart';
import 'package:fairbid/features/jobs/domain/milestone.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'widget_test.dart';

Job _job({required bool owner, bool funded = true}) => Job(
  id: 'job-1',
  requestorId: owner ? 'uid-1' : 'req-9',
  requestorName: 'Rita Client',
  title: 'Fix leaking sink',
  description: 'The kitchen sink leaks.',
  category: 'Plumbing',
  location: const JobLocation(lat: 3.14, lng: 101.7, address: 'Bangsar, KL'),
  createdAt: DateTime.now(),
  status: JobStatus.inProgress,
  acceptedProviderId: owner ? 'prov-1' : 'uid-1',
  acceptedProviderName: 'Pro Fixer',
  acceptedBidAmountSen: 15000,
  fundedAtAward: funded,
);

Milestone _fullJob({
  required bool owner,
  MilestoneStatus status = MilestoneStatus.funded,
}) => Milestone(
  id: 'm0',
  jobId: 'job-1',
  providerId: owner ? 'prov-1' : 'uid-1',
  description: 'Full job',
  amountSen: 15000,
  order: 0,
  status: status,
  createdAt: DateTime.now(),
);

void main() {
  Future<void> open(
    WidgetTester tester, {
    required bool owner,
    bool funded = true,
    bool withMilestone = true,
    MilestoneStatus stageStatus = MilestoneStatus.funded,
  }) async {
    tester.view.physicalSize = const Size(360, 1200) * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final auth = FakeAuthRepository()
      ..verificationStatus = 'approved'
      ..seedSignedIn(owner ? UserRole.requestor : UserRole.provider);
    final jobs = FakeJobRepository([_job(owner: owner, funded: funded)]);
    await tester.pumpWidget(
      buildApp(
        auth,
        jobRepository: jobs,
        milestoneRepository: FakeMilestoneRepository(jobs, [
          if (withMilestone) _fullJob(owner: owner, status: stageStatus),
        ]),
      ),
    );
    await tester.pumpAndSettle();
    GoRouter.of(
      tester.element(find.byType(Scaffold).first),
    ).push<void>('/jobs/job-1');
    await tester.pumpAndSettle();
  }

  void expectNoPlanUi() {
    expect(find.text('Propose milestones'), findsNothing);
    expect(find.text('Approve plan'), findsNothing);
    expect(find.text('Request changes'), findsNothing);
    expect(find.text('Agree the plan'), findsNothing);
    expect(find.text('Amend'), findsNothing);
    expect(find.textContaining('Fund RM'), findsNothing);
  }

  testWidgets('provider sees Mark as delivered and no plan UI', (tester) async {
    await open(tester, owner: false);
    expect(
      find.widgetWithText(FilledButton, 'Mark as delivered'),
      findsOneWidget,
    );
    expect(find.textContaining('${formatRm(15000)} secured in escrow'), findsOneWidget);
    expectNoPlanUi();
  });

  testWidgets('owner waits on delivery and is never asked to fund', (
    tester,
  ) async {
    await open(tester, owner: true);
    expect(
      find.textContaining('${formatRm(15000)} is secured in escrow. Waiting for'),
      findsOneWidget,
    );
    expectNoPlanUi();
  });

  testWidgets('a dispute-refunded stage can still be funded again', (
    tester,
  ) async {
    // A refund ruling returns the stage to `pending` and re-locks the money,
    // so the owner must still get the legacy Fund step back.
    await open(tester, owner: true, stageStatus: MilestoneStatus.pending);
    expect(
      find.widgetWithText(FilledButton, 'Fund ${formatRm(15000)}'),
      findsOneWidget,
    );
  });

  testWidgets('provider is not asked to propose when no stage has loaded', (
    tester,
  ) async {
    await open(tester, owner: false, withMilestone: false);
    expect(find.text('Propose milestones'), findsNothing);
  });

  testWidgets('a legacy job with no stages still asks for a plan', (
    tester,
  ) async {
    await open(tester, owner: false, funded: false, withMilestone: false);
    expect(
      find.widgetWithText(FilledButton, 'Propose milestones'),
      findsOneWidget,
    );
  });

  test('Job.fromMap reads fundedAtAward and defaults it to false', () {
    final base = {'requestorId': 'u', 'title': 't'};
    expect(Job.fromMap('a', base).fundedAtAward, isFalse);
    expect(
      Job.fromMap('a', {...base, 'fundedAtAward': true}).fundedAtAward,
      isTrue,
    );
  });
}
