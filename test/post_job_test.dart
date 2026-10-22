import 'package:fairbid/core/location/penang_districts.dart';
import 'package:fairbid/core/theme/app_theme.dart';
import 'package:fairbid/core/widgets/form_widgets.dart';
import 'package:fairbid/features/jobs/data/assist_repository.dart';
import 'package:fairbid/features/jobs/domain/bundle.dart';
import 'package:fairbid/features/jobs/domain/job.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fakes.dart';
import 'helpers/harness.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await PenangDistricts.instance.ensureLoaded();
  });

  group('Post a job', () {
    testWidgets('an empty form reports every required field', (tester) async {
      await openPostJob(tester);

      final submit = find.widgetWithText(FilledButton, 'Post job');
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();

      // All three sit in the first section, above the submit button.
      expect(find.text('Pick a category.'), findsOneWidget);
      expect(find.text('Title is required.'), findsOneWidget);
      expect(find.text('Description is required.'), findsOneWidget);
      // Nothing was posted, so the form is still up.
      expect(find.text('Post a job'), findsOneWidget);
    });

    testWidgets('a complete form posts the job', (tester) async {
      await openPostJob(tester);

      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Plumbing').last);
      await tester.pumpAndSettle();

      await fillField(tester, 'Job title', 'Fix the kitchen tap');
      await fillField(tester, 'Description', 'It drips constantly.');

      // "Where" is already satisfied by the seeded default location.

      final submit = find.widgetWithText(FilledButton, 'Post job');
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();

      // No photo, so it asks first instead of posting.
      expect(find.text('Post without photos?'), findsOneWidget);
      expect(find.text('Job posted!'), findsNothing);
      await tester.tap(find.text('Post anyway'));
      await tester.pumpAndSettle();

      expect(find.text('Job posted!'), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------
  // Posting a bundle: Post-a-Job's "Add another task", which is the only way
  // a requestor can reach createBundle (docs/BUNDLE_BIDDING.md, "Requestor
  // side"). One task still posts an ordinary job - the group above covers
  // that path and must keep passing.
  // -------------------------------------------------------------------------
  group('Post a bundle', () {
    /// Opens the form and hands back the fake the posting will go through.
    Future<FakeBundleRepository> openBundleForm(WidgetTester tester) async {
      final bundles = FakeBundleRepository();
      await openPostJob(tester, bundle: bundles, height: 2400);
      return bundles;
    }

    Future<void> addTask(WidgetTester tester) async {
      final add = find.textContaining('Add another task');
      await tester.ensureVisible(add);
      await tester.pumpAndSettle();
      await tester.tap(add);
      await tester.pumpAndSettle();
    }

    /// Picks [category] in the [index]-th category dropdown (0 is task 1).
    Future<void> pickCategory(
      WidgetTester tester,
      int index,
      String category,
    ) async {
      final dropdown = find.byType(DropdownButtonFormField<String>).at(index);
      await tester.ensureVisible(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text(category).last);
      await tester.pumpAndSettle();
    }

    testWidgets('adding a task turns the form into a bundled posting', (
      tester,
    ) async {
      await openBundleForm(tester);
      expect(find.widgetWithText(FilledButton, 'Post job'), findsOneWidget);

      await addTask(tester);

      expect(find.text('Task 1'), findsOneWidget);
      expect(find.text('Task 2'), findsOneWidget);
      expect(find.text('Posting title'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Post bundle'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Post job'), findsNothing);
    });

    testWidgets('adding a task counts them and asks for a posting name', (
      tester,
    ) async {
      await openBundleForm(tester);
      await addTask(tester);

      expect(find.text('2 tasks in this posting'), findsOneWidget);
      // The name is asked for at the end of the form, not above the fold.
      expect(find.text('Name this posting'), findsOneWidget);
    });

    testWidgets('the task you add is scrolled into view', (tester) async {
      await openBundleForm(tester);
      // A phone-sized viewport, where the new card starts off screen.
      await tester.binding.setSurfaceSize(const Size(400, 700));
      await tester.pumpAndSettle();

      await addTask(tester);

      final card = tester.getRect(find.text('Task 2'));
      expect(card.top, lessThan(700));
      expect(card.bottom, greaterThan(0));
    });

    testWidgets('an address already added is flagged, and clears', (
      tester,
    ) async {
      await openBundleForm(tester);
      await tapAt(tester,
          find.text('Add address (only your hired provider sees it)'));
      await fillField(tester, 'Address line 1', '12 Jalan Mawar');
      await fillField(tester, 'Postcode', '11900');
      await fillField(tester, 'Town/City', 'Bayan Lepas');
      await tapAt(tester, find.widgetWithText(FilledButton, 'Save address'));

      await addTask(tester);

      expect(find.textContaining('service address you added will not be'),
          findsOneWidget);
      await tapAt(tester, find.widgetWithText(TextButton, 'Clear it'));
      expect(find.textContaining('service address you added will not be'),
          findsNothing);
    });

    testWidgets('a two-task form posts one bundle', (tester) async {
      final bundles = await openBundleForm(tester);

      await pickCategory(tester, 0, 'Plumbing');
      await fillField(tester, 'Job title', 'Fix the kitchen tap');
      await fillField(tester, 'Description', 'It drips constantly.');
      await addTask(tester);
      await pickCategory(tester, 1, 'Electrical');
      await fillField(tester, 'Task 2 title', 'Replace the ceiling light');
      await fillField(tester, 'Task 2 description', 'The fitting is cracked.');
      await fillField(tester, 'Posting title', 'Kitchen refresh');

      final submit = find.widgetWithText(FilledButton, 'Post bundle');
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Post anyway'));
      await tester.pumpAndSettle();

      final posted = bundles.lastCreate!;
      final tasks = posted['tasks'] as List<BundleTaskDraft>;
      expect(posted['title'], 'Kitchen refresh');
      expect(tasks.map((t) => t.title),
          ['Fix the kitchen tap', 'Replace the ceiling light']);
      expect(tasks.map((t) => t.category), ['Plumbing', 'Electrical']);
      // The shared location came from the requestor's saved default.
      expect((posted['location'] as JobLocation).districtCode, 'TL');
      // A blank summary falls back to the task titles, because createBundle
      // requires a description and the form already knows one.
      expect(posted['description'],
          '2 tasks: Fix the kitchen tap, Replace the ceiling light.');
      expect(find.text('Bundle posted with 2 tasks!'), findsOneWidget);
    });
  });

  group('AppTextField', () {
    testWidgets('a labelTrailing widget sits flush with the row\'s right '
        'edge', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: AppTextField(
            controller: TextEditingController(),
            label: 'Password',
            labelTrailing: const Text('Forgot?'),
          ),
        ),
      ));

      final row = find.ancestor(
        of: find.text('Forgot?'),
        matching: find.byType(Row),
      );
      final rowRight = tester.getRect(row).right;
      final trailingRight = tester.getRect(find.text('Forgot?')).right;
      // Expanded (not Flexible+Spacer) pushes the label to wrap instead of
      // splitting the row 50/50, so the trailing widget lands flush right.
      expect(trailingRight, closeTo(rowRight, 0.5));
    });
  });

  // -------------------------------------------------------------------------
  // The one-shot draft: one rough note fills the form, and never overwrites
  // anything already typed.
  // -------------------------------------------------------------------------
  group('Drafting a post with AI', () {
    final draft = const JobDraft(
      title: 'Fix the kitchen tap',
      category: 'Plumbing',
      description: 'What needs doing\nTap drips all night.',
      minSen: 8000,
      maxSen: 15000,
    );

    Future<void> runDraft(WidgetTester tester) async {
      await tester.tap(find.text("Describe it once, we'll fill this in"));
      await tester.pumpAndSettle();
      await fillField(tester, 'In your own words', 'kitchen tap drips');
      await tester.tap(find.widgetWithText(FilledButton, 'Draft my post'));
      await tester.pumpAndSettle();
    }

    testWidgets('one note fills the title, category and budget', (
      tester,
    ) async {
      await openPostJob(tester, assist: FakeAssistRepository(draft: draft), height: 2000);
      await runDraft(tester);

      expect(find.widgetWithText(TextFormField, 'Fix the kitchen tap'),
          findsOneWidget);
      expect(find.text('Plumbing'), findsOneWidget); // the category dropdown
      expect(find.widgetWithText(TextFormField, '80.00'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '150.00'), findsOneWidget);
    });

    testWidgets('a draft never overwrites what you already typed', (
      tester,
    ) async {
      await openPostJob(tester, assist: FakeAssistRepository(draft: draft), height: 2000);
      await fillField(tester, 'Job title', 'My own title');
      await runDraft(tester);

      expect(find.widgetWithText(TextFormField, 'My own title'),
          findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'Fix the kitchen tap'),
          findsNothing);
      // The fields it did fill are named back to the requestor.
      expect(find.textContaining('Filled in'), findsOneWidget);
    });

    testWidgets('task 2 drafts from its own note and leaves task 1 alone', (
      tester,
    ) async {
      await openPostJob(tester, assist: FakeAssistRepository(draft: draft), height: 2400);
      await tapAt(tester, find.textContaining('Add another task'));

      await tapAt(tester, find.text("Describe task 2, we'll fill it in"));
      await fillField(tester, 'In your own words', 'kitchen tap drips');
      await tester.tap(find.widgetWithText(FilledButton, 'Draft my post'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextFormField, 'Fix the kitchen tap'),
          findsOneWidget);
      // Task 1's title is the first text field on the form, and stays empty.
      final task1Title = tester.widget<TextFormField>(
          find.byType(TextFormField).first);
      expect(task1Title.controller!.text, isEmpty);
    });

    testWidgets('task 2 can ask for its own fair range', (tester) async {
      await openPostJob(
          tester,
          assist: FakeAssistRepository(
              priceRange: (minSen: 8000, maxSen: 15000)),
          height: 2400);
      await tapAt(tester, find.textContaining('Add another task'));

      final dropdown = find.byType(DropdownButtonFormField<String>).at(1);
      await tapAt(tester, dropdown);
      await tapAt(tester, find.text('Plumbing').last);
      await fillField(tester, 'Task 2 description', 'The tap drips.');
      await tapAt(tester, find.text('Suggest a fair range').at(1));

      expect(find.textContaining('Similar jobs'), findsOneWidget);
    });
  });
}
