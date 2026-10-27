import 'package:fairbid/core/widgets/face_crop.dart';
import 'package:fairbid/features/admin/domain/flagged_review.dart';
import 'package:fairbid/features/admin/domain/managed_user.dart';
import 'package:fairbid/features/admin/domain/pending_verification.dart';
import 'package:fairbid/features/auth/domain/user_role.dart';
import 'package:fairbid/features/onboarding/data/face_checker.dart';
import 'package:fairbid/features/onboarding/domain/onboarding_data.dart';
import 'package:fairbid/features/onboarding/domain/requestor_onboarding_data.dart';
import 'package:fairbid/features/onboarding/domain/id_extract.dart';
import 'package:fairbid/features/onboarding/domain/ssm_extract.dart';
import 'package:fairbid/features/profile/domain/review.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fakes.dart';
import 'helpers/harness.dart';

void main() {
  group('Admin verification queue', () {
    PendingVerification samplePending({
      String uid = 'prov-9',
      String name = 'Alex Rivera',
      UserRole role = UserRole.provider,
    }) => PendingVerification(
      uid: uid,
      displayName: name,
      role: role,
      email: 'alex@fairbid.app',
      providerType: 'individual',
      submittedAt: DateTime.now().subtract(const Duration(hours: 2)),
      phone: '0123456789',
      location: 'Kuala Lumpur',
      category: 'Plumbing',
      skills: const ['Pipe fitting', 'Leak repair'],
      // Identity docs now come from the private-only loadIdentityDocuments;
      // the public `documents` list holds certificates/portfolio only.
      documents: const [],
    );

    testWidgets('admin lands on the queue and sees pending applicants', (
      tester,
    ) async {

      final auth = FakeAuthRepository()..seedSignedIn(UserRole.admin);
      await pumpApp(tester, buildApp(
          auth,
          verification: FakeVerificationRepository([samplePending()]),
        ), size: const Size(500, 1600));

      expect(find.text('Verification Queue'), findsOneWidget);
      expect(find.text('Alex Rivera'), findsOneWidget);
      // The "Pending Review" stat reflects the queue length.
      expect(find.text('1'), findsOneWidget);
    });

    Future<void> openDetail(
      WidgetTester tester,
      FakeVerificationRepository repo, {
      Size size = const Size(500, 2400),
    }) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final auth = FakeAuthRepository()..seedSignedIn(UserRole.admin);
      await pumpApp(tester, buildApp(auth, verification: repo));
      await tester.tap(find.text('Alex Rivera'));
      await tester.pumpAndSettle();
    }

    testWidgets('detail says when no automated ID check has run', (
      tester,
    ) async {
      await openDetail(tester, FakeVerificationRepository([samplePending()]));
      expect(find.text('Automated ID checks'), findsOneWidget);
      expect(find.text('No automated check yet'), findsOneWidget);
    });

    testWidgets('detail shows the automated ID check result', (tester) async {
      await openDetail(tester, FakeVerificationRepository([samplePending()])
        ..idExtract = const IdExtract(
          verdict: IdVerdict.needsReview,
          failures: ['name-mismatch'],
          maskedIc: '******-07-**34',
          ageOk: true,
          nameMatches: false,
        ));
      expect(find.textContaining('Needs review', findRichText: true),
          findsOneWidget);
      expect(find.text('******-07-**34'), findsOneWidget);
      expect(find.text('18 or older'), findsOneWidget);
      expect(find.text('Does not match'), findsOneWidget);
      expect(find.textContaining(idFailureLabel('name-mismatch')),
          findsOneWidget);
    });

    testWidgets('detail shows the automated SSM check result', (tester) async {
      final business = PendingVerification(
        uid: 'prov-9',
        displayName: 'Alex Rivera',
        role: UserRole.provider,
        providerType: 'business',
        ssmNumber: '201903350205',
      );
      await openDetail(tester, FakeVerificationRepository([business])
        ..ssmExtract = const SsmExtract(
          verdict: SsmVerdict.needsReview,
          failures: ['not-digitally-signed'],
          businessName: 'JIN XIAO LONG TRADING',
          registrationNumber: '201903350205',
        ));
      expect(find.text('Automated SSM checks'), findsOneWidget);
      expect(find.text('JIN XIAO LONG TRADING'), findsOneWidget);
      expect(find.text('Matches entered'), findsOneWidget);
      expect(find.textContaining('Not a digitally certified copy'),
          findsOneWidget);
    });

    testWidgets('individual detail hides the SSM checks', (tester) async {
      await openDetail(tester, FakeVerificationRepository([samplePending()]));
      expect(find.text('Automated SSM checks'), findsNothing);
    });

    testWidgets('detail shows the face comparison when ID and selfie exist', (
      tester,
    ) async {
      await openDetail(tester, FakeVerificationRepository([samplePending()])
        ..identityDocuments = const [
          VerificationDocument(
            label: 'Identity Document',
            url: 'https://fake.storage/id.jpg',
            faceBox: FaceBox(
                left: 0.1, top: 0.1, width: 0.3, height: 0.4, aspect: 1.5),
          ),
          VerificationDocument(
              label: 'Selfie', url: 'https://fake.storage/selfie.jpg'),
        ]);
      expect(find.text('Face comparison'), findsOneWidget);
      expect(find.text('Compare the two faces before approving.'),
          findsOneWidget);
      expect(find.text('On ID'), findsOneWidget);
      expect(find.byType(FaceCrop), findsNWidgets(2));
    });

    testWidgets('the face comparison fits a 360dp phone without overflow', (
      tester,
    ) async {
      await openDetail(
        tester,
        FakeVerificationRepository([samplePending()])
          ..identityDocuments = const [
            VerificationDocument(
              label: 'Identity Document',
              url: 'https://fake.storage/id.jpg',
              faceBox: FaceBox(
                  left: 0.1, top: 0.1, width: 0.3, height: 0.4, aspect: 1.5),
            ),
            VerificationDocument(
                label: 'Selfie', url: 'https://fake.storage/selfie.jpg'),
          ],
        size: const Size(360, 800),
      );
      expect(find.text('Face comparison'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final crops = tester.widgetList(find.byType(FaceCrop)).cast<FaceCrop>();
      expect(crops.map((c) => c.size).toSet().single, lessThan(140));
    });

    testWidgets('detail hides the face comparison without a selfie', (
      tester,
    ) async {
      await openDetail(tester, FakeVerificationRepository([samplePending()]));
      expect(find.text('Face comparison'), findsNothing);
      expect(find.byType(FaceCrop), findsNothing);
    });

    testWidgets('empty queue shows the all-caught-up state', (tester) async {
      final auth = FakeAuthRepository()..seedSignedIn(UserRole.admin);
      await pumpApp(tester, buildApp(auth));

      expect(find.text('All caught up'), findsOneWidget);
    });

    testWidgets('approving an applicant records the decision and clears it', (
      tester,
    ) async {

      final auth = FakeAuthRepository()..seedSignedIn(UserRole.admin);
      final verification = FakeVerificationRepository([samplePending()]);
      await pumpApp(tester, buildApp(auth, verification: verification), size: const Size(500, 1600));

      // Open the applicant's review screen.
      await tester.tap(find.text('Alex Rivera'));
      await tester.pumpAndSettle();
      expect(find.text('Verify Provider'), findsOneWidget);
      expect(find.text('Applicant Details'), findsOneWidget);
      expect(find.text('Identity Document'), findsOneWidget);

      // Approve → confirm in the dialog.
      await tester.tap(find.widgetWithText(FilledButton, 'Approve'));
      await tester.pumpAndSettle();
      expect(find.text('Approve verification?'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(FilledButton, 'Approve'),
        ),
      );
      await tester.pumpAndSettle();

      // Decision recorded; back on the queue, now empty.
      expect(verification.decisions['prov-9'], isTrue);
      expect(find.text('All caught up'), findsOneWidget);
    });

    testWidgets('admin profile shows admin info, not marketplace fields', (
      tester,
    ) async {

      final auth = FakeAuthRepository()..seedSignedIn(UserRole.admin);
      await pumpApp(tester, buildApp(
          auth,
          verification: FakeVerificationRepository([samplePending()]),
        ), size: const Size(500, 1600));

      await openTab(tester, 'Profile');

      // Admin-appropriate content.
      expect(find.text('Administrator'), findsOneWidget);
      expect(find.text('Administrator Access'), findsOneWidget);
      // StatCard uppercases its label.
      expect(find.text('PENDING VERIFICATIONS'), findsOneWidget);
      // Marketplace-participant content is hidden for admins.
      expect(find.text('Trust Score'), findsNothing);
      expect(find.text('Earnings & payouts'), findsNothing);
      expect(find.textContaining('Reviews ('), findsNothing);
    });

    testWidgets('rejecting captures the reason', (tester) async {

      final auth = FakeAuthRepository()..seedSignedIn(UserRole.admin);
      final verification = FakeVerificationRepository([samplePending()]);
      await pumpApp(tester, buildApp(auth, verification: verification), size: const Size(500, 1600));

      await tester.tap(find.text('Alex Rivera'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(OutlinedButton, 'Reject'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Blurry document.');
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(FilledButton, 'Reject'),
        ),
      );
      await tester.pumpAndSettle();

      expect(verification.decisions['prov-9'], isFalse);
      expect(verification.lastReason, 'Blurry document.');
    });
  });

  group('Verification privacy', () {
    test('provider toMap excludes identity photo URLs (they go private)', () {
      final data = OnboardingData()
        ..idDocumentUrl = 'https://x/id.jpg'
        ..selfieUrl = 'https://x/selfie.jpg';
      final map = data.toMap();
      expect(map.containsKey('idDocumentUrl'), isFalse);
      expect(map.containsKey('selfieUrl'), isFalse);
      expect(data.privateMap()['idDocumentUrl'], 'https://x/id.jpg');
      expect(data.privateMap()['selfieUrl'], 'https://x/selfie.jpg');
    });

    test('requestor toMap excludes the ID/SSM document URL', () {
      final data = RequestorOnboardingData()
        ..clientDocumentUrl = 'https://x/doc.jpg';
      expect(data.toMap().containsKey('clientDocumentUrl'), isFalse);
      expect(data.privateMap()['clientDocumentUrl'], 'https://x/doc.jpg');
    });

    test('requestor toMap excludes the phone number (it goes private)', () {
      final data = RequestorOnboardingData()..phone = '012-345 6789';
      expect(data.toMap().containsKey('phone'), isFalse);
      expect(data.payoutMap()['phone'], '012-345 6789');
    });

    test('PendingVerification takes the phone from the private payout doc, '
        'preferring it over the legacy public-doc location', () {
      final v = PendingVerification.fromMap(
        'prov-1',
        {
          'role': 'provider',
          'displayName': 'Alex Rivera',
          // Legacy public locations, still present on a doc that hasn't
          // fully migrated yet - the payout doc below must win.
          'phone': '011-000 0000',
        },
        payoutData: {'phone': '012-345 6789'},
      );
      expect(v?.phone, '012-345 6789');
    });

    test('PendingVerification falls back to the legacy public-doc fields '
        'when the private payout doc is missing (pre-migration applicant)', () {
      final requestor = PendingVerification.fromMap('req-1', {
        'role': 'requestor',
        'displayName': 'Jamie Lee',
        'phone': '019-888 7777',
      });
      expect(requestor?.phone, '019-888 7777');
    });
  });

  group('Review moderation & stats', () {
    test('Review parses moderation fields with safe defaults', () {
      final legacy = Review.fromMap('r1', {'rating': 4});
      expect(legacy.flagged, isFalse);
      expect(legacy.hidden, isFalse);
      expect(legacy.flagReason, isNull);

      final flagged = Review.fromMap('r2', {
        'rating': 1,
        'flagged': true,
        'flagReason': 'Never my client.',
        'hidden': true,
      });
      expect(flagged.flagged, isTrue);
      expect(flagged.hidden, isTrue);
      // Moderation state never travels back into a write.
      expect(flagged.toMap().containsKey('flagged'), isFalse);
      expect(flagged.toMap().containsKey('hidden'), isFalse);
    });

    testWidgets('owner reports a review from their profile', (tester) async {

      final review = FakeReviewRepository([
        Review(
          id: 'r1',
          reviewerId: 'someone',
          reviewerName: 'Sarah Connor',
          rating: 1,
          comment: 'Terrible.',
          createdAt: DateTime.now(),
        ),
      ]);
      await pumpApp(tester, buildApp(FakeAuthRepository(), review: review), size: const Size(500, 2200));
      await logIn(tester);

      await openTab(tester, 'Profile');

      // Report via the flag icon on the review.
      final flagIcon = find.byIcon(Icons.flag_outlined);
      await tester.ensureVisible(flagIcon);
      await tester.tap(flagIcon);
      await tester.pumpAndSettle();
      expect(find.text('Report this review?'), findsOneWidget);

      // The reason is required.
      final report = find.widgetWithText(FilledButton, 'Report');
      expect(tester.widget<FilledButton>(report).onPressed, isNull);
      await tester.enterText(
        find.byType(TextField).last,
        'This reviewer was never my client.',
      );
      await tester.pumpAndSettle();
      await tester.tap(report);
      await tester.pumpAndSettle();

      expect(review.flags, hasLength(1));
      expect(review.flags.single.$2, 'r1');
      expect(review.flags.single.$3, 'This reviewer was never my client.');
    });

    testWidgets('admin hides a flagged review from the Reviews tab', (
      tester,
    ) async {

      final moderation = FakeModerationRepository([
        FlaggedReview(
          revieweeId: 'prov-1',
          review: Review(
            id: 'r1',
            reviewerId: 'someone',
            reviewerName: 'Sarah Connor',
            rating: 1,
            comment: 'Terrible.',
            flagged: true,
            flagReason: 'Never my client.',
            createdAt: DateTime.now(),
          ),
        ),
      ]);
      final auth = FakeAuthRepository()..seedSignedIn(UserRole.admin);
      await pumpApp(tester, buildApp(auth, moderation: moderation), size: const Size(500, 1600));

      await tester.tap(find.text('Reviews'));
      await tester.pumpAndSettle();
      expect(find.text('Review Moderation'), findsOneWidget);
      expect(find.text('Sarah Connor'), findsOneWidget);
      expect(find.text('Never my client.'), findsOneWidget);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Hide'));
      await tester.pumpAndSettle();

      expect(moderation.rulings['r1'], isTrue);
      expect(find.text('Nothing to moderate'), findsOneWidget);
    });

    testWidgets('stats tab shows the aggregated platform numbers', (
      tester,
    ) async {

      final auth = FakeAuthRepository()..seedSignedIn(UserRole.admin);
      await pumpApp(tester, buildApp(auth), size: const Size(500, 1600));

      // The scrollable TabBar puts 'Stats' past the right edge in the wide
      // Ahem test font - bring it on-screen first.
      await tester.ensureVisible(find.text('Stats'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Stats'));
      await tester.pumpAndSettle();

      expect(find.text('Platform statistics'), findsOneWidget);
      expect(find.text('RM\u00A012,345.00'), findsOneWidget); // released volume
      expect(find.text('11'), findsOneWidget); // clients
      expect(find.text('12'), findsOneWidget); // providers
      expect(find.text('17'), findsOneWidget); // open disputes
      expect(find.text('23'), findsOneWidget); // total users
    });

    testWidgets('stats tab shows bundle award counts', (
      tester,
    ) async {

      final auth = FakeAuthRepository()..seedSignedIn(UserRole.admin);
      await pumpApp(tester, buildApp(auth), size: const Size(500, 1600));

      await tester.ensureVisible(find.text('Stats'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Stats'));
      await tester.pumpAndSettle();

      expect(find.text('Bundles'), findsOneWidget);
      expect(find.text('20'), findsOneWidget); // bundles awarded
      expect(find.text('5 (25%)'), findsOneWidget); // split awards
    });

    testWidgets('stats tab can trigger the Trust Score recompute', (
      tester,
    ) async {

      final auth = FakeAuthRepository()..seedSignedIn(UserRole.admin);
      final stats = FakeStatsRepository();
      await pumpApp(tester, buildApp(auth, stats: stats), size: const Size(500, 1600));

      await tester.ensureVisible(find.text('Stats'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Stats'));
      await tester.pumpAndSettle();

      final btn = find.widgetWithText(OutlinedButton, 'Recompute Trust Scores');
      await tester.ensureVisible(btn);
      await tester.tap(btn);
      await tester.pumpAndSettle();

      expect(stats.recomputeCalls, 1);
      expect(find.textContaining('Trust Scores recomputed'), findsOneWidget);
    });
  });

  group('Admin user suspension', () {
    testWidgets('admin suspends a user from the Users tab', (tester) async {

      final auth = FakeAuthRepository()..seedSignedIn(UserRole.admin);
      final users = FakeUserAdminRepository([
        const ManagedUser(
          uid: 'u-2',
          displayName: 'Bob Provider',
          email: 'bob@fairbid.app',
          role: 'provider',
          suspended: false,
        ),
      ]);
      await pumpApp(tester, buildApp(auth, userAdmin: users), size: const Size(500, 1600));

      // The Users tab is the last, scrollable-off-screen one in the wide test
      // font - bring it on-screen first (same as the Stats tab test).
      await tester.ensureVisible(find.text('Users'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Users'));
      await tester.pumpAndSettle();

      expect(find.text('Bob Provider'), findsOneWidget);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Suspend'));
      await tester.pumpAndSettle();

      // Confirm sheet: enter a reason and confirm.
      await tester.enterText(
        find.widgetWithText(TextField, 'Reason (optional)'),
        'Spam bids',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Suspend'));
      await tester.pumpAndSettle();

      expect(users.calls, hasLength(1));
      expect(users.calls.first.uid, 'u-2');
      expect(users.calls.first.suspended, isTrue);
      expect(users.calls.first.reason, 'Spam bids');
      // The list re-renders: the user now shows the Suspended pill and the
      // action flips to Reinstate.
      expect(find.text('Suspended'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Reinstate'), findsOneWidget);
    });

    testWidgets('admin resets a lost authenticator from the Users tab', (
      tester,
    ) async {

      final auth = FakeAuthRepository()..seedSignedIn(UserRole.admin);
      final users = FakeUserAdminRepository([
        const ManagedUser(
          uid: 'u-2',
          displayName: 'Bob Provider',
          email: 'bob@fairbid.app',
          role: 'provider',
          suspended: false,
        ),
      ]);
      await pumpApp(tester, buildApp(auth, userAdmin: users), size: const Size(500, 1600));

      await tester.ensureVisible(find.text('Users'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Users'));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reset two-factor'));
      await tester.pumpAndSettle();

      expect(find.text('Reset two-factor for Bob Provider?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Reset'));
      await tester.pumpAndSettle();

      expect(users.mfaClears, ['u-2']);
      expect(find.text('Two-factor authentication reset.'), findsOneWidget);
    });

    testWidgets('a suspended user is locked to the suspended screen', (
      tester,
    ) async {
      final auth = FakeAuthRepository()
        ..suspended = true
        ..suspensionReason = 'Repeated policy violations'
        ..seedSignedIn(UserRole.requestor);
      await pumpApp(tester, buildApp(auth));

      expect(find.text('Account suspended'), findsOneWidget);
      expect(find.textContaining('Repeated policy violations'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Sign Out'), findsOneWidget);
    });
  });
}
