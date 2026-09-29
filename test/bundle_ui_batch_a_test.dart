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
    bool allOrNothing = false,
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
          startsAfterJobId: 'job-1',
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

        // The dependent task says when it starts.
        expect(
          find.textContaining('Starts after Waterproof the floor'),
          findsOneWidget,
        );

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

    testWidgets(
      'linked tasks say so in plain terms, not "bid together" jargon',
      (tester) async {
        final first = Job(
          id: 'job-1',
          requestorId: 'req-1',
          requestorName: 'Test User',
          title: 'Waterproof the floor',
          description: 'Seal the wet area.',
          category: 'Home Repair',
          location: const JobLocation(lat: 3.14, lng: 101.7, address: 'Penang'),
          lotId: 'wet-area',
        );
        final second = Job(
          id: 'job-2',
          requestorId: 'req-1',
          requestorName: 'Test User',
          title: 'Tile the floor',
          description: 'Lay the tiles.',
          category: 'Home Repair',
          location: const JobLocation(lat: 3.14, lng: 101.7, address: 'Penang'),
          lotId: 'wet-area',
        );
        await pumpSheet(
          tester,
          bundleBids: FakeBundleBidRepository(),
          tasks: [first, second],
        );

        expect(
          find.textContaining(
              'Linked with Tile the floor — linked tasks go to the same '
              'provider.'),
          findsOneWidget,
        );
        expect(find.textContaining('Bid together with'), findsNothing);
      },
    );
  });

  group('Bundle bid sheet: bundle price needs two tasks', () {
    testWidgets(
      'the bundle price and all-or-nothing switch are disabled and cleared '
      'below two ticked tasks, then re-enable once a second is picked',
      (tester) async {
        final tasks = [
          sampleJob(id: 'job-1', title: 'Waterproof the floor'),
          sampleJob(id: 'job-2', title: 'Tile the floor'),
        ];
        await pumpSheet(
          tester,
          bundleBids: FakeBundleBidRepository(),
          tasks: tasks,
        );

        AppTextField bundlePriceField() => tester.widget<AppTextField>(
              find.byWidgetPredicate(
                  (w) => w is AppTextField && w.label == 'Bundle price (RM)'),
            );
        SwitchListTile allOrNothingTile() => tester.widget<SwitchListTile>(
              find.widgetWithText(SwitchListTile, 'All or nothing'),
            );

        expect(bundlePriceField().enabled, isFalse);
        expect(allOrNothingTile().onChanged, isNull);
        expect(find.text('Pick at least two tasks'), findsNWidgets(2));

        await tapAt(
            tester, find.widgetWithText(CheckboxListTile, 'Waterproof the floor'));
        await tapAt(
            tester, find.widgetWithText(CheckboxListTile, 'Tile the floor'));

        expect(bundlePriceField().enabled, isTrue);
        expect(allOrNothingTile().onChanged, isNotNull);
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

  group('Post a bundle: template sheet and invalid-submit feedback', () {
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
      'the template sheet lists each template\'s task titles under its name',
      (tester) async {
        await openPostJob(tester);

        await tester.ensureVisible(find.text('Start from a template'));
        await tester.tap(find.text('Start from a template'));
        await tester.pumpAndSettle();

        expect(
          find.textContaining(
              'Plumbing rough-in · Waterproofing · Tiling · Electrical '
              'fittings'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'picking a template only asks to replace typed content AFTER a '
      "template is picked, not before the sheet even opens",
      (tester) async {
        await openPostJob(tester);
        await fillField(tester, 'Job title', 'My own title');

        await tester.ensureVisible(find.text('Start from a template'));
        await tester.tap(find.text('Start from a template'));
        await tester.pumpAndSettle();

        // The sheet opened straight away - no confirmation blocked it.
        expect(find.text('Replace your tasks with this template?'), findsNothing);
        expect(find.text('Bathroom renovation'), findsOneWidget);

        await tester.tap(find.text('Bathroom renovation'));
        await tester.pumpAndSettle();

        // Only now, because there was content to lose, is it asked.
        expect(
          find.text('Replace your tasks with this template?'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      "a task still linked by a template shows a disabled remove button, "
      'not a missing one',
      (tester) async {
        await openPostJob(tester);

        await tester.ensureVisible(find.text('Start from a template'));
        await tester.tap(find.text('Start from a template'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Move-in prep'));
        await tester.pumpAndSettle();

        final lockedButton = find.byWidgetPredicate((w) =>
            w is IconButton &&
            w.tooltip ==
                'Linked by the template. Tap Clear template to remove it.');
        expect(lockedButton, findsWidgets);
        final icon = tester.widget<IconButton>(lockedButton.first);
        expect(icon.onPressed, isNull);
      },
    );

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
