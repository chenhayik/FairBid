import 'package:fairbid/core/location/penang_districts.dart';
import 'package:fairbid/core/widgets/location_field.dart';
import 'package:fairbid/features/auth/data/auth_exception.dart';
import 'package:fairbid/features/jobs/domain/job.dart';
import 'package:fairbid/features/profile/domain/review.dart';
import 'package:fairbid/features/profile/presentation/edit_profile_screen.dart';
import 'package:fairbid/features/wallet/domain/payout_method.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/builders.dart';
import 'helpers/fakes.dart';
import 'helpers/harness.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await PenangDistricts.instance.ensureLoaded();
  });

  group('Profile screen', () {
    Future<void> openProfileTab(WidgetTester tester) async {
      await openTab(tester, 'Profile');
    }

    testWidgets('shows Earnings & payouts for a provider', (tester) async {

      final auth = FakeAuthRepository()..verificationStatus = 'approved';
      await pumpApp(tester, buildApp(auth), size: const Size(500, 2200));
      await openRegisterAs(tester, 'Work');
      await openProfileTab(tester);

      expect(find.text('Earnings & payouts'), findsOneWidget);
    });

    testWidgets('hides Earnings & payouts for a requestor', (tester) async {

      await pumpApp(tester, buildApp(FakeAuthRepository()), size: const Size(500, 2200));
      await logIn(tester);
      await openProfileTab(tester);

      expect(find.text('Earnings & payouts'), findsNothing);
    });

    testWidgets('edit profile updates the name and About', (tester) async {

      await pumpApp(tester, buildApp(FakeAuthRepository()), size: const Size(500, 2200));
      await logIn(tester);
      await openProfileTab(tester);

      await tester.tap(find.text('Edit').first);
      await tester.pumpAndSettle();

      final fields = find.descendant(
        of: find.byType(EditProfileScreen),
        matching: find.byType(TextFormField),
      );
      await tester.enterText(fields.at(0), 'Brand New Name');
      await tester.enterText(fields.at(2), 'A fresh bio about my work.');
      final save = find.widgetWithText(FilledButton, 'Save');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();

      expect(find.text('Brand New Name'), findsWidgets);
      expect(find.text('A fresh bio about my work.'), findsOneWidget);
    });

    testWidgets('edit profile shows a map location picker, not free text', (
      tester,
    ) async {

      await pumpApp(tester, buildApp(FakeAuthRepository()), size: const Size(500, 2200));
      await logIn(tester);
      await openProfileTab(tester);
      await tester.tap(find.text('Edit').first);
      await tester.pumpAndSettle();

      expect(find.byType(LocationField), findsOneWidget);
      expect(find.text('Pick your location in Penang'), findsOneWidget);
      // Requestors don't get the provider-only services section.
      expect(find.text('Your services'), findsNothing);
    });

    testWidgets('a provider edits category and skills and saves', (
      tester,
    ) async {

      final auth = FakeAuthRepository()
        ..verificationStatus = 'approved'
        ..category = 'Plumbing'
        ..skills = ['Pipe repair'];
      await pumpApp(tester, buildApp(auth), size: const Size(500, 2600));
      await openRegisterAs(tester, 'Work');
      await openProfileTab(tester);
      await tester.tap(find.text('Edit').first);
      await tester.pumpAndSettle();

      expect(find.text('Your services'), findsOneWidget);
      // Prefilled from the saved onboarding data.
      expect(find.text('Plumbing'), findsOneWidget);
      expect(find.text('Pipe repair'), findsOneWidget);

      await tester.tap(find.text('Plumbing'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Electrical').last);
      await tester.pumpAndSettle();
      final skills = find.descendant(
        of: find.byType(EditProfileScreen),
        matching: find.byType(TextFormField),
      );
      await tester.enterText(skills.at(3), 'Wiring, Fan install , Wiring');
      final save = find.widgetWithText(FilledButton, 'Save');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();

      expect(auth.category, 'Electrical');
      expect(auth.skills, ['Wiring', 'Fan install']);
    });

    testWidgets('reviews section shows the empty state with no reviews', (
      tester,
    ) async {

      await pumpApp(tester, buildApp(FakeAuthRepository()), size: const Size(500, 2200));
      await logIn(tester);
      await openProfileTab(tester);

      expect(find.text('No reviews yet'), findsOneWidget);
    });

    testWidgets('reviews section renders a seeded review', (tester) async {

      final review = Review(
        id: 'r1',
        reviewerId: 'someone',
        reviewerName: 'Sarah Connor',
        rating: 5,
        comment: 'Communications were clear.',
        createdAt: DateTime.now(),
      );
      await pumpApp(tester, buildApp(FakeAuthRepository(), reviews: [review]), size: const Size(500, 2200));
      await logIn(tester);
      await openProfileTab(tester);

      expect(find.text('Sarah Connor'), findsOneWidget);
      expect(find.text('"Communications were clear."'), findsOneWidget);
    });

    testWidgets('Trust Score card shows the New state until earned', (
      tester,
    ) async {

      // Approved but only 1 completed job → below the visibility gate.
      final auth = FakeAuthRepository()
        ..verificationStatus = 'approved'
        ..jobsCompleted = 1;
      await pumpApp(tester, buildApp(auth), size: const Size(500, 2200));
      await openRegisterAs(tester, 'Work');
      await openProfileTab(tester);

      expect(find.text('New'), findsOneWidget);
      // The four real sub-bars replace the old decorative ones.
      expect(find.text('Track Record'), findsOneWidget);
      expect(find.text('Verification'), findsOneWidget);
      expect(find.textContaining('/100'), findsNothing); // no headline number
    });

    testWidgets('Trust Score card shows the number once earned', (
      tester,
    ) async {

      final auth = FakeAuthRepository()
        ..verificationStatus = 'approved'
        ..jobsCompleted = 5
        ..ratingSum = 90
        ..ratingCount = 20;
      await pumpApp(tester, buildApp(auth), size: const Size(500, 2200));
      await openRegisterAs(tester, 'Work');
      await openProfileTab(tester);

      expect(find.text('New'), findsNothing);
      expect(find.textContaining('/100'), findsOneWidget);
    });

    testWidgets('earnings screen shows the balance and Withdraw', (
      tester,
    ) async {

      final auth = FakeAuthRepository()
        ..verificationStatus = 'approved'
        ..walletBalanceSen = 85000;
      await pumpApp(tester, buildApp(auth), size: const Size(500, 2200));
      await openRegisterAs(tester, 'Work');
      await openProfileTab(tester);

      await tester.tap(find.text('Earnings & payouts'));
      await tester.pumpAndSettle();

      expect(find.text('RM\u00A0850.00'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Withdraw'), findsOneWidget);
    });

    testWidgets('delete account cancel keeps the user signed in', (
      tester,
    ) async {

      await pumpApp(tester, buildApp(FakeAuthRepository()), size: const Size(500, 2200));
      await logIn(tester);
      await openProfileTab(tester);

      await tester.tap(find.text('Delete Account'));
      await tester.pumpAndSettle();
      expect(find.text('Delete account?'), findsOneWidget);
      expect(find.text('Confirm your password'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Delete account?'), findsNothing);
      expect(find.text('Delete Account'), findsOneWidget);
    });

    testWidgets('delete account confirmed with password signs the user out', (
      tester,
    ) async {

      await pumpApp(tester, buildApp(FakeAuthRepository()), size: const Size(500, 2200));
      await logIn(tester);
      await openProfileTab(tester);

      await tester.tap(find.text('Delete Account'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'Confirm your password'),
        'secret123',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      // Signed out -> router redirects back to the login screen.
      expect(find.text('Delete account?'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Log In'), findsOneWidget);
    });

    testWidgets('delete account failure shows an error and stays signed in', (
      tester,
    ) async {

      final auth = FakeAuthRepository();
      await pumpApp(tester, buildApp(auth), size: const Size(500, 2200));
      await logIn(tester);
      await openProfileTab(tester);

      auth.failWith = const AuthException('Incorrect password.');
      await tester.tap(find.text('Delete Account'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Confirm your password'),
        'wrong',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(find.text('Incorrect password.'), findsOneWidget);
      expect(find.text('Delete Account'), findsOneWidget);
    });
  });

  group('Payout method', () {
    Future<FakeWalletRepository> openEarnings(
      WidgetTester tester, {
      PayoutMethod? method,
    }) async {
      final auth = FakeAuthRepository()
        ..verificationStatus = 'approved'
        ..walletBalanceSen = 85000;
      final wallet = FakeWalletRepository()..payoutMethod = method;
      await pumpApp(tester, buildApp(auth, wallet: wallet), size: const Size(500, 2200));
      await openRegisterAs(tester, 'Work');
      await openTab(tester, 'Profile');
      await tester.tap(find.text('Earnings & payouts'));
      await tester.pumpAndSettle();
      return wallet;
    }

    testWidgets('with no payout method, withdrawing asks to add one first', (
      tester,
    ) async {
      await openEarnings(tester);
      expect(find.textContaining('Not set up yet'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Withdraw'));
      await tester.pumpAndSettle();
      expect(find.text('Where should we send it?'), findsOneWidget);
    });

    testWidgets('a recently changed method blocks withdrawing for 24 hours', (
      tester,
    ) async {
      await openEarnings(
        tester,
        method: PayoutMethod(
          method: 'duitnow',
          masked: 'DuitNow 012-•••• 678',
          holderName: 'Test User',
          availableAt: DateTime.now().add(const Duration(hours: 20)),
        ),
      );
      expect(find.text('DuitNow 012-•••• 678'), findsOneWidget);
      expect(find.textContaining('24-hour safety hold'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Withdraw'));
      await tester.pumpAndSettle();
      expect(find.textContaining('withdrawals resume'), findsOneWidget);
    });

    testWidgets('a client sees Withdraw and the money held for jobs', (
      tester,
    ) async {
      final auth = FakeAuthRepository()..walletBalanceSen = 5000;
      await pumpApp(tester, buildApp(
        auth,
        jobs: [
          sampleJob(
            status: JobStatus.inProgress,
            acceptedProviderId: 'prov-1',
            acceptedBidAmountSen: 15000,
          ),
        ],
      ), size: const Size(500, 2200));
      await logIn(tester);
      await openTab(tester, 'Profile');
      await tester.tap(find.text('My wallet'));
      await tester.pumpAndSettle();

      expect(find.text('HELD IN ESCROW FOR YOUR JOBS'), findsOneWidget);
      expect(find.text('RM 150.00'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Withdraw'), findsOneWidget);
      expect(find.text('Payout method'), findsOneWidget);
    });

    testWidgets('a bank account is checked against the bank, then saved', (
      tester,
    ) async {
      final wallet = await openEarnings(tester);
      await tester.tap(find.widgetWithText(TextButton, 'Add'));
      await tester.pumpAndSettle();
      expect(find.text('How you get paid'), findsOneWidget);

      await tester.tap(find.text('Bank account'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pick your bank'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Maybank').last);
      await tester.pumpAndSettle();
      await fillField(tester, 'Account number', '12345');
      await fillField(tester, 'Account number again', '12345');
      await tester.tap(find.widgetWithText(FilledButton, 'Save payout method'));
      await tester.pumpAndSettle();
      expect(find.text('Maybank account numbers have 12 digits.'),
          findsOneWidget);
      expect(wallet.savedPayouts, isEmpty);

      await fillField(tester, 'Account number', '512345678901');
      await fillField(tester, 'Account number again', '512345678901');
      await tester.tap(find.widgetWithText(FilledButton, 'Save payout method'));
      await tester.pumpAndSettle();
      expect(wallet.savedPayouts.single, {
        'method': 'bank',
        'proxyType': null,
        'bankSwift': 'MBBEMYKL',
        'accountNumber': '512345678901',
      });
    });
  });
}
