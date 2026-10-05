// The provider's bid button turns into an edit action once they have bid.
// Reuses the fakes/helpers from widget_test.dart.
import 'package:fairbid/core/theme/app_theme.dart';
import 'package:fairbid/features/auth/domain/app_user.dart';
import 'package:fairbid/features/auth/domain/user_role.dart';
import 'package:fairbid/features/jobs/domain/bid.dart';
import 'package:fairbid/features/jobs/domain/bundle_bid.dart';
import 'package:fairbid/features/jobs/domain/job.dart';
import 'package:fairbid/features/jobs/presentation/bid/submit_bid_sheet.dart';
import 'package:fairbid/features/jobs/presentation/bundle/bundle_provider_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'widget_test.dart';

BundleBid _bundleBid(Map<String, int> prices, {BundleBidStatus? status}) =>
    BundleBid(
      bundleId: 'b1',
      providerId: 'uid-1',
      providerName: 'New User',
      taskPrices: prices,
      estimatedDuration: '1 week',
      status: status ?? BundleBidStatus.pending,
    );

/// Signs up a verified provider and opens the first job on the feed.
Future<void> _openJob(
  WidgetTester tester, {
  required Job job,
  List<Bid> bids = const [],
  FakeBundleBidRepository? bundleBid,
}) async {
  await tester.binding.setSurfaceSize(const Size(500, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final auth = FakeAuthRepository()
    ..verificationStatus = 'approved'
    ..baseLat = 3.139
    ..baseLng = 101.6869;
  await tester.pumpWidget(
    buildApp(auth, jobs: [job], bids: bids, bundleBid: bundleBid),
  );
  await tester.pumpAndSettle();
  await openRegisterAs(tester, 'Work');
  await tester.tap(find.text('Fix leaking sink').first);
  await tester.pumpAndSettle();
}

void main() {
  group('Ordinary job', () {
    testWidgets('before a bid the bar says Submit a bid', (tester) async {
      await _openJob(tester, job: sampleJob(requestorId: 'req-9'));

      expect(find.widgetWithText(FilledButton, 'Submit a bid'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Edit bid'), findsNothing);
    });

    testWidgets('after a bid it says Edit bid and updates the bid', (
      tester,
    ) async {
      await _openJob(
        tester,
        job: sampleJob(requestorId: 'req-9'),
        bids: [sampleBid(providerId: 'uid-1', amountSen: 15000)],
      );

      expect(find.widgetWithText(FilledButton, 'Submit a bid'), findsNothing);
      await tester.tap(find.widgetWithText(FilledButton, 'Edit bid'));
      await tester.pumpAndSettle();

      // The sheet is prefilled with the existing bid.
      expect(find.text('Edit your bid'), findsOneWidget);
      expect(find.text('150.00'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(SubmitBidSheet),
          matching: find.text('Less than 1 week'),
        ),
        findsOneWidget,
      );
      expect(
        find.text('I can fix this quickly with quality parts.'),
        findsOneWidget,
      );

      await fillField(tester, 'Your bid (RM)', '200');
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Update bid'));
      await tester.pumpAndSettle();

      expect(find.byType(SubmitBidSheet), findsNothing);
      expect(find.text('Bid updated!'), findsOneWidget);
      expect(find.text('RM 200.00'), findsOneWidget);
    });
  });

  testWidgets('bundle task: a pending bundle bid on another task says Edit '
      'bundle bid', (tester) async {
    await _openJob(
      tester,
      job: sampleJob(
        requestorId: 'req-9',
        bundleId: 'b1',
        bundleOrder: 0,
        bundleTaskCount: 2,
      ),
      bundleBid: FakeBundleBidRepository([
        _bundleBid(const {'job-2': 20000}),
      ]),
    );

    expect(find.widgetWithText(FilledButton, 'Edit bundle bid'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Bid on this bundle'), findsNothing);
    expect(
      find.text(
        "Your bundle bid doesn't include this task yet. "
        'Edit it to add this task.',
      ),
      findsOneWidget,
    );
  });

  group('Bundle provider view', () {
    Future<void> pump(WidgetTester tester, BundleBid? bid) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: BundleProviderView(
            bundle: sampleBundle(id: 'b1'),
            tasks: Stream.value([sampleJob()]),
            myBid: Stream.value(bid),
            me: const AppUser(
              uid: 'uid-1',
              email: 'a@b.com',
              displayName: 'New User',
              role: UserRole.provider,
              verificationStatus: 'approved',
            ),
            onOpenTask: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a pending bid says Edit bundle bid', (tester) async {
      await pump(tester, _bundleBid(const {'job-1': 10000}));
      expect(find.text('Edit bundle bid'), findsOneWidget);
    });

    testWidgets('no bid says Bid on this bundle', (tester) async {
      await pump(tester, null);
      expect(find.text('Bid on this bundle'), findsOneWidget);
    });

    testWidgets('a closed bid does not count as mine', (tester) async {
      await pump(
        tester,
        _bundleBid(const {'job-1': 10000}, status: BundleBidStatus.closed),
      );
      expect(find.text('Bid on this bundle'), findsOneWidget);
    });
  });
}
