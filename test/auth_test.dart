import 'package:fairbid/core/widgets/app_widgets.dart';
import 'package:fairbid/features/auth/data/auth_exception.dart';
import 'package:fairbid/features/auth/domain/mfa.dart';
import 'package:fairbid/features/auth/domain/user_role.dart';
import 'package:fairbid/features/auth/presentation/mfa_code_sheet.dart';
import 'package:fairbid/features/auth/presentation/validators.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fakes.dart';
import 'helpers/harness.dart';

void main() {
  group('Validators', () {
    test('email rejects malformed and accepts valid', () {
      expect(Validators.email(''), isNotNull);
      expect(Validators.email('not-an-email'), isNotNull);
      expect(Validators.email('a@b.com'), isNull);
    });

    test('password requires 8+ characters (per design mock)', () {
      expect(Validators.password('1234567'), isNotNull);
      expect(Validators.password('12345678'), isNull);
    });

    test('confirmPassword must match', () {
      expect(Validators.confirmPassword('abc', 'xyz'), isNotNull);
      expect(Validators.confirmPassword('abc', 'abc'), isNull);
    });
  });

  group('Login', () {
    testWidgets('shows the expected fields and tabs', (tester) async {
      await pumpApp(tester, buildApp(FakeAuthRepository()));

      expect(find.text('Welcome to FairBid'), findsOneWidget);
      expect(find.text('Log In'), findsWidgets); // tab + button
      expect(find.text('Sign Up'), findsOneWidget);
      expect(find.text('Email'), findsOneWidget);
      expect(find.text('Password'), findsOneWidget);
      expect(find.text('Continue with Google'), findsOneWidget);
    });

    testWidgets('typed input text has a visible colour', (tester) async {
      await pumpApp(tester, buildApp(FakeAuthRepository()));

      final editable = tester.widget<EditableText>(
        find.byType(EditableText).first,
      );
      expect(editable.style.color, isNotNull);
      expect(editable.style.color, isNot(Colors.white));
    });

    testWidgets('empty submit shows validation errors', (tester) async {
      await pumpApp(tester, buildApp(FakeAuthRepository()));

      await tester.tap(find.widgetWithText(FilledButton, 'Log In'));
      await tester.pumpAndSettle();

      expect(find.text('Email is required.'), findsOneWidget);
      expect(find.text('Password is required.'), findsOneWidget);
    });

    testWidgets('successful sign-in lands on home', (tester) async {
      await pumpApp(tester, buildApp(FakeAuthRepository()));

      await logIn(tester);

      // Lands on the app shell (requestor home).
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.text('Hello, Test'), findsOneWidget);
      for (final tab in ['Home', 'My jobs', 'Messages', 'Profile']) {
        expect(find.text(tab), findsWidgets);
      }
    });

    testWidgets('Forgot password with no email prompts for one', (
      tester,
    ) async {
      final repo = FakeAuthRepository();
      await pumpApp(tester, buildApp(repo));

      await tester.tap(find.text('Forgot Email or Password?'));
      await tester.pump(); // let the snackbar animate in

      expect(find.text('Enter your email first'), findsOneWidget);
      expect(repo.passwordResetsSent, isEmpty);
    });

    testWidgets('Forgot password sends a reset email for the typed address', (
      tester,
    ) async {
      final repo = FakeAuthRepository();
      await pumpApp(tester, buildApp(repo));

      await fillField(tester, 'Email', 'test@fairbid.app');
      await tester.tap(find.text('Forgot Email or Password?'));
      await tester.pumpAndSettle();

      expect(repo.passwordResetsSent, ['test@fairbid.app']);
      expect(
        find.text('Password reset email sent to test@fairbid.app'),
        findsOneWidget,
      );
    });

    testWidgets('failed sign-in shows an error banner', (tester) async {
      final repo = FakeAuthRepository()
        ..failWith = const AuthException('Incorrect email or password.');
      await pumpApp(tester, buildApp(repo));

      await logIn(tester);

      expect(find.text('Incorrect email or password.'), findsOneWidget);
    });
  });

  group('Register', () {
    Future<void> openRegister(WidgetTester tester) async {
      await tester.tap(find.text('Sign Up'));
      await tester.pumpAndSettle();
      expect(find.text('Join FairBid'), findsOneWidget);
    }

    Future<void> fillRegisterForm(WidgetTester tester) async {
      await fillField(tester, 'FULL NAME', 'New User');
      await fillField(tester, 'EMAIL ADDRESS', 'new@fairbid.app');
      await fillField(tester, 'PASSWORD', 'secret123');
      await fillField(tester, 'CONFIRM PASSWORD', 'secret123');
      final checkbox = find.byType(Checkbox);
      await tester.ensureVisible(checkbox);
      await tester.tap(checkbox);
      await tester.pumpAndSettle();
    }

    Future<void> submit(WidgetTester tester) async {
      final button = find.widgetWithText(FilledButton, 'Sign Up');
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
    }

    testWidgets('requestor completes onboarding and lands on home', (
      tester,
    ) async {
      await pumpApp(tester, buildApp(FakeAuthRepository()..onboardingComplete = false));
      await openRegister(tester);
      await tester.tap(find.text('Hire'));
      await tester.pumpAndSettle();
      await fillRegisterForm(tester);
      await submit(tester);
      expect(find.text('How will you hire?'), findsOneWidget);
      expect(find.text('Business'), findsOneWidget);

      // Stage 1 → pick Individual → Continue.
      await tester.tap(find.text('Individual'));
      await tester.pumpAndSettle();
      final stage1Continue = find.widgetWithText(FilledButton, 'Continue');
      await tester.ensureVisible(stage1Continue);
      await tester.tap(stage1Continue);
      await tester.pumpAndSettle();

      // Stage 2 → fill required details → Continue.
      await fillField(tester, 'Full Name', 'Jane Client');
      await fillField(tester, 'Phone Number', '0123456789');
      await pickPenangLocation(
        tester,
        placeholder: 'Pick your default location in Penang',
      );
      final continueBtn = find.widgetWithText(FilledButton, 'Continue');
      await tester.ensureVisible(continueBtn);
      await tester.tap(continueBtn);
      await tester.pumpAndSettle();

      // Stage 3 → Skip verification → finish.
      final skip = find.widgetWithText(OutlinedButton, 'Skip for now');
      await tester.ensureVisible(skip);
      await tester.tap(skip);
      await tester.pumpAndSettle();

      // Onboarding complete → lands on the app shell.
      expect(find.byType(NavigationBar), findsOneWidget);
    });

    testWidgets('onboarding continue unlocks after picking a provider type', (
      tester,
    ) async {
      await pumpApp(tester, buildApp(FakeAuthRepository()));
      await openRegister(tester);
      await tester.tap(find.text('Work'));
      await tester.pumpAndSettle();
      await fillRegisterForm(tester);
      await submit(tester);
      expect(find.text('Choose Provider Type'), findsOneWidget);
      expect(find.text('Registered Business'), findsOneWidget);

      // Continue starts disabled.
      final continueButton = find.widgetWithText(FilledButton, 'Continue');
      expect(tester.widget<FilledButton>(continueButton).onPressed, isNull);

      // Selecting a type enables it; tapping moves to identity verification.
      await tester.tap(find.text('Individual / Freelancer'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(continueButton);
      await tester.tap(continueButton);
      await tester.pumpAndSettle();

      expect(find.text('Verify your identity'), findsOneWidget);
    });
  });

  group('App shell', () {
    testWidgets('profile tab shows the user name and logout', (tester) async {
      // Tall surface so the whole profile (incl. bottom "Log out") lays out.

      await pumpApp(tester, buildApp(FakeAuthRepository()), size: const Size(500, 2200));
      await logIn(tester);

      await openTab(tester, 'Profile');

      expect(find.text('Test User'), findsWidgets);
      expect(find.widgetWithText(OutlinedButton, 'Log out'), findsOneWidget);
    });

    testWidgets('verified provider home shows stat cards', (tester) async {
      final repo = FakeAuthRepository()..verificationStatus = 'approved';
      await pumpApp(tester, buildApp(repo));
      await openRegisterAs(tester, 'Work');

      // Provider, approved → not gated → provider home with its stat cards.
      expect(find.byType(StatCard), findsWidgets);
    });
  });

  group('Email verification', () {
    testWidgets('unverified user sees the banner and can resend', (
      tester,
    ) async {
      final auth = FakeAuthRepository()..emailVerified = false;
      await pumpApp(tester, buildApp(auth));
      await logIn(tester);

      expect(find.text('Verify your email'), findsOneWidget);

      await tester.tap(find.text('Resend'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(auth.verificationEmailsSent, 1);
      expect(find.textContaining('Verification email sent'), findsOneWidget);

      // Let the 60s cooldown finish so its Timer.periodic self-cancels
      // instead of leaking past the end of the test.
      await tester.pump(const Duration(seconds: 61));
    });

    testWidgets('verified user sees no banner', (tester) async {
      await pumpApp(tester, buildApp(FakeAuthRepository()));
      await logIn(tester);

      expect(find.text('Verify your email'), findsNothing);
    });

    testWidgets('tapping refresh after verifying hides the banner', (
      tester,
    ) async {
      final auth = FakeAuthRepository()
        ..emailVerified = false
        ..verifyOnReload = true;
      await pumpApp(tester, buildApp(auth));
      await logIn(tester);

      await tester.tap(find.byTooltip("I've verified - refresh"));
      await tester.pumpAndSettle();

      expect(find.text('Verify your email'), findsNothing);
    });

    testWidgets('withdrawing asks to confirm identity; cancelling stops it', (
      tester,
    ) async {

      final auth = FakeAuthRepository()
        ..verificationStatus = 'approved'
        ..walletBalanceSen = 85000;
      await pumpApp(tester, buildApp(auth), size: const Size(500, 2200));
      await openRegisterAs(tester, 'Work');
      await openTab(tester, 'Profile');
      await tester.tap(find.text('Earnings & payouts'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Withdraw'));
      await tester.pumpAndSettle();
      expect(find.text("Confirm it's you"), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(auth.reauthCount, 0);
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('confirming identity opens the withdraw amount sheet', (
      tester,
    ) async {

      final auth = FakeAuthRepository()
        ..verificationStatus = 'approved'
        ..walletBalanceSen = 85000;
      await pumpApp(tester, buildApp(auth), size: const Size(500, 2200));
      await openRegisterAs(tester, 'Work');
      await openTab(tester, 'Profile');
      await tester.tap(find.text('Earnings & payouts'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Withdraw'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'Your password'),
        'secret123',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
      await tester.pumpAndSettle();

      expect(auth.reauthCount, 1);
      expect(
        find.textContaining('Sent to Maybank'),
        findsOneWidget,
      );
    });
  });

  group('Two-factor authentication', () {
    Future<void> openSecurityScreen(WidgetTester tester) async {
      await openTab(tester, 'Profile');
      await tester.tap(find.text('Security'));
      await tester.pumpAndSettle();
    }

    testWidgets(
      'signing in with 2FA on prompts for a code; wrong code stays open, '
      'right code signs in',
      (tester) async {
        final auth = FakeAuthRepository()..requireMfaOnSignIn = true;
        await pumpApp(tester, buildApp(auth));
        await logIn(tester);

        expect(find.text('Two-factor authentication'), findsOneWidget);
        expect(find.byType(NavigationBar), findsNothing);

        // The login screen's own fields are still mounted behind the sheet
        // (TextFormField renders a TextField internally too), so scope the
        // finder to the sheet's field.
        final codeField = find.descendant(
          of: find.byType(MfaCodeSheet),
          matching: find.byType(TextField),
        );
        await tester.enterText(codeField, '000000');
        await tester.tap(find.widgetWithText(FilledButton, 'Verify'));
        await tester.pumpAndSettle();
        expect(find.text('That code is incorrect.'), findsOneWidget);

        await tester.enterText(codeField, '123456');
        await tester.tap(find.widgetWithText(FilledButton, 'Verify'));
        await tester.pumpAndSettle();

        expect(find.byType(NavigationBar), findsOneWidget);
      },
    );

    testWidgets('security screen shows Off, then On after enrolling', (
      tester,
    ) async {

      final auth = FakeAuthRepository();
      await pumpApp(tester, buildApp(auth), size: const Size(500, 2200));
      await logIn(tester);
      await openSecurityScreen(tester);

      expect(find.text('Off'), findsOneWidget);

      await tester.tap(find.widgetWithText(PrimaryButton, 'Turn on'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Your password'),
        'secret123',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
      await tester.pumpAndSettle();

      expect(find.text('Scan this code'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '123456');
      await tester.tap(find.text('Verify and turn on'));
      await tester.pumpAndSettle();

      expect(find.text('On'), findsOneWidget);
    });

    testWidgets('unverified email blocks turning 2FA on', (tester) async {

      final auth = FakeAuthRepository()..emailVerified = false;
      await pumpApp(tester, buildApp(auth), size: const Size(500, 2200));
      await logIn(tester);
      await openSecurityScreen(tester);

      expect(find.text('Verify your email first'), findsOneWidget);
      expect(find.text('Turn on'), findsNothing);
    });

    testWidgets('turning off asks for confirmation, then returns to Off', (
      tester,
    ) async {

      final auth = FakeAuthRepository()
        ..mfaFactors = const [
          MfaFactor(uid: 'factor-1'),
        ];
      await pumpApp(tester, buildApp(auth), size: const Size(500, 2200));
      await logIn(tester);
      await openSecurityScreen(tester);

      expect(find.text('On'), findsOneWidget);
      await tester.tap(find.widgetWithText(SecondaryButton, 'Turn off'));
      await tester.pumpAndSettle();

      expect(find.text('Turn off two-factor?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Turn off'));
      await tester.pumpAndSettle();

      expect(find.text('Off'), findsOneWidget);
    });

    testWidgets(
      'withdrawing as an enrolled user shows re-auth, then the code sheet',
      (tester) async {

        // Seeded already signed in - this test targets the reauth path, not
        // the (separately covered) sign-in one, and requireMfaOnSignIn is a
        // single-use flag.
        final auth = FakeAuthRepository()
          ..verificationStatus = 'approved'
          ..walletBalanceSen = 85000
          ..mfaFactors = const [
            MfaFactor(uid: 'factor-1'),
          ]
          ..requireMfaOnSignIn = true
          ..seedSignedIn(UserRole.provider);
        await pumpApp(tester, buildApp(auth), size: const Size(500, 2200));
        await openTab(tester, 'Profile');
        await tester.tap(find.text('Earnings & payouts'));
        await tester.pumpAndSettle();

        await tester.tap(find.widgetWithText(FilledButton, 'Withdraw'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextField, 'Your password'),
          'secret123',
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
        await tester.pumpAndSettle();

        expect(find.text('Two-factor authentication'), findsOneWidget);

        // The reauth dialog's password field is still mounted behind the
        // sheet - scope the finder to the sheet's field.
        await tester.enterText(
          find.descendant(
            of: find.byType(MfaCodeSheet),
            matching: find.byType(TextField),
          ),
          '123456',
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Verify'));
        await tester.pumpAndSettle();

        expect(
          find.textContaining('Sent to Maybank'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'deleting the account as an MFA-enrolled user with a stale session '
      'prompts for the code and completes the deletion',
      (tester) async {

        // Seeded already signed in, same as the withdraw test above -
        // deleteAccount re-authenticates internally, so the challenge
        // surfaces from that call rather than a separate reauth dialog.
        final auth = FakeAuthRepository()
          ..mfaFactors = const [
            MfaFactor(uid: 'factor-1'),
          ]
          ..requireMfaOnSignIn = true
          ..seedSignedIn(UserRole.requestor);
        await pumpApp(tester, buildApp(auth), size: const Size(500, 2200));
        await openTab(tester, 'Profile');

        await tester.tap(find.text('Delete Account'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextField, 'Confirm your password'),
          'secret123',
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
        await tester.pumpAndSettle();

        // The Security nav card behind the sheet also says "Two-factor
        // authentication", so scope this to the sheet itself.
        expect(find.byType(MfaCodeSheet), findsOneWidget);

        await tester.enterText(
          find.descendant(
            of: find.byType(MfaCodeSheet),
            matching: find.byType(TextField),
          ),
          '123456',
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Verify'));
        await tester.pumpAndSettle();

        // Signed out -> router redirects back to the login screen.
        expect(find.text('Delete account?'), findsNothing);
        expect(find.widgetWithText(FilledButton, 'Log In'), findsOneWidget);
      },
    );
  });
}
