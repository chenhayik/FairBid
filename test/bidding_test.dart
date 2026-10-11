import 'dart:convert';
import 'dart:io';

import 'package:fairbid/core/config/platform_config.dart';
import 'package:fairbid/features/auth/domain/app_user.dart';
import 'package:fairbid/features/auth/domain/user_role.dart';
import 'package:fairbid/features/jobs/data/job_repository.dart';
import 'package:fairbid/features/jobs/presentation/bid/submit_bid_sheet.dart';
import 'package:fairbid/features/jobs/domain/bid.dart';
import 'package:fairbid/features/jobs/domain/job.dart';
import 'package:fairbid/features/jobs/presentation/widgets/bid_card.dart';
import 'package:fairbid/features/profile/domain/public_profile.dart';
import 'package:fairbid/features/profile/presentation/public_profile_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/builders.dart';
import 'helpers/fakes.dart';
import 'helpers/harness.dart';

void main() {
  group('Jobs', () {
    test('Job round-trips through toMap/fromMap', () {
      final job = sampleJob();
      final map = {
        ...job.toMap(),
        'status': 'open',
        'bidCount': 3,
        'createdAt': null,
      };
      final parsed = Job.fromMap('job-1', map);
      expect(parsed.title, 'Fix leaking sink');
      expect(parsed.category, 'Plumbing');
      expect(parsed.location.address, 'Bangsar, KL');
      expect(parsed.budget?.minSen, 10000);
      expect(parsed.bidCount, 3);
    });

  });

  group('Bidding', () {
    test('Bid round-trips through toMap/fromMap', () {
      final bid = sampleBid();
      final map = {...bid.toMap(), 'status': 'pending', 'createdAt': null};
      final parsed = Bid.fromMap('job-1', 'prov-1', map);
      expect(parsed.providerName, 'Pro Fixer');
      expect(parsed.providerTrustScore, 800);
      expect(parsed.amountSen, 15000);
      expect(parsed.estimatedDuration, 'Less than 1 week');
      expect(parsed.status, BidStatus.pending);
    });

    /// Registers as a provider and opens the seeded job's detail screen.
    Future<void> openJobAsProvider(WidgetTester tester) async {
      await openRegisterAs(tester, 'Work');
      await tester.tap(find.text('Fix leaking sink').first);
      await tester.pumpAndSettle();
      expect(find.text('Job details'), findsOneWidget);
    }

    testWidgets('approved provider submits a bid (with form validation)', (
      tester,
    ) async {

      final auth = FakeAuthRepository()
        ..verificationStatus = 'approved'
        ..baseLat = 3.139
        ..baseLng = 101.6869;
      // Someone else's job, so the provider section (not bids) is shown.
      await pumpApp(tester, buildApp(auth, jobs: [sampleJob(requestorId: 'req-9')]), size: const Size(500, 1600));
      await openJobAsProvider(tester);

      // Open the sheet and submit empty → validation errors. "Submit a bid"
      // is the pinned bottom bar's button; the bids slot doesn't repeat it.
      expect(find.widgetWithText(FilledButton, 'Submit a bid'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Submit a bid'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Submit bid'));
      await tester.pumpAndSettle();
      expect(find.text('Enter your bid amount.'), findsOneWidget);
      expect(find.text('Pick a duration.'), findsOneWidget);
      expect(find.text('Message is required.'), findsOneWidget);

      // Fill the form and submit.
      await fillField(tester, 'Your bid (RM)', '150');
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Less than 1 week').last);
      await tester.pumpAndSettle();
      await fillField(tester, 'Proposal message', 'I can start tomorrow.');
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Submit bid'));
      await tester.pumpAndSettle();

      // Sheet closed; the detail now shows the live bid with Withdraw (the
      // bid card's own secondary action - the bottom bar doesn't offer it).
      expect(find.text('Your bid'), findsOneWidget);
      expect(find.text('RM\u00A0150.00'), findsOneWidget);
      expect(
        find.widgetWithText(OutlinedButton, 'Withdraw bid'),
        findsOneWidget,
      );

      // Withdrawing (after confirming the dialog) returns to the submit state.
      await tester.tap(find.widgetWithText(OutlinedButton, 'Withdraw bid'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Withdraw'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(FilledButton, 'Submit a bid'), findsOneWidget);
    });

    testWidgets('pending provider sees the locked state', (tester) async {

      final auth = FakeAuthRepository()
        ..verificationStatus = 'pending'
        ..baseLat = 3.139
        ..baseLng = 101.6869;
      await pumpApp(tester, buildApp(auth, jobs: [sampleJob(requestorId: 'req-9')]), size: const Size(500, 1600));
      await openJobAsProvider(tester);

      expect(find.text('Bidding locked'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Submit a bid'), findsNothing);
    });

    testWidgets('approved provider sees "Bidding closed" once the deadline has '
        'passed', (tester) async {

      final auth = FakeAuthRepository()
        ..verificationStatus = 'approved'
        ..baseLat = 3.139
        ..baseLng = 101.6869;
      final job = sampleJob(
        requestorId: 'req-9',
        deadline: DateTime.now().subtract(const Duration(hours: 1)),
      );
      await pumpApp(tester, buildApp(auth, jobs: [job]), size: const Size(500, 1600));
      await openJobAsProvider(tester);

      // "Bidding closed" also appears as the job's own deadline info row, so
      // assert on the locked-state banner's more specific body text.
      expect(find.text('Bidding for this job has closed.'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Submit a bid'), findsNothing);
    });

    testWidgets('requestor sees a bid and accepting flips the job to '
        'in progress', (tester) async {

      // Enough available balance to cover the RM 150 bid (see FakeBidRepository
      // .acceptBid's balance gate, mirroring the acceptBid Cloud Function).
      final auth = FakeAuthRepository()..walletBalanceSen = 20000;
      await pumpApp(tester, buildApp(auth, jobs: [sampleJob()], bids: [sampleBid()]), size: const Size(500, 1600));
      await logIn(tester);

      // Open own job → the bid list shows the provider's offer.
      await tester.tap(find.text('Fix leaking sink').first);
      await tester.pumpAndSettle();
      expect(find.text('Pro Fixer'), findsOneWidget);
      expect(find.text('RM\u00A0150.00'), findsOneWidget);

      // Accept → confirm in the dialog.
      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'Accept bid'),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Accept bid'));
      await tester.pumpAndSettle();
      expect(find.text('Accept this bid?'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(FilledButton, 'Accept bid'),
        ),
      );
      await tester.pumpAndSettle();

      // The job is now in progress with the winner shown.
      expect(find.text('In progress'), findsOneWidget);
      expect(find.text('Assigned provider'), findsOneWidget);
      expect(find.text('Pro Fixer'), findsOneWidget);
    });

    testWidgets('after a bid it says Edit bid and updates the bid', (
      tester,
    ) async {
      final auth = FakeAuthRepository()
        ..verificationStatus = 'approved'
        ..baseLat = 3.139
        ..baseLng = 101.6869;
      await pumpApp(
        tester,
        buildApp(
          auth,
          jobs: [sampleJob(requestorId: 'req-9')],
          bids: [sampleBid(providerId: 'uid-1', amountSen: 15000)],
        ),
        size: const Size(500, 1600),
      );
      await openRegisterAs(tester, 'Work');
      await tester.tap(find.text('Fix leaking sink').first);
      await tester.pumpAndSettle();

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
      expect(find.text('RM\u00A0200.00'), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------
  // Licensing notice (docs/BUNDLE_BIDDING.md "Licensing"): shown on any job's
  // detail screen when its category needs one.
  // -------------------------------------------------------------------------
  group('Licence notice', () {
    Future<void> openOwnJob(WidgetTester tester, {required String category}) async {
      final auth = FakeAuthRepository()..seedSignedIn(UserRole.requestor);
      await pumpApp(tester, buildApp(auth, jobs: [sampleJob(title: 'A task', category: category)]), size: const Size(500, 1600));
      await openTab(tester, 'My jobs');
      await tester.tap(find.text('A task'));
      await tester.pumpAndSettle();
    }

    testWidgets('shows on an Electrical job', (tester) async {
      await openOwnJob(tester, category: 'Electrical');
      expect(find.text('Licensing'), findsOneWidget);
      expect(find.textContaining('Energy Commission-registered contractor'),
          findsOneWidget);
    });

    testWidgets('does not show on a Cleaning job', (tester) async {
      await openOwnJob(tester, category: 'Cleaning');
      expect(find.text('Licensing'), findsNothing);
    });
  });

  group('Watchlist', () {
    testWidgets('bookmarking a job on the feed toggles its saved state', (
      tester,
    ) async {

      final auth = FakeAuthRepository()..verificationStatus = 'approved';
      await pumpApp(tester, buildApp(auth, jobs: [sampleJob(requestorId: 'req-9')]), size: const Size(500, 1600));
      await openRegisterAs(tester, 'Work');

      // Into the full "Find Jobs" feed, where the bookmark toggle lives.
      await tester.tap(find.text('View all'));
      await tester.pumpAndSettle();

      // Scoped to the job list - the feed's AppBar has its own (separate)
      // bookmark_border icon that opens the Saved Jobs screen.
      final list = find.byType(ListView);
      Finder cardBookmark(IconData icon) =>
          find.descendant(of: list, matching: find.byIcon(icon));

      expect(cardBookmark(Icons.bookmark_border), findsOneWidget);
      await tester.tap(cardBookmark(Icons.bookmark_border));
      await tester.pumpAndSettle();

      expect(cardBookmark(Icons.bookmark), findsOneWidget);
      expect(auth.watchlist, contains('job-1'));

      // Tapping again unsaves it.
      await tester.tap(cardBookmark(Icons.bookmark));
      await tester.pumpAndSettle();
      expect(cardBookmark(Icons.bookmark_border), findsOneWidget);
      expect(auth.watchlist, isEmpty);
    });
  });

  group('Wallet balance gate on bid acceptance', () {
    test('AppUser.availableBalanceSen subtracts locked escrow', () {
      const user = AppUser(
        uid: 'uid-1',
        email: 'a@b.com',
        displayName: 'Test User',
        role: UserRole.requestor,
        walletBalanceSen: 50000,
        escrowLockedSen: 20000,
      );
      expect(user.availableBalanceSen, 30000);
    });

    testWidgets(
      'accepting a bid over the available balance shows a top-up dialog',
      (tester) async {

        // RM 100 available, but the sample bid is RM 150 - RM 50 short.
        final auth = FakeAuthRepository()..walletBalanceSen = 10000;
        await pumpApp(tester, buildApp(auth, jobs: [sampleJob()], bids: [sampleBid()]), size: const Size(500, 1600));
        await logIn(tester);

        await tester.tap(find.text('Fix leaking sink').first);
        await tester.pumpAndSettle();

        await tester.ensureVisible(
          find.widgetWithText(FilledButton, 'Accept bid'),
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Accept bid'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.widgetWithText(FilledButton, 'Accept bid'),
          ),
        );
        await tester.pumpAndSettle();

        // The gate blocked the accept and surfaced the shortfall.
        expect(find.text('Not enough balance'), findsOneWidget);
        expect(find.textContaining('RM\u00A050.00 more available'), findsOneWidget);
        expect(find.widgetWithText(FilledButton, 'Top up'), findsOneWidget);
        expect(find.text('In progress'), findsNothing);

        // Top up routes to the wallet screen.
        await tester.tap(find.widgetWithText(FilledButton, 'Top up'));
        await tester.pumpAndSettle();
        expect(find.text('My wallet'), findsOneWidget);
      },
    );
  });

  group('Trust Score', () {
    // The shared vectors that also pin functions/index.js (`npm test`): if the
    // Dart and JS formulas ever drift, one of the two suites fails.
    final vectors =
        (jsonDecode(File('test/fixtures/trust_vectors.json').readAsStringSync())
                as Map<String, dynamic>)['vectors']
            as List;
    for (final raw in vectors) {
      final v = raw as Map<String, dynamic>;
      test('v2 breakdown vector: ${v['name']}', () {
        final b = PlatformConfig.trustBreakdownFor(
          ratingSum: v['ratingSum'] as int,
          ratingCount: v['ratingCount'] as int,
          verificationStatus: v['verificationStatus'] as String,
          jobsCompleted: v['jobsCompleted'] as int,
          disputesLost: v['disputesLost'] as int,
          hasDisplayName: v['hasDisplayName'] as bool,
          hasPhone: v['hasPhone'] as bool,
          hasBio: v['hasBio'] as bool,
          hasPhoto: v['hasPhoto'] as bool,
          hasLocation: v['hasLocation'] as bool,
        );
        final e = v['expected'] as Map<String, dynamic>;
        expect(b.reviewScore, e['reviewScore']);
        expect(b.trackRecordScore, e['trackRecordScore']);
        expect(b.verificationScore, e['verificationScore']);
        expect(b.profileScore, e['profileScore']);
        expect(b.composite, e['composite']);
        expect(b.scoreVisible, e['scoreVisible']);
      });
    }

  });

  group('Best Value ranking', () {
    // Cheapest vs a pricier but far more trusted bid. Composites (§3.2.3):
    //   Cheap Charlie: 0.6*(100/100) + 0.4*0.30 = 0.72
    //   Trusty Tina:   0.6*(100/120) + 0.4*0.95 = 0.88  → Best Value
    List<Bid> valueBids() => [
      sampleBid(
        providerId: 'p-cheap',
        providerName: 'Cheap Charlie',
        amountSen: 10000,
        trustScore: 300,
      ),
      sampleBid(
        providerId: 'p-trust',
        providerName: 'Trusty Tina',
        amountSen: 12000,
        trustScore: 950,
      ),
    ];

    Future<void> openOwnJob(WidgetTester tester) async {
      await logIn(tester);
      await tester.tap(find.text('Fix leaking sink').first);
      await tester.pumpAndSettle();
    }

    testWidgets('defaults to composite order and badges the top bid', (
      tester,
    ) async {

      await pumpApp(tester, buildApp(FakeAuthRepository(), jobs: [sampleJob()], bids: valueBids()), size: const Size(500, 1600));
      await openOwnJob(tester);

      // Two sort options; hidden scores make a Trust sort misleading.
      expect(find.text('Best'), findsOneWidget);
      expect(find.text('Price'), findsOneWidget);
      expect(find.text('Trust'), findsNothing);

      // Exactly one badge, on the composite winner, which sorts first.
      expect(find.text('BEST VALUE'), findsOneWidget);
      final firstCard = find.byType(BidCard).first;
      expect(
        find.descendant(of: firstCard, matching: find.text('Trusty Tina')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: firstCard, matching: find.text('BEST VALUE')),
        findsOneWidget,
      );
    });

    testWidgets('the Compare button opens a side-by-side table of bids', (
      tester,
    ) async {

      await pumpApp(tester, buildApp(FakeAuthRepository(), jobs: [sampleJob(bidCount: 2)], bids: valueBids()), size: const Size(500, 1600));
      await openOwnJob(tester);

      await tester.tap(find.widgetWithText(FilledButton, 'Compare 2 bids'));
      await tester.pumpAndSettle();

      final table = find.byType(DataTable);
      expect(find.text('Compare 2 bids'), findsWidgets);
      expect(table, findsOneWidget);
      expect(find.descendant(of: table, matching: find.text('Cheap Charlie')),
          findsOneWidget);
      expect(find.descendant(of: table, matching: find.text('Trusty Tina')),
          findsOneWidget);

      // Picking a row starts that bid's accept.
      await tester.tap(
          find.descendant(of: table, matching: find.text('Cheap Charlie')));
      await tester.pumpAndSettle();
      expect(find.text('Accept this bid?'), findsOneWidget);
    });

    testWidgets('hidden "New" scores never decide the ranking', (tester) async {

      // Both scores are hidden, so both count as the same baseline and the
      // cheaper bid wins despite its lower hidden score.
      await pumpApp(tester, buildApp(
        FakeAuthRepository(),
        jobs: [sampleJob(bidCount: 2)],
        bids: [
          sampleBid(
            providerId: 'p-a',
            providerName: 'Pricey Pat',
            amountSen: 12000,
            trustScore: 990,
            scoreVisible: false,
          ),
          sampleBid(
            providerId: 'p-b',
            providerName: 'Cheap Chris',
            amountSen: 10000,
            trustScore: 100,
            scoreVisible: false,
          ),
        ],
      ), size: const Size(500, 1600));
      await openOwnJob(tester);

      expect(
        find.descendant(
          of: find.byType(BidCard).first,
          matching: find.text('Cheap Chris'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('re-sorting by Price reorders but keeps the badge fixed', (
      tester,
    ) async {

      await pumpApp(tester, buildApp(FakeAuthRepository(), jobs: [sampleJob()], bids: valueBids()), size: const Size(500, 1600));
      await openOwnJob(tester);

      await tester.tap(find.text('Price'));
      await tester.pumpAndSettle();

      // Cheapest sorts first now, but the badge stays on the value winner.
      expect(
        find.descendant(
          of: find.byType(BidCard).first,
          matching: find.text('Cheap Charlie'),
        ),
        findsOneWidget,
      );
      expect(find.text('BEST VALUE'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(BidCard).last,
          matching: find.text('BEST VALUE'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a bid from a new provider shows a New badge, not a score', (
      tester,
    ) async {

      await pumpApp(tester, buildApp(
          FakeAuthRepository(),
          jobs: [sampleJob()],
          bids: [sampleBid(scoreVisible: false)],
        ), size: const Size(500, 1600));
      await openOwnJob(tester);

      expect(find.text('New provider, no score yet'), findsOneWidget);
      expect(find.textContaining('Trust Score'), findsNothing);
      // Still rankable / acceptable - the internal score just isn't surfaced.
      expect(find.widgetWithText(FilledButton, 'Accept bid'), findsOneWidget);
    });

    testWidgets("tapping a bid card's identity row opens the provider's public "
        'profile', (tester) async {

      final publicProfile = FakePublicProfileRepository({
        'p-trust': PublicProfile(
          uid: 'p-trust',
          displayName: 'Trusty Tina',
          role: UserRole.provider,
          bio: 'Reliable and fast.',
        ),
      });
      await pumpApp(tester, buildApp(
          FakeAuthRepository(),
          jobs: [sampleJob()],
          bids: valueBids(),
          publicProfile: publicProfile,
        ), size: const Size(500, 1600));
      await openOwnJob(tester);

      await tester.tap(find.text('Trusty Tina'));
      await tester.pumpAndSettle();

      expect(find.byType(PublicProfileScreen), findsOneWidget);
      expect(find.text('Reliable and fast.'), findsOneWidget);
      // Private fields never render, even though nothing in this profile
      // sets them (the model has no field for them at all).
      expect(find.textContaining('@'), findsNothing);
    });
  });

  group('Saved Jobs covers the whole watchlist', () {
    // Firestore's whereIn caps at 30 values. Saved Jobs used to `take(30)`,
    // so a user who bookmarked a 31st job never saw it again - silently, with
    // nothing in the UI to explain the gap. These pin the chunking that
    // replaced it. (The repository itself needs a live Firestore and so
    // cannot be unit-tested; this covers the arithmetic that carried the bug.)
    test('a 35-id watchlist is split into chunks that lose nothing', () {
      final ids = [for (var i = 0; i < 35; i++) 'job-$i'];
      final chunks = chunkForWhereIn(ids);

      expect(chunks.length, 2);
      expect(chunks[0].length, 30);
      expect(chunks[1].length, 5);
      // The bug was losing ids, so assert on coverage, not just on counts.
      expect(chunks.expand((c) => c).toList(), ids);
    });

    test('never exceeds the whereIn limit, at any size', () {
      for (final size in [1, 29, 30, 31, 60, 61, 200]) {
        final ids = [for (var i = 0; i < size; i++) 'job-$i'];
        final chunks = chunkForWhereIn(ids);
        expect(
          chunks.every((c) => c.length <= kWhereInLimit && c.isNotEmpty),
          isTrue,
          reason: 'a $size-id watchlist produced an invalid chunk',
        );
        expect(
          chunks.expand((c) => c).length,
          size,
          reason: 'a $size-id watchlist lost or duplicated ids',
        );
      }
    });

    test('an empty watchlist produces no queries', () {
      expect(chunkForWhereIn(const []), isEmpty);
    });
  });

  group('Best Value uses live trust, not the bid snapshot', () {
    // The stored scores would rank Cheap Charlie first; the providers' current
    // scores are the reverse. Ranking must follow the live numbers, otherwise
    // Best Value orders today's bids by last week's reputation while each
    // provider's own profile shows something different.
    //
    //   stored: Charlie 950 -> 0.6*1.000 + 0.4*0.95 = 0.98  (would win)
    //   live:   Charlie 300 -> 0.6*1.000 + 0.4*0.30 = 0.72
    //           Tina    950 -> 0.6*0.833 + 0.4*0.95 = 0.88  -> wins
    testWidgets('ranks on the provider\'s current score', (tester) async {

      final publicProfile = FakePublicProfileRepository({
        'p-cheap': PublicProfile(
          uid: 'p-cheap',
          displayName: 'Cheap Charlie',
          role: UserRole.provider,
          trustScore: 300, // dropped since bidding
          trustBreakdown: TrustBreakdown(
            reviewScore: 0,
            trackRecordScore: 0,
            verificationScore: 0,
            profileScore: 0,
            composite: 0,
            scoreVisible: true,
          ),
        ),
        'p-trust': PublicProfile(
          uid: 'p-trust',
          displayName: 'Trusty Tina',
          role: UserRole.provider,
          trustScore: 950, // climbed since bidding
          trustBreakdown: TrustBreakdown(
            reviewScore: 0,
            trackRecordScore: 0,
            verificationScore: 0,
            profileScore: 0,
            composite: 0,
            scoreVisible: true,
          ),
        ),
      });

      await pumpApp(tester, buildApp(
          FakeAuthRepository(),
          jobs: [sampleJob()],
          bids: [
            sampleBid(
              providerId: 'p-cheap',
              providerName: 'Cheap Charlie',
              amountSen: 10000,
              trustScore: 950, // stale snapshot on the bid
            ),
            sampleBid(
              providerId: 'p-trust',
              providerName: 'Trusty Tina',
              amountSen: 12000,
              trustScore: 300, // stale snapshot on the bid
            ),
          ],
          publicProfile: publicProfile,
        ), size: const Size(500, 1600));
      await logIn(tester);
      await tester.tap(find.text('Fix leaking sink').first);
      await tester.pumpAndSettle();

      final firstCard = find.byType(BidCard).first;
      expect(
        find.descendant(of: firstCard, matching: find.text('Trusty Tina')),
        findsOneWidget,
        reason: 'live trust should decide the order, not the bid snapshot',
      );
      expect(
        find.descendant(of: firstCard, matching: find.text('BEST VALUE')),
        findsOneWidget,
      );
    });
  });
}
