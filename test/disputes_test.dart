import 'package:fairbid/features/auth/domain/user_role.dart';
import 'package:fairbid/features/disputes/domain/dispute.dart';
import 'package:fairbid/features/jobs/domain/job.dart';
import 'package:fairbid/features/jobs/domain/milestone.dart';
import 'package:fairbid/features/wallet/domain/ledger_entry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/builders.dart';
import 'helpers/fakes.dart';
import 'helpers/harness.dart';

void main() {
  group('Disputes', () {
    test('Dispute builds from a Firestore-shaped map', () {
      final dispute = Dispute.fromMap('d1', {
        'jobId': 'job-1',
        'jobTitle': 'Fix leaking sink',
        'milestoneId': 'ms-1',
        'milestoneDescription': 'Full repair',
        'amountSen': 15000,
        'raisedByUid': 'prov-1',
        'raisedByRole': 'provider',
        'requestorId': 'uid-1',
        'providerId': 'prov-1',
        'statement': 'Payment not released after delivery.',
        'evidenceUrls': ['https://x/1.jpg'],
        'status': 'open',
        'resolution': null,
      });
      expect(dispute.raisedByLabel, 'Provider');
      expect(dispute.conversationId, 'job-1_prov-1');
      expect(dispute.status, DisputeStatus.open);
      expect(dispute.evidenceUrls, hasLength(1));
    });

    test('ledger types parse from storage', () {
      for (final (stored, type) in [
        ('dispute_release', LedgerType.disputeRelease),
        ('dispute_refund', LedgerType.disputeRefund),
        ('refund', LedgerType.refund),
      ]) {
        expect(LedgerType.fromStorage(stored), type, reason: stored);
      }
      expect(LedgerType.refund.label, 'Escrow refund');
    });

    Dispute sampleDispute({String id = 'disp-1'}) => Dispute(
      id: id,
      jobId: 'job-1',
      jobTitle: 'Fix leaking sink',
      milestoneId: 'ms-1',
      milestoneDescription: 'Full repair',
      amountSen: 15000,
      raisedByRole: 'requestor',
      providerId: 'prov-1',
      statement: 'The pipe still leaks after the repair.',
      createdAt: DateTime.now(),
    );

    testWidgets('requestor raises a dispute on a funded milestone', (
      tester,
    ) async {

      final dispute = FakeDisputeRepository();
      final job = sampleJob(
        status: JobStatus.inProgress,
        acceptedProviderId: 'prov-1',
        acceptedProviderName: 'Pro Fixer',
        acceptedBidAmountSen: 15000,
      );
      final milestone = Milestone(
        id: 'ms-1',
        jobId: 'job-1',
        providerId: 'prov-1',
        description: 'Full repair',
        amountSen: 15000,
        status: MilestoneStatus.funded,
        createdAt: DateTime.now(),
      );
      await pumpApp(tester, buildApp(
          FakeAuthRepository(),
          jobs: [job],
          milestones: [milestone],
          dispute: dispute,
        ), size: const Size(500, 1600));
      await logIn(tester);

      // Open own job → the funded (current) milestone step offers the
      // "Raise a dispute" button.
      await tester.tap(find.text('Fix leaking sink').first);
      await tester.pumpAndSettle();
      final disputeBtn = find.widgetWithText(OutlinedButton, 'Raise a dispute');
      await tester.ensureVisible(disputeBtn);
      await tester.tap(disputeBtn);
      await tester.pumpAndSettle();
      expect(find.text('Raise a Dispute'), findsOneWidget);

      // Empty statement is rejected.
      await tester.tap(find.widgetWithText(FilledButton, 'Submit Dispute'));
      await tester.pumpAndSettle();
      expect(find.text('Describe the issue.'), findsOneWidget);

      // Statement in → submitted; milestone freezes to Disputed.
      await fillField(
        tester,
        'What went wrong?',
        'The pipe still leaks after repair.',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Submit Dispute'));
      await tester.pumpAndSettle();

      expect(dispute.raised, hasLength(1));
      expect(dispute.raised.single.milestoneId, 'ms-1');
      expect(find.text('Disputed, on hold'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Raise a dispute'), findsNothing);

      // The person who raised it can take it back.
      final withdrawBtn = find.text('Withdraw dispute');
      await tester.ensureVisible(withdrawBtn);
      await tester.tap(withdrawBtn);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Withdraw'));
      await tester.pumpAndSettle();

      expect(dispute.withdrawn, ['ms-1']);
      expect(find.text('Disputed, on hold'), findsNothing);
      expect(find.text('Withdraw dispute'), findsNothing);
    });

    testWidgets('admin rules a dispute from the Disputes tab', (tester) async {

      final dispute = FakeDisputeRepository([sampleDispute()]);
      final auth = FakeAuthRepository()..seedSignedIn(UserRole.admin);
      await pumpApp(tester, buildApp(auth, dispute: dispute), size: const Size(500, 1600));

      // Admin home opens on Verifications; switch to the Disputes tab.
      await tester.tap(find.text('Disputes'));
      await tester.pumpAndSettle();
      expect(find.text('Disputes Resolution'), findsOneWidget);
      expect(find.text('Fix leaking sink'), findsOneWidget);

      // Open the dispute → statement and both rulings are shown.
      await tester.tap(find.text('Fix leaking sink'));
      await tester.pumpAndSettle();
      expect(find.text('Dispute Review'), findsOneWidget);
      expect(
        find.text('The pipe still leaks after the repair.'),
        findsOneWidget,
      );

      // Release → the ruling note is required before confirming.
      await tester.tap(find.text('Pay the provider RM 150.00'));
      await tester.pumpAndSettle();
      final confirm = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, 'Pay provider'),
      );
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      await tester.enterText(
        find.byType(TextField).last,
        'Work matches the milestone scope.',
      );
      await tester.pumpAndSettle();
      await tester.tap(confirm);
      await tester.pumpAndSettle();

      // Ruling recorded; the queue is empty again.
      expect(dispute.resolutions['disp-1'], DisputeResolution.release);
      expect(dispute.lastRulingNote, 'Work matches the milestone scope.');
      expect(find.text('No open disputes'), findsOneWidget);
    });
  });
}
