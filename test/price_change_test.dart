// Mutual price change: overflow-menu entry, response card and price label on
// the job detail screen.
import 'package:fairbid/core/util/money.dart';
import 'package:fairbid/features/jobs/domain/price_change_request.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/builders.dart';
import 'helpers/harness.dart';

void main() {
  Future<void> openMenu(WidgetTester tester) async {
    final button = find.text('Problem with this job?');
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  /// Whether the "Change the price" option can be tapped.
  bool priceChangeEnabled(WidgetTester tester) => tester
      .widget<ListTile>(find.widgetWithText(ListTile, 'Change the price'))
      .enabled;

  group('problem sheet', () {
    for (final owner in [true, false]) {
      testWidgets(
        'offers Change the price to the ${owner ? 'requestor' : 'provider'}',
        (tester) async {
          await pumpJobDetail(tester, testJob(owner: owner), owner: owner);
          await openMenu(tester);
          expect(priceChangeEnabled(tester), isTrue);
        },
      );
    }

    testWidgets('explains it is off for a bundle task', (tester) async {
      await pumpJobDetail(tester, testJob(owner: true, bundleId: 'b1'), owner: true);
      await openMenu(tester);
      expect(priceChangeEnabled(tester), isFalse);
      expect(find.text('Not available for bundle tasks.'), findsOneWidget);
    });

    testWidgets('explains it is off after 3 accepted changes', (tester) async {
      await pumpJobDetail(tester, testJob(owner: true, priceChangeCount: 3), owner: true);
      await openMenu(tester);
      expect(priceChangeEnabled(tester), isFalse);
      expect(find.text('The price has already been changed 3 times.'),
          findsOneWidget);
    });
  });

  group('pending request', () {
    const request = PriceChangeRequest(
      by: 'provider',
      newAmountSen: 20000,
      reason: 'Extra pipework needed',
    );

    testWidgets('responder can accept and decline', (tester) async {
      final jobs = await pumpJobDetail(tester, testJob(owner: true, priceChangeRequest: request), owner: true);
      expect(find.text('Extra pipework needed'), findsNothing);
      expect(find.text('"Extra pipework needed"'), findsOneWidget);
      expect(
        find.text('A price change request needs your response.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Decline'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Accept'));
      await tester.pumpAndSettle();
      expect(jobs.priceChangeCalls, ['decline:job-1', 'accept:job-1']);
    });

    testWidgets('requester sees Withdraw and can use it', (tester) async {
      final jobs = await pumpJobDetail(tester, testJob(owner: false, priceChangeRequest: request), owner: false);
      expect(find.text('Waiting for the other party'), findsOneWidget);
      expect(find.text('Accept'), findsNothing);
      await tester.tap(find.text('Withdraw'));
      await tester.pumpAndSettle();
      expect(jobs.priceChangeCalls, ['withdraw:job-1']);
    });

    testWidgets('Change the price is off while a request is pending', (
      tester,
    ) async {
      await pumpJobDetail(tester, testJob(owner: false, priceChangeRequest: request), owner: false);
      await openMenu(tester);
      expect(priceChangeEnabled(tester), isFalse);
      expect(find.text('A price change is already waiting for an answer.'),
          findsOneWidget);
    });
  });

  testWidgets('shows the agreed price with the original once changed', (
    tester,
  ) async {
    await pumpJobDetail(tester, testJob(owner: true, originalBidAmountSen: 10000, priceChangeCount: 1), owner: true);
    expect(
      find.text(
        'Agreed price: ${formatRm(15000)} (was ${formatRm(10000)})',
      ),
      findsOneWidget,
    );
  });
}
