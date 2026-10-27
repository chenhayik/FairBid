import 'package:fairbid/features/auth/data/auth_exception.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fakes.dart';
import 'helpers/harness.dart';

/// What:   Registration cases used in the Chapter 5 unit testing tables.
/// Input:  The Sign Up form, driven through FakeAuthRepository.
/// Output: Pass when the form shows the expected message.
void main() {
  Future<void> openSignUp(WidgetTester tester) async {
    await tester.tap(find.text('Sign Up'));
    await tester.pumpAndSettle();
  }

  Future<void> submit(WidgetTester tester) async {
    final button = find.widgetWithText(FilledButton, 'Sign Up');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  testWidgets('empty Sign Up form shows every mandatory field error', (
    tester,
  ) async {
    await pumpApp(tester, buildApp(FakeAuthRepository()));
    await openSignUp(tester);
    await submit(tester);

    expect(find.text('Name is required.'), findsOneWidget);
    expect(find.text('Email is required.'), findsOneWidget);
    expect(find.text('Password is required.'), findsOneWidget);
  });

  testWidgets('a 7-character password is rejected on the Sign Up form', (
    tester,
  ) async {
    await pumpApp(tester, buildApp(FakeAuthRepository()));
    await openSignUp(tester);
    await fillField(tester, 'FULL NAME', 'New User');
    await fillField(tester, 'EMAIL ADDRESS', 'new@fairbid.app');
    await fillField(tester, 'PASSWORD', '1234567');
    await fillField(tester, 'CONFIRM PASSWORD', '1234567');
    await submit(tester);

    expect(find.text('Must be at least 8 characters.'), findsOneWidget);
  });

  testWidgets('registering an email that is already in use shows an error', (
    tester,
  ) async {
    final repo = FakeAuthRepository()
      ..failWith = AuthException.fromFirebase(
        FirebaseAuthException(code: 'email-already-in-use'),
      );
    await pumpApp(tester, buildApp(repo));
    await openRegisterAs(tester, 'Hire');

    expect(
      find.text('An account already exists for that email.'),
      findsOneWidget,
    );
  });
}
