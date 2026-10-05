// After a mutual price change keeps the funded milestones, the provider must
// be able to plan the unplanned remainder and nobody sees a false "plan
// agreed" / "complete" state.
import 'package:fairbid/core/util/money.dart';
import 'package:fairbid/core/widgets/app_widgets.dart';
import 'package:fairbid/features/auth/domain/user_role.dart';
import 'package:fairbid/features/jobs/data/milestone_repository.dart';
import 'package:fairbid/features/jobs/domain/job.dart';
import 'package:fairbid/features/jobs/domain/milestone.dart';
import 'package:fairbid/features/jobs/presentation/detail/propose_milestones_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'widget_test.dart';

Job _job({required bool owner, int price = 15000}) => Job(
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
  acceptedBidAmountSen: price,
);

Milestone _ms(MilestoneStatus status, {required bool owner, int sen = 4000}) =>
    Milestone(
      id: 'm0',
      jobId: 'job-1',
      providerId: owner ? 'prov-1' : 'uid-1',
      description: 'Demolition',
      amountSen: sen,
      order: 0,
      status: status,
      createdAt: DateTime.now(),
    );

class _RecordingRepo extends FakeMilestoneRepository {
  _RecordingRepo(super.jobs);
  List<Milestone>? sent;

  @override
  Future<void> proposeMilestones(String jobId, List<Milestone> m) async {
    sent = m;
  }
}

void main() {
  Future<void> open(
    WidgetTester tester, {
    required bool owner,
    required Milestone milestone,
    int price = 15000,
  }) async {
    tester.view.physicalSize = const Size(360, 1400) * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final onError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (!details.exceptionAsString().contains('overflowed')) {
        onError?.call(details);
      }
    };
    addTearDown(() => FlutterError.onError = onError);
    final auth = FakeAuthRepository()
      ..verificationStatus = 'approved'
      ..seedSignedIn(owner ? UserRole.requestor : UserRole.provider);
    final jobs = FakeJobRepository([_job(owner: owner, price: price)]);
    await tester.pumpWidget(
      buildApp(
        auth,
        jobRepository: jobs,
        milestoneRepository: FakeMilestoneRepository(jobs, [milestone]),
      ),
    );
    await tester.pumpAndSettle();
    GoRouter.of(
      tester.element(find.byType(Scaffold).first),
    ).push<void>('/jobs/job-1');
    await tester.pumpAndSettle();
  }

  final remaining = formatRm(11000);

  testWidgets('provider can plan the remainder after a price change', (
    tester,
  ) async {
    await open(
      tester,
      owner: false,
      milestone: _ms(MilestoneStatus.funded, owner: false),
    );
    expect(find.textContaining('The agreed price changed to'), findsOneWidget);
    final button = find.widgetWithText(
      SecondaryButton,
      'Plan remaining $remaining',
    );
    expect(button, findsOneWidget);
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.byType(ProposeMilestonesSheet), findsOneWidget);
  });

  testWidgets('requestor sees the waiting text and job is not complete', (
    tester,
  ) async {
    await open(
      tester,
      owner: true,
      milestone: _ms(MilestoneStatus.funded, owner: true),
    );
    expect(
      find.text(
        'Waiting for the provider to plan the remaining $remaining of the '
        'new price.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Plan agreed'), findsNothing);
  });

  testWidgets('fully planned released milestone is unchanged', (tester) async {
    await open(
      tester,
      owner: true,
      milestone: _ms(MilestoneStatus.released, owner: true),
      price: 4000,
    );
    expect(
      find.textContaining('Waiting for the provider to plan'),
      findsNothing,
    );
    expect(find.textContaining('Plan agreed'), findsOneWidget);
  });

  testWidgets('sheet keeps locked rows read-only and resends them first', (
    tester,
  ) async {
    final jobs = FakeJobRepository([_job(owner: false)]);
    final repo = _RecordingRepo(jobs);
    await tester.pumpWidget(
      MaterialApp(
        home: Provider<MilestoneRepository>.value(
          value: repo,
          child: Scaffold(
            body: ProposeMilestonesSheet(
              job: _job(owner: false),
              existing: [_ms(MilestoneStatus.funded, owner: false)],
            ),
          ),
        ),
      ),
    );
    final fields = tester
        .widgetList<TextField>(find.byType(TextField))
        .toList();
    expect(fields.length, 2);
    expect(fields.every((f) => f.enabled == false), isTrue);
    expect(find.byIcon(Icons.close), findsNothing);

    await tester.tap(find.text('Add milestone'));
    await tester.pump();
    await tester.enterText(find.byType(TextField).at(2), 'Tiling');
    await tester.enterText(find.byType(TextField).at(3), '110');
    await tester.tap(find.text('Submit changes'));
    await tester.pumpAndSettle();

    final sent = repo.sent!;
    expect(sent.length, 2);
    expect(sent[0].order, 0);
    expect(sent[0].description, 'Demolition');
    expect(sent[0].amountSen, 4000);
    expect(sent[1].order, 1);
    expect(sent[1].description, 'Tiling');
    expect(sent[1].amountSen, 11000);
  });
}
