// A job is funded at award with one funded "Full job" stage, so nobody is
// ever asked to fund it.
import 'package:fairbid/core/util/money.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/builders.dart';
import 'helpers/harness.dart';

void main() {
  Future<void> open(WidgetTester tester, {required bool owner}) => pumpJobDetail(
    tester,
    testJob(owner: owner, description: 'The kitchen sink leaks.'),
    owner: owner,
    milestones: [sampleMilestone(id: 'm0', owner: owner, description: 'Full job')],
    height: 1200,
  );

  testWidgets('provider sees Mark as delivered with the money secured', (tester) async {
    await open(tester, owner: false);
    expect(
      find.widgetWithText(FilledButton, 'Mark as delivered'),
      findsOneWidget,
    );
    expect(find.textContaining('${formatRm(15000)} secured in escrow'), findsOneWidget);
  });

  testWidgets('owner waits on delivery and is never asked to fund', (
    tester,
  ) async {
    await open(tester, owner: true);
    expect(
      find.textContaining('${formatRm(15000)} is secured in escrow. Waiting for'),
      findsOneWidget,
    );
  });
}
