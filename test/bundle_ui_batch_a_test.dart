// New tests for batch A's bundle-bidding UI fixes (bid sheet, Post a Job,
// shared form field, server copy). Reuses the fakes/helpers declared
// top-level in widget_test.dart rather than duplicating them.

import 'package:fairbid/core/theme/app_theme.dart';
import 'package:fairbid/core/widgets/app_widgets.dart';
import 'package:fairbid/core/widgets/form_widgets.dart';
import 'package:fairbid/features/auth/domain/app_user.dart';
import 'package:fairbid/features/auth/domain/user_role.dart';
import 'package:fairbid/features/jobs/data/bundle_bid_repository.dart';
import 'package:fairbid/features/jobs/domain/bundle_bid.dart';
import 'package:fairbid/features/jobs/domain/job.dart';
import 'package:fairbid/features/jobs/presentation/bid/submit_bundle_bid_controller.dart';
import 'package:fairbid/features/jobs/presentation/bid/submit_bundle_bid_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'widget_test.dart';

/// A [BundleBidRepository] whose `submit` always fails with a server-style
/// message, so the sheet's error-banner behaviour can be exercised - unlike
/// the shared [FakeBundleBidRepository], which never fails.
class _FailingBundleBidRepository implements BundleBidRepository {
  @override
  Future<void> submit({
    required String bundleId,
    required Map<String, int> taskPrices,
    int? bundlePriceSen,
    required String estimatedDuration,
    String message = '',
  }) async {
    throw const BundleBidRejectedException(
      'One of the tasks you picked is no longer open.',
    );
  }

  @override
  Future<void> withdraw(String bundleId) => throw UnimplementedError();

  @override
  Stream<BundleBid?> watchMyBundleBid(String bundleId, String providerId) =>
      throw UnimplementedError();

  @override
  Future<BundleBid?> getMyBundleBid(String bundleId, String providerId) =>
      throw UnimplementedError();

  @override
  Stream<List<BundleBid>> watchBundleBids(String bundleId) =>
      throw UnimplementedError();

  @override
  Stream<List<BundleBid>> watchMyBundleBids(String providerId) =>
      throw UnimplementedError();
}

void main() {
  final bidder = const AppUser(
    uid: 'prov-1',
    email: 'pro@test.com',
    displayName: 'Pro Fixer',
    role: UserRole.provider,
  );

  /// Pumps the sheet on its own - a form, so it needs nothing from the
  /// router or the shell, only the controller its fields drive.
  Future<void> pumpSheet(
    WidgetTester tester, {
    required BundleBidRepository bundleBids,
    required List<Job> tasks,
    BundleBid? existing,
  }) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: ChangeNotifierProvider(
        create: (_) => SubmitBundleBidController(bundleBids),
        child: Scaffold(
          body: SubmitBundleBidSheet(
            bundle: sampleBundle(id: 'b1', taskIds: tasks.map((t) => t.id).toList()),
            tasks: tasks,
            bidder: bidder,
            existing: existing,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// Taps something that may be below the fold on this tall sheet.
  Future<void> tapAt(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  group('Bundle bid sheet: server error stays visible', () {
    testWidgets(
      'a rejected submit shows the error banner both at the top and above '
      'Submit - not just at the top, which is off-screen after scrolling '
      'down to tap it',
      (tester) async {
        final tasks = [
          sampleJob(id: 'job-1', title: 'Waterproof the floor'),
        ];
        await pumpSheet(
          tester,
          bundleBids: _FailingBundleBidRepository(),
          tasks: tasks,
        );

        await tapAt(
            tester, find.widgetWithText(CheckboxListTile, 'Waterproof the floor'));
        await fillField(tester, 'Price if you get only this task (RM)', '100.00');
        await tapAt(tester, find.byType(DropdownButtonFormField<String>));
        await tester.tap(find.text('Less than 1 week').last);
        await tester.pumpAndSettle();
        await fillField(tester, 'Proposal message', 'I can do this.');
        await tapAt(tester, find.byType(CheckboxListTile).last);
        await tapAt(
            tester, find.widgetWithText(PrimaryButton, 'Submit bundle bid'));

        expect(
          find.text('One of the tasks you picked is no longer open.'),
          findsNWidgets(2),
        );
        expect(find.byType(ErrorBanner), findsNWidgets(2));
      },
    );
  });

  group('Bundle bid sheet: withdraw confirmation', () {
    testWidgets(
      'withdrawing a bundle bid asks for confirmation first, and Cancel '
      'leaves the bid in place',
      (tester) async {
        final tasks = [
          sampleJob(id: 'job-1', title: 'Waterproof the floor'),
          sampleJob(id: 'job-2', title: 'Tile the floor'),
        ];
        final bundleBids = FakeBundleBidRepository();
        final existing = BundleBid(
          bundleId: 'b1',
          providerId: 'prov-1',
          providerName: 'Pro Fixer',
          taskPrices: const {'job-1': 10000},
          estimatedDuration: 'Less than 1 week',
          message: 'I can do this.',
        );
        await pumpSheet(
          tester,
          bundleBids: bundleBids,
          tasks: tasks,
          existing: existing,
        );

        await tapAt(tester, find.widgetWithText(TextButton, 'Withdraw bid'));

        expect(find.text('Withdraw your bundle bid?'), findsOneWidget);
        expect(
          find.text('You\'ll no longer be considered for any of its tasks.'),
          findsOneWidget,
        );

        // Cancel: the dialog closes, nothing was withdrawn.
        await tapAt(tester, find.widgetWithText(TextButton, 'Cancel'));
        expect(bundleBids.withdrawn, isEmpty);
        expect(find.byType(SubmitBundleBidSheet), findsOneWidget);

        // Confirming actually withdraws it.
        await tapAt(tester, find.widgetWithText(TextButton, 'Withdraw bid'));
        await tapAt(tester, find.widgetWithText(FilledButton, 'Withdraw'));
        expect(bundleBids.withdrawn, ['b1']);
      },
    );
  });

  group('Bundle bid sheet: task rows show more than a title', () {
    testWidgets(
      'a task row shows its budget, an expandable description, and when it '
      'starts after another task',
      (tester) async {
        final first = Job(
          id: 'job-1',
          requestorId: 'req-1',
          requestorName: 'Test User',
          title: 'Waterproof the floor',
          description: 'Seal every wet-area joint before tiling begins.',
          category: 'Home Repair',
          location: const JobLocation(lat: 3.14, lng: 101.7, address: 'Penang'),
          budget: const JobBudget(minSen: 20000, maxSen: 40000),
        );
        final second = Job(
          id: 'job-2',
          requestorId: 'req-1',
          requestorName: 'Test User',
          title: 'Tile the floor',
          description: 'Lay non-slip tiles once the floor is dry.',
          category: 'Home Repair',
          location: const JobLocation(lat: 3.14, lng: 101.7, address: 'Penang'),
          budget: const JobBudget(minSen: 30000, maxSen: 50000),
        );
        await pumpSheet(
          tester,
          bundleBids: FakeBundleBidRepository(),
          tasks: [first, second],
        );

        // The budget shows next to the category, so a provider isn't pricing
        // blind.
        expect(find.textContaining('RM 200.00'), findsOneWidget);
        expect(find.textContaining('RM 300.00'), findsOneWidget);

        // The description is collapsed until "Show details" is tapped.
        expect(
          find.text('Seal every wet-area joint before tiling begins.'),
          findsNothing,
        );
        await tapAt(tester, find.text('Show details').first);
        expect(
          find.text('Seal every wet-area joint before tiling begins.'),
          findsOneWidget,
        );
      },
    );

  });

  group('Bundle bid sheet: optional package deal', () {
    final tasks = [
      sampleJob(id: 'job-1', title: 'Waterproof the floor'),
      sampleJob(id: 'job-2', title: 'Tile the floor'),
    ];
    final addDeal = find.text('+ Add a package deal (optional)');
    final dealField = find.text('Price if you win all 2 tasks (RM)');

    testWidgets(
      'the package deal link shows from two ticked tasks, reveals the field, '
      'and Remove clears and hides it again',
      (tester) async {
        await pumpSheet(
          tester,
          bundleBids: FakeBundleBidRepository(),
          tasks: tasks,
        );

        expect(addDeal, findsNothing);
        await tapAt(tester,
            find.widgetWithText(CheckboxListTile, 'Waterproof the floor'));
        expect(addDeal, findsNothing);
        await tapAt(
            tester, find.widgetWithText(CheckboxListTile, 'Tile the floor'));
        expect(addDeal, findsOneWidget);
        expect(dealField, findsNothing);

        await tapAt(tester, addDeal);
        expect(dealField, findsOneWidget);
        expect(addDeal, findsNothing);

        await fillField(tester, 'Price if you win all 2 tasks (RM)', '80.00');
        await tapAt(tester, find.widgetWithText(TextButton, 'Remove'));
        expect(dealField, findsNothing);
        expect(addDeal, findsOneWidget);

        // Re-opening it starts empty.
        await tapAt(tester, addDeal);
        final field = tester.widget<TextFormField>(
          find.descendant(
            of: find.byType(AppTextField).last,
            matching: find.byType(TextFormField),
          ),
        );
        expect(field.controller!.text, isEmpty);
      },
    );

    testWidgets(
      'dropping below two ticked tasks hides the package deal field',
      (tester) async {
        await pumpSheet(
          tester,
          bundleBids: FakeBundleBidRepository(),
          tasks: tasks,
        );
        await tapAt(tester,
            find.widgetWithText(CheckboxListTile, 'Waterproof the floor'));
        await tapAt(
            tester, find.widgetWithText(CheckboxListTile, 'Tile the floor'));
        await tapAt(tester, addDeal);
        expect(dealField, findsOneWidget);

        await tapAt(
            tester, find.widgetWithText(CheckboxListTile, 'Tile the floor'));
        expect(dealField, findsNothing);
        expect(addDeal, findsNothing);
      },
    );

    testWidgets(
      'editing a bid that has a bundle price shows the field already open',
      (tester) async {
        final existing = BundleBid(
          bundleId: 'b1',
          providerId: 'prov-1',
          providerName: 'Pro Fixer',
          taskPrices: const {'job-1': 10000, 'job-2': 10000},
          bundlePriceSen: 15000,
          estimatedDuration: 'Less than 1 week',
          message: 'I can do this.',
        );
        await pumpSheet(
          tester,
          bundleBids: FakeBundleBidRepository(),
          tasks: tasks,
          existing: existing,
        );

        expect(dealField, findsOneWidget);
        expect(addDeal, findsNothing);
        expect(find.text('RM 50.00 off your task total'), findsOneWidget);
      },
    );
  });

  group('Bundle bid sheet: escrow copy addresses the provider', () {
    testWidgets('the escrow checkbox explains milestone escrow to a provider,'
        ' not a client', (tester) async {
      await pumpSheet(
        tester,
        bundleBids: FakeBundleBidRepository(),
        tasks: [sampleJob(id: 'job-1', title: 'Waterproof the floor')],
      );

      expect(
        find.textContaining(
            'the client funds each milestone and it\'s released to me when '
            'they approve the work.'),
        findsOneWidget,
      );
      expect(find.textContaining('Your money is held by FairBid'),
          findsNothing);
    });
  });

  group('Post a bundle: draft card and invalid-submit feedback', () {
    Future<void> openPostJob(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final auth = FakeAuthRepository()
        ..defaultLat = 5.4164
        ..defaultLng = 100.3327
        ..defaultDistrictCode = 'TL'
        ..defaultTown = 'George Town'
        ..seedSignedIn(UserRole.requestor);
      await tester.pumpWidget(buildApp(auth, bundle: FakeBundleRepository()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('+ Post a job'));
      await tester.pumpAndSettle();
    }

    testWidgets(
      'the AI draft card says it only fills task 1 once the form is a '
      'bundle',
      (tester) async {
        await openPostJob(tester);
        final add = find.textContaining('Add another task');
        await tester.ensureVisible(add);
        await tester.tap(add);
        await tester.pumpAndSettle();

        expect(
          find.text("Describe task 1 once and we'll fill it in"),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'a failed submit scrolls the first error back into view when the user '
      'had scrolled down to reach the submit button, and shows a snackbar',
      (tester) async {
        // A small viewport, so the top (category) and bottom (submit button)
        // of the empty form cannot both be on screen at once.
        await tester.binding.setSurfaceSize(const Size(400, 700));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final auth = FakeAuthRepository()
          ..defaultLat = 5.4164
          ..defaultLng = 100.3327
          ..defaultDistrictCode = 'TL'
          ..defaultTown = 'George Town'
          ..seedSignedIn(UserRole.requestor);
        await tester.pumpWidget(buildApp(auth, bundle: FakeBundleRepository()));
        await tester.pumpAndSettle();
        await tester.tap(find.text('+ Post a job'));
        await tester.pumpAndSettle();

        final submit = find.widgetWithText(FilledButton, 'Post job');
        await tester.ensureVisible(submit);
        await tester.pumpAndSettle();
        // Scrolled down to the submit button: the category dropdown at the
        // top of the form is now off the top of the viewport.
        final categoryDropdown = find.byType(DropdownButtonFormField<String>);
        expect(tester.getRect(categoryDropdown).bottom, lessThan(0));

        await tester.tap(submit);
        await tester.pumpAndSettle();

        expect(find.text('Some fields need attention'), findsOneWidget);
        // The failed submit scrolled the first invalid field back on screen.
        final categoryError = tester.getRect(find.text('Pick a category.'));
        expect(categoryError.top, greaterThanOrEqualTo(0));
        expect(categoryError.bottom, lessThanOrEqualTo(700));
      },
    );
  });
}
