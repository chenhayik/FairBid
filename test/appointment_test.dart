// Appointment scheduling: the card's states, the delivery gate, confirming a
// proposed time and the propose-times sheet.
import 'package:fairbid/core/util/visit_time.dart';
import 'package:fairbid/core/widgets/app_widgets.dart';
import 'package:fairbid/features/auth/domain/user_role.dart';
import 'package:fairbid/features/jobs/domain/appointment.dart';
import 'package:fairbid/features/jobs/domain/job.dart';
import 'package:fairbid/features/jobs/domain/milestone.dart';
import 'package:fairbid/features/jobs/domain/service_address.dart';
import 'package:fairbid/features/jobs/presentation/detail/appointment_card.dart';
import 'package:fairbid/features/jobs/presentation/detail/propose_time_sheet.dart';
import 'package:fairbid/features/disputes/presentation/raise_dispute_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/builders.dart';
import 'helpers/fakes.dart';
import 'helpers/harness.dart';

final _now = DateTime.now();
DateTime _in(Duration d) => DateTime(_now.year, _now.month, _now.day, 10).add(d);

/// A proposal from the other party (the viewer is `uid-1`).
AppointmentProposal _theirProposal({required bool owner, int options = 2}) =>
    AppointmentProposal(
      options: [for (var i = 0; i < options; i++) _in(Duration(days: 2 + i))],
      by: owner ? 'prov-1' : 'req-9',
      note: 'Bring a ladder',
    );

Appointment _appointment(DateTime start, {DateTime? endAt}) =>
    Appointment(startAt: start, endAt: endAt);

void main() {
  Future<FakeJobRepository> open(
    WidgetTester tester,
    Job job, {
    required bool owner,
    MilestoneStatus? milestone = MilestoneStatus.funded,
    List<Job> extra = const [],
  }) => pumpJobDetail(
    tester,
    job,
    owner: owner,
    milestones: [if (milestone != null) sampleMilestone(status: milestone, owner: owner)],
    extra: extra,
  );

  group('card states', () {
    testWidgets('nothing agreed yet offers Propose a time', (tester) async {
      await open(tester, testJob(schedulingRequired: true, owner: true), owner: true);
      expect(find.text('Agree a visit time'), findsOneWidget);
      expect(
        find.text('Agree a visit time with Pro Fixer.'),
        findsOneWidget,
      );
      expect(find.text('Propose a time'), findsOneWidget);
    });

    testWidgets('the other party sees chips, Confirm and Suggest', (
      tester,
    ) async {
      final proposal = _theirProposal(owner: true);
      await open(
        tester,
        testJob(schedulingRequired: true, owner: true, appointmentProposal: proposal),
        owner: true,
      );
      expect(find.text('Pro Fixer suggested some times'), findsOneWidget);
      for (final option in proposal.options) {
        expect(find.text(formatVisitTime(option)), findsOneWidget);
      }
      expect(find.text('"Bring a ladder"'), findsOneWidget);
      expect(find.text('Confirm'), findsOneWidget);
      expect(find.text('Suggest other times'), findsOneWidget);
      // Nothing is picked yet, so Confirm is off.
      expect(
        tester
            .widget<FilledButton>(
              find.descendant(
                of: find.widgetWithText(PrimaryButton, 'Confirm'),
                matching: find.byType(FilledButton),
              ),
            )
            .onPressed,
        isNull,
      );
    });

    testWidgets('the proposer sees Waiting and can withdraw', (tester) async {
      final jobs = await open(
        tester,
        testJob(schedulingRequired: true, 
          owner: false,
          appointmentProposal: AppointmentProposal(
            options: [_in(const Duration(days: 2))],
            by: 'uid-1',
          ),
        ),
        owner: false,
      );
      expect(find.text('Waiting for Rita Client to confirm'), findsOneWidget);
      await tapAt(tester, find.text('Withdraw'));
      expect(jobs.appointmentCalls, ['withdraw:job-1']);
      expect(find.text('Waiting for Rita Client to confirm'), findsNothing);
      expect(find.text('Agree a visit time'), findsOneWidget);
    });

    testWidgets('confirmed shows the time, finish date and Reschedule', (
      tester,
    ) async {
      final start = _in(const Duration(days: 3));
      final end = _in(const Duration(days: 5));
      await open(
        tester,
        testJob(schedulingRequired: true, owner: true, appointment: _appointment(start, endAt: end)),
        owner: true,
      );
      expect(find.text('Visit confirmed'), findsOneWidget);
      expect(find.text(formatVisitTime(start)), findsOneWidget);
      expect(find.text('Finishes on ${formatVisitDate(end)}'), findsOneWidget);
      expect(find.text('Reschedule'), findsOneWidget);
      expect(find.text('Propose a time'), findsNothing);
    });

    testWidgets('confirmed offers Add to calendar', (tester) async {
      await open(
        tester,
        testJob(schedulingRequired: true, owner: true, appointment: _appointment(_in(const Duration(days: 3)))),
        owner: true,
      );
      expect(find.text('Add to calendar'), findsOneWidget);
    });

    testWidgets('no Add to calendar before a time is confirmed', (tester) async {
      await open(
        tester,
        testJob(schedulingRequired: true, owner: true, appointmentProposal: _theirProposal(owner: true)),
        owner: true,
      );
      expect(find.text('Add to calendar'), findsNothing);
    });

    testWidgets('confirmed also shows a pending reschedule below', (
      tester,
    ) async {
      await open(
        tester,
        testJob(schedulingRequired: true, 
          owner: true,
          appointment: _appointment(_in(const Duration(days: 3))),
          appointmentProposal: _theirProposal(owner: true, options: 1),
        ),
        owner: true,
      );
      expect(find.text('Visit confirmed'), findsOneWidget);
      expect(find.text('Pro Fixer suggested a time'), findsOneWidget);
      expect(find.text('Reschedule'), findsOneWidget);
    });

    testWidgets('a completed job shows a read-only Visited on line', (
      tester,
    ) async {
      final start = _in(const Duration(days: -2));
      await open(
        tester,
        testJob(schedulingRequired: true, 
          owner: true,
          status: JobStatus.completed,
          appointment: _appointment(start),
        ),
        owner: true,
        milestone: MilestoneStatus.released,
      );
      expect(find.text('Visited on ${formatVisitTime(start)}'), findsOneWidget);
      expect(find.text('Reschedule'), findsNothing);
    });
  });

  group('visit day', () {
    DateTime fromNow(Duration d) => DateTime.now().add(d);

    testWidgets('the provider sees On my way inside the 3 hour window', (
      tester,
    ) async {
      final jobs = await open(
        tester,
        testJob(schedulingRequired: true, owner: false, appointment: _appointment(fromNow(const Duration(hours: 2)))),
        owner: false,
      );
      expect(find.text("I've arrived"), findsOneWidget);
      await tapAt(tester, find.text('On my way'));
      expect(find.text('How long until you arrive?'), findsOneWidget);
      await tapAt(tester, find.text('30 min'));
      expect(jobs.appointmentCalls, ['onTheWay:job-1:30']);
      expect(find.textContaining("You're on the way, about 30 min"), findsOneWidget);
      await tapAt(tester, find.text("I've arrived"));
      expect(jobs.appointmentCalls.last, 'arrived:job-1');
      expect(find.textContaining('Arrived at'), findsOneWidget);
      expect(find.text('On my way'), findsNothing);
      expect(find.text("I've arrived"), findsNothing);
    });

    testWidgets('the provider does not see it before the window', (
      tester,
    ) async {
      await open(
        tester,
        testJob(schedulingRequired: true, owner: false, appointment: _appointment(fromNow(const Duration(hours: 5)))),
        owner: false,
      );
      expect(find.text('Visit confirmed'), findsOneWidget);
      expect(find.text('On my way'), findsNothing);
      expect(find.text("I've arrived"), findsNothing);
    });

    testWidgets('the requestor sees the on-the-way line, not the buttons', (
      tester,
    ) async {
      final sent = fromNow(const Duration(minutes: -5));
      await open(
        tester,
        testJob(schedulingRequired: true, 
          owner: true,
          appointment: _appointment(fromNow(const Duration(hours: 1))),
          onTheWayAt: sent,
          etaMinutes: 30,
        ),
        owner: true,
      );
      expect(
        find.text('Pro Fixer is on the way, about 30 min (sent ${formatClock(sent)})'),
        findsOneWidget,
      );
      expect(find.text('On my way'), findsNothing);
    });

    testWidgets('the requestor sees when the provider arrived', (tester) async {
      final arrived = fromNow(const Duration(minutes: -5));
      await open(
        tester,
        testJob(schedulingRequired: true, 
          owner: true,
          appointment: _appointment(fromNow(const Duration(hours: -1))),
          arrivedAt: arrived,
        ),
        owner: true,
      );
      expect(find.text('Arrived at ${formatClock(arrived)}'), findsOneWidget);
    });
  });

  group('no-show option', () {
    Future<void> openSheet(WidgetTester tester) => tapAt(tester, find.text('Problem with this job?'));

    bool enabled(WidgetTester tester) => tester
        .widget<ListTile>(find.widgetWithText(ListTile, "Provider didn't show up"))
        .enabled;

    testWidgets('is enabled 30+ minutes after the start and opens a pre-filled dispute', (
      tester,
    ) async {
      final start = DateTime.now().subtract(const Duration(minutes: 45));
      await open(tester, testJob(schedulingRequired: true, owner: true, appointment: _appointment(start)), owner: true);
      await openSheet(tester);
      expect(enabled(tester), isTrue);
      await tester.tap(find.text("Provider didn't show up"));
      await tester.pumpAndSettle();
      expect(find.byType(RaiseDisputeSheet), findsOneWidget);
      expect(
        find.text("The provider didn't show up for the visit on ${formatVisitTime(start)}."),
        findsOneWidget,
      );
    });

    final ago10m = DateTime.now().subtract(const Duration(minutes: 10));
    final ago2h = DateTime.now().subtract(const Duration(hours: 2));
    for (final (name, job, hint) in [
      (
        'before the 30 minute grace period',
        testJob(schedulingRequired: true, owner: true, appointment: _appointment(ago10m)),
        'Only 30 minutes after the visit time.',
      ),
      (
        'once the provider arrived',
        testJob(
          schedulingRequired: true,
          owner: true,
          appointment: _appointment(ago2h),
          arrivedAt: ago2h,
        ),
        null,
      ),
      (
        'with no confirmed visit',
        testJob(schedulingRequired: true, owner: true),
        'Only once a visit time is confirmed.',
      ),
    ]) {
      testWidgets('is disabled $name', (tester) async {
        await open(tester, job, owner: true);
        await openSheet(tester);
        expect(enabled(tester), isFalse);
        if (hint != null) expect(find.text(hint), findsOneWidget);
      });
    }

    testWidgets('is not offered to the provider', (tester) async {
      final start = DateTime.now().subtract(const Duration(hours: 2));
      await open(tester, testJob(schedulingRequired: true, owner: false, appointment: _appointment(start)), owner: false);
      await openSheet(tester);
      expect(find.text("Provider didn't show up"), findsNothing);
    });
  });

  group('directions', () {
    Future<void> openWithAddress(WidgetTester tester, {required bool owner}) async {
      final jobs = await open(
        tester,
        testJob(schedulingRequired: true, owner: owner, appointment: _appointment(_in(const Duration(days: 3)))),
        owner: owner,
      );
      await jobs.setJobAddress(
        'job-1',
        const ServiceAddress(line1: '1 Jalan Test', postcode: '50000', city: 'KL'),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('the provider sees Google Maps and Waze', (tester) async {
      await openWithAddress(tester, owner: false);
      expect(find.textContaining('1 Jalan Test'), findsOneWidget);
      expect(find.text('Google Maps'), findsOneWidget);
      expect(find.text('Waze'), findsOneWidget);
    });

    testWidgets('the requestor does not', (tester) async {
      await openWithAddress(tester, owner: true);
      expect(find.textContaining('1 Jalan Test'), findsOneWidget);
      expect(find.text('Google Maps'), findsNothing);
      expect(find.text('Waze'), findsNothing);
    });
  });

  group('delivery gate', () {
    testWidgets('the provider must agree a time before delivering', (
      tester,
    ) async {
      await open(tester, testJob(schedulingRequired: true, owner: false), owner: false);
      expect(find.text('Mark as delivered'), findsNothing);
      expect(
        find.widgetWithText(FilledButton, 'Propose a time'),
        findsWidgets,
      );
      expect(
        find.text('Agree a visit time with Rita Client.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Agree a visit time first.'),
        findsOneWidget,
      );
    });

    testWidgets('a confirmed time unlocks Mark as delivered', (tester) async {
      await open(
        tester,
        testJob(schedulingRequired: true, 
          owner: false,
          appointment: _appointment(_in(const Duration(days: -1))),
        ),
        owner: false,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Mark as delivered'));
      await tester.pumpAndSettle();
      expect(find.text('Mark as delivered?'), findsOneWidget);
      expect(find.text('Visit time not reached'), findsNothing);
    });

    testWidgets('delivering before the visit asks first', (tester) async {
      await open(
        tester,
        testJob(schedulingRequired: true, 
          owner: false,
          appointment: _appointment(_in(const Duration(days: 2))),
        ),
        owner: false,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Mark as delivered'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          "The visit time hasn't come yet. Mark as delivered anyway?",
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Mark as delivered?'), findsOneWidget);
    });

    testWidgets('the requestor waits for the provider to propose', (
      tester,
    ) async {
      await open(tester, testJob(schedulingRequired: true, owner: true), owner: true);
      expect(
        find.text('Waiting for Pro Fixer to propose a visit time.'),
        findsOneWidget,
      );
    });
  });

  group('confirming a proposal', () {
    testWidgets('the requestor picks one of two times and confirms', (
      tester,
    ) async {
      final proposal = _theirProposal(owner: true);
      final jobs = await open(
        tester,
        testJob(schedulingRequired: true, owner: true, appointmentProposal: proposal),
        owner: true,
      );
      expect(find.text('Choose a visit time'), findsOneWidget);
      await tapAt(tester, find.text(formatVisitTime(proposal.options[1])));
      await tapAt(tester, find.text('Confirm'));
      expect(jobs.appointmentCalls, ['accept:job-1:1']);
      expect(find.text('Visit confirmed'), findsOneWidget);
      expect(
        find.text(formatVisitTime(proposal.options[1])),
        findsOneWidget,
      );
    });

    testWidgets('a single proposed time is confirmed from the bottom bar', (
      tester,
    ) async {
      final jobs = await open(
        tester,
        testJob(schedulingRequired: true, owner: true, appointmentProposal: _theirProposal(owner: true, options: 1)),
        owner: true,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm visit time'));
      await tester.pumpAndSettle();
      expect(jobs.appointmentCalls, ['accept:job-1:0']);
      expect(find.text('Visit confirmed'), findsOneWidget);
    });

    testWidgets('Suggest other times opens the sheet', (tester) async {
      await open(
        tester,
        testJob(schedulingRequired: true, owner: true, appointmentProposal: _theirProposal(owner: true)),
        owner: true,
      );
      await tapAt(tester, find.text('Suggest other times'));
      expect(find.byType(ProposeTimeSheet), findsOneWidget);
    });
  });

  group('upcoming visits', () {
    Future<void> openHome(WidgetTester tester, List<Job> jobs) async {
      tester.view.physicalSize = const Size(360, 2400) * 2;
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      final auth = FakeAuthRepository()
        ..verificationStatus = 'approved'
        ..seedSignedIn(UserRole.provider);
      await pumpApp(tester, buildApp(auth, jobRepository: FakeJobRepository(jobs)));
    }

    Job visit(String id, String title, Duration from, {JobStatus? status}) =>
        testJob(schedulingRequired: true, 
          owner: false,
          id: id,
          title: title,
          status: status ?? JobStatus.inProgress,
          appointment: _appointment(DateTime.now().add(from)),
        );

    testWidgets('lists visits by start time and flags clashes', (tester) async {
      await openHome(tester, [
        visit('c', 'Visit C', const Duration(days: 3)),
        visit('b', 'Visit B', const Duration(days: 1, hours: 1)),
        visit('a', 'Visit A', const Duration(days: 1)),
        visit('old', 'Visit Old', const Duration(hours: -3)),
        visit('done', 'Visit Done', const Duration(days: 2),
            status: JobStatus.completed),
        testJob(schedulingRequired: true, owner: false, id: 'none', title: 'No time yet'),
      ]);
      expect(find.text('Upcoming visits'), findsOneWidget);
      expect(find.text('Visit Old'), findsNothing);
      expect(find.text('Visit Done'), findsNothing);
      expect(find.text('No time yet'), findsNothing);
      double top(String t) => tester.getTopLeft(find.text(t)).dy;
      expect(top('Visit A'), lessThan(top('Visit B')));
      expect(top('Visit B'), lessThan(top('Visit C')));
      expect(find.text('Bangsar, KL'), findsNWidgets(3));
      // A and B are an hour apart; C is alone.
      expect(find.text('Close to another visit'), findsNWidgets(2));
      await tester.tap(find.text('Visit C'));
      await tester.pumpAndSettle();
      expect(find.byType(AppointmentCard), findsOneWidget);
    });

    testWidgets('a visit that started under 2 hours ago is kept', (tester) async {
      await openHome(tester, [
        visit('a', 'Visit A', const Duration(minutes: -90)),
      ]);
      expect(find.text('Visit A'), findsOneWidget);
      expect(find.text('Close to another visit'), findsNothing);
    });

    testWidgets('the section is hidden with no visits', (tester) async {
      await openHome(tester, [testJob(schedulingRequired: true, owner: false)]);
      expect(find.text('Upcoming visits'), findsNothing);
    });
  });

  group('propose sheet', () {
    final now = DateTime(2026, 10, 7, 12);
    DateTime at(int days, [int hour = 10]) =>
        DateTime(now.year, now.month, now.day + days, hour);

    test('accepts one to three future times', () {
      expect(validateVisitTimes(options: [at(1)], now: now), isNull);
      expect(
        validateVisitTimes(options: [at(1), at(2), at(3)], now: now),
        isNull,
      );
    });

    test('rejects a row with no time picked', () {
      expect(validateVisitTimes(options: [null], now: now), isNotNull);
      expect(validateVisitTimes(options: [at(1), null], now: now), isNotNull);
    });

    test('rejects duplicates, near and far times', () {
      expect(
        validateVisitTimes(options: [at(1), at(1)], now: now),
        'Each time must be different.',
      );
      expect(
        validateVisitTimes(
          options: [now.add(const Duration(minutes: 29))],
          now: now,
        ),
        'Each time must be at least 30 minutes from now.',
      );
      expect(
        validateVisitTimes(
          options: [now.add(const Duration(minutes: 30))],
          now: now,
        ),
        isNull,
      );
      expect(
        validateVisitTimes(options: [at(91)], now: now),
        'Each time must be within the next 90 days.',
      );
    });

    test('checks the finish time against the last visit', () {
      expect(
        validateVisitTimes(options: [at(1), at(3)], endAt: at(2), now: now),
        isNotNull,
      );
      expect(
        validateVisitTimes(options: [at(1), at(3)], endAt: at(5), now: now),
        isNull,
      );
      expect(
        validateVisitTimes(options: [at(1)], endAt: at(95), now: now),
        isNotNull,
      );
    });

    testWidgets('Send with no time picked shows an error', (tester) async {
      final jobs = await open(tester, testJob(schedulingRequired: true, owner: true), owner: true);
      await tapAt(tester, find.text('Propose a time'));
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
      expect(
        find.text('Pick a date and time for each row, or remove the row.'),
        findsOneWidget,
      );
      expect(jobs.appointmentCalls, isEmpty);
    });

    testWidgets('picks a time and sends the proposal', (tester) async {
      final jobs = await open(tester, testJob(schedulingRequired: true, owner: true), owner: true);
      await tapAt(tester, find.text('Propose a time'));
      await tester.tap(find.text('Pick date and time'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.text('Pick date and time'), findsNothing);
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
      expect(jobs.appointmentCalls, ['propose:job-1:1']);
      expect(find.byType(ProposeTimeSheet), findsNothing);
      expect(find.text('Visit confirmed'), findsNothing);
      expect(find.text('Waiting for Pro Fixer to confirm'), findsOneWidget);
    });

    Future<FakeJobRepository> openBundleSheet(WidgetTester tester) async {
      final jobs = await open(
        tester,
        testJob(schedulingRequired: true, owner: true, bundleId: 'b1'),
        owner: true,
        extra: [
          testJob(schedulingRequired: true, owner: true, id: 'job-2', title: 'Paint hall', bundleId: 'b1'),
          testJob(schedulingRequired: true, owner: true, id: 'job-3', title: 'Tile bath', bundleId: 'b1'),
          // Not offered: another provider, a finished task, another bundle.
          testJob(schedulingRequired: true, 
            owner: true,
            id: 'job-4',
            title: 'Wire kitchen',
            bundleId: 'b1',
            providerId: 'prov-2',
          ),
          testJob(schedulingRequired: true, 
            owner: true,
            id: 'job-5',
            title: 'Fix gate',
            bundleId: 'b1',
            status: JobStatus.completed,
          ),
          testJob(schedulingRequired: true, owner: true, id: 'job-6', title: 'Other bundle', bundleId: 'b2'),
        ],
      );
      await tapAt(tester, find.text('Propose a time'));
      return jobs;
    }

    Future<void> pickAndSend(WidgetTester tester) async {
      await tester.tap(find.text('Pick date and time'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
    }

    testWidgets('a multi-task bundle lists sibling tasks, ticked', (
      tester,
    ) async {
      final jobs = await openBundleSheet(tester);
      expect(find.text('Also use these times for:'), findsOneWidget);
      expect(find.byType(CheckboxListTile), findsNWidgets(2));
      expect(find.text('Paint hall'), findsOneWidget);
      expect(find.text('Tile bath'), findsOneWidget);
      expect(find.text('Wire kitchen'), findsNothing);
      await pickAndSend(tester);
      expect(jobs.proposedAlso, [
        ['job-2', 'job-3'],
      ]);
    });

    testWidgets('unticked siblings are left out of the proposal', (tester) async {
      final jobs = await openBundleSheet(tester);
      await tester.tap(find.text('Paint hall'));
      await tester.pumpAndSettle();
      await pickAndSend(tester);
      expect(jobs.proposedAlso, [
        ['job-3'],
      ]);
    });

    testWidgets('a lone bundle task shows no checkboxes', (tester) async {
      await open(tester, testJob(schedulingRequired: true, owner: true, bundleId: 'b1'), owner: true);
      await tapAt(tester, find.text('Propose a time'));
      expect(find.text('Also use these times for:'), findsNothing);
      expect(find.byType(CheckboxListTile), findsNothing);
    });

    testWidgets('a job outside any bundle sends no alsoJobIds', (tester) async {
      final jobs = await open(tester, testJob(schedulingRequired: true, owner: true), owner: true);
      await tapAt(tester, find.text('Propose a time'));
      expect(find.byType(CheckboxListTile), findsNothing);
      await pickAndSend(tester);
      expect(jobs.proposedAlso, [<String>[]]);
    });

    testWidgets('rows can be added up to three and removed', (tester) async {
      await open(tester, testJob(schedulingRequired: true, owner: true), owner: true);
      await tapAt(tester, find.text('Propose a time'));
      await tester.tap(find.text('Add another time'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add another time'));
      await tester.pumpAndSettle();
      expect(find.text('Pick date and time'), findsNWidgets(3));
      expect(find.text('Add another time'), findsNothing);
      await tester.tap(find.byTooltip('Remove this time').first);
      await tester.pumpAndSettle();
      expect(find.text('Pick date and time'), findsNWidgets(2));
    });

    testWidgets('warns when rescheduling under 24 hours before the visit', (
      tester,
    ) async {
      await open(
        tester,
        testJob(schedulingRequired: true, 
          owner: true,
          appointment: _appointment(DateTime.now().add(const Duration(hours: 5))),
        ),
        owner: true,
      );
      await tapAt(tester, find.text('Reschedule'));
      expect(find.text('Reschedule the visit'), findsOneWidget);
      expect(find.text('Short notice'), findsOneWidget);
    });

    testWidgets('no warning when the visit is days away', (tester) async {
      await open(
        tester,
        testJob(schedulingRequired: true, 
          owner: true,
          appointment: _appointment(_in(const Duration(days: 4))),
        ),
        owner: true,
      );
      await tapAt(tester, find.text('Reschedule'));
      expect(find.text('Short notice'), findsNothing);
    });
  });
}
