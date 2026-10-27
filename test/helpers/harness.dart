import 'package:fairbid/core/app.dart';
import 'package:fairbid/features/jobs/domain/bid.dart';
import 'package:fairbid/features/jobs/domain/job.dart';
import 'package:fairbid/features/jobs/domain/milestone.dart';
import 'package:fairbid/features/profile/domain/review.dart';
import 'package:fairbid/features/auth/domain/user_role.dart';
import 'package:fairbid/core/theme/app_theme.dart';
import 'package:fairbid/features/auth/presentation/auth_controller.dart';
import 'package:fairbid/features/jobs/data/bundle_bid_repository.dart';
import 'package:fairbid/features/jobs/data/bundle_repository.dart';
import 'package:fairbid/features/jobs/data/job_repository.dart';
import 'package:fairbid/features/jobs/presentation/bundle/bundle_detail_screen.dart';
import 'package:fairbid/features/profile/data/public_profile_repository.dart';
import 'package:provider/provider.dart';
import 'package:fairbid/features/auth/domain/app_user.dart';
import 'package:fairbid/features/jobs/domain/bundle.dart';
import 'package:fairbid/features/jobs/domain/bundle_bid.dart';
import 'package:fairbid/features/jobs/presentation/bid/submit_bundle_bid_controller.dart';
import 'package:fairbid/features/jobs/presentation/bid/submit_bundle_bid_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'builders.dart';
import 'fakes.dart';

/// What:   The whole app wired to in-memory fakes.
/// Input:  [auth] plus optional seed data ([jobs], [bids], [reviews], [milestones]) or a replacement fake per repository.
/// Output: A FairBidApp to hand to pumpApp().
Widget buildApp(
  FakeAuthRepository auth, {
  List<Job> jobs = const [],
  List<Bid> bids = const [],
  List<Review> reviews = const [],
  List<Milestone> milestones = const [],
  FakeJobRepository? jobRepository,
  FakeReviewRepository? review,
  FakePublicProfileRepository? publicProfile,
  FakeUserReportRepository? userReport,
  FakeVerificationRepository? verification,
  FakeChatRepository? chat,
  FakeDisputeRepository? dispute,
  FakeModerationRepository? moderation,
  FakeStatsRepository? stats,
  FakeNotificationRepository? notifications,
  FakeUserAdminRepository? userAdmin,
  FakeAssistRepository? assist,
  FakeBundleRepository? bundle,
  FakeBundleBidRepository? bundleBid,
  FakeMilestoneRepository? milestoneRepository,
  FakeWalletRepository? wallet,
}) {
  final jobRepo = jobRepository ?? FakeJobRepository(jobs);
  final milestoneRepo =
      milestoneRepository ?? FakeMilestoneRepository(jobRepo, milestones);
  final disputeRepo = dispute ?? FakeDisputeRepository();
  disputeRepo.milestones ??= milestoneRepo;
  return FairBidApp(
    authRepository: auth,
    onboardingRepository: FakeOnboardingRepository(auth),
    requestorOnboardingRepository: FakeRequestorOnboardingRepository(auth),
    documentStorageRepository: FakeDocumentStorageRepository(),
    jobRepository: jobRepo,
    bidRepository: FakeBidRepository(jobRepo, auth, bids),
    reviewRepository: review ?? FakeReviewRepository(reviews),
    publicProfileRepository: publicProfile ?? FakePublicProfileRepository(),
    userReportRepository: userReport ?? FakeUserReportRepository(),
    verificationRepository: verification ?? FakeVerificationRepository(),
    userAdminRepository: userAdmin ?? FakeUserAdminRepository(),
    chatRepository: chat ?? FakeChatRepository(),
    milestoneRepository: milestoneRepo,
    walletRepository: wallet ?? FakeWalletRepository(),
    disputeRepository: disputeRepo,
    moderationRepository: moderation ?? FakeModerationRepository(),
    statsRepository: stats ?? FakeStatsRepository(),
    notificationRepository: notifications ?? FakeNotificationRepository(),
    pushService: FakePushService(),
    assistRepository: assist ?? FakeAssistRepository(),
    bundleRepository: bundle ?? FakeBundleRepository(),
    bundleBidRepository: bundleBid ?? FakeBundleBidRepository(),
  );
}

/// What:   Types [text] into the form field labelled [label].
/// Input:  [tester]; [label] shown above or inside the field; [text] to enter.
/// Output: The field filled; it is scrolled into view first.
Future<void> fillField(WidgetTester tester, String label, String text) async {
  // Field labels are external; find the TextFormField below the label text.
  final direct = find.widgetWithText(TextFormField, label);
  final field = direct.evaluate().isEmpty
      ? _fieldBelowLabel(tester, label)
      : direct;
  await tester.ensureVisible(field); // scroll into view on tall forms
  await tester.pumpAndSettle();
  await tester.enterText(field, text);
}

Finder _fieldBelowLabel(WidgetTester tester, String label) {
  // Fields render label + TextFormField inside one AppTextField column.
  final column = find.ancestor(
    of: find.text(label),
    matching: find.byType(Column),
  );
  return find
      .descendant(of: column.first, matching: find.byType(TextFormField))
      .first;
}

/// What:   Picks a district in the Penang location picker opened from a `LocationField`.
/// Input:  [placeholder] shown by the field; [districtLabel] to select in the District dropdown.
/// Output: The picker confirmed and closed.
/// Notes:  Avoids `pumpAndSettle` while the map is up; its tile layer would never settle.
Future<void> pickPenangLocation(
  WidgetTester tester, {
  required String placeholder,
  String districtLabel = 'Barat Daya',
}) async {
  await tester.tap(find.text(placeholder));
  await tester.pump(const Duration(milliseconds: 400)); // push transition
  await tester.pump(const Duration(milliseconds: 200)); // ensureLoaded()

  // The default map centre (George Town) already auto-classifies into a
  // district by this point, so the field may show its name instead of the
  // "Select a district..." hint - and when the picker is pushed on top of a
  // screen that has its own dropdown (e.g. ServiceStep's category picker),
  // that earlier dropdown is still mounted (just behind the new route), so
  // `.first` in tree order can't be trusted either. Target the District
  // dropdown via its label instead.
  await tester.tap(districtDropdown());
  await tester.pump(const Duration(milliseconds: 400)); // menu opens
  await tester.tap(find.text(districtLabel).last);
  await tester.pump(
    const Duration(milliseconds: 400),
  ); // menu closes + recentre

  await tester.tap(find.widgetWithText(FilledButton, 'Use this location'));
  await tester.pump(const Duration(milliseconds: 400)); // pop transition
  await tester.pumpAndSettle();
}

/// What:   Finds the District dropdown of the region picker.
/// Input:  None; matches through the "District" label, as other dropdowns may be mounted underneath.
/// Output: A Finder for that dropdown.
Finder districtDropdown() {
  final column = find.ancestor(
    of: find.text('District'),
    matching: find.byType(Column),
  );
  return find
      .descendant(
        of: column.first,
        matching: find.byType(DropdownButtonFormField<String>),
      )
      .first;
}


/// What:   Registers a new account from the login screen.
/// Input:  [roleLabel] 'Hire' or 'Work'; the form is filled with `new@fairbid.app`.
/// Output: A signed-in user of that role, settled.
Future<void> openRegisterAs(WidgetTester tester, String roleLabel) async {
  await tester.tap(find.text('Sign Up'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(roleLabel));
  await tester.pumpAndSettle();
  await fillField(tester, 'FULL NAME', 'New User');
  await fillField(tester, 'EMAIL ADDRESS', 'new@fairbid.app');
  await fillField(tester, 'PASSWORD', 'secret123');
  await fillField(tester, 'CONFIRM PASSWORD', 'secret123');
  final checkbox = find.byType(Checkbox);
  await tester.ensureVisible(checkbox);
  await tester.tap(checkbox);
  await tester.pumpAndSettle();
  final button = find.widgetWithText(FilledButton, 'Sign Up');
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

/// What:   Pumps [app] and settles, optionally on a custom screen [size].
/// Input:  [tester]; [app] usually from buildApp(); [size] for tall or narrow layouts.
/// Output: The app on screen; the surface size is reset when the test ends.
Future<void> pumpApp(WidgetTester tester, Widget app, {Size? size}) async {
  if (size != null) {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }
  await tester.pumpWidget(app);
  await tester.pumpAndSettle();
}

/// What:   Logs in from the login screen with the fake auth's test account.
/// Input:  [tester] showing the login screen.
/// Output: Signed-in state, settled.
Future<void> logIn(WidgetTester tester) async {
  await fillField(tester, 'Email', 'test@fairbid.app');
  await fillField(tester, 'Password', 'secret123');
  await tester.tap(find.widgetWithText(FilledButton, 'Log In'));
  await tester.pumpAndSettle();
}

/// What:   Taps a bottom-navigation tab.
/// Input:  [tester]; [label] such as 'Home', 'My jobs', 'Messages', 'Profile'.
/// Output: The tab's screen, settled.
Future<void> openTab(WidgetTester tester, String label) async {
  await tester.tap(
    find.descendant(
      of: find.byType(NavigationBar),
      matching: find.text(label),
    ),
  );
  await tester.pumpAndSettle();
}

/// What:   Opens `/jobs/{job.id}` on a phone-sized screen as the job's owner or its provider.
/// Input:  [job]; [owner] picks the signed-in role; [milestones] seed the escrow steps;
///         [milestoneRepo] swaps the milestone fake; [extra] jobs share the repository; [textScale] zooms text.
/// Output: The job repository; layout overflows are ignored since the test font is wider than a real one.
Future<FakeJobRepository> pumpJobDetail(
  WidgetTester tester,
  Job job, {
  required bool owner,
  List<Milestone> milestones = const [],
  FakeMilestoneRepository Function(FakeJobRepository, List<Milestone>)?
  milestoneRepo,
  List<Job> extra = const [],
  double height = 780,
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = Size(360, height) * 2;
  tester.view.devicePixelRatio = 2;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final onError = FlutterError.onError;
  FlutterError.onError = (details) {
    if (!details.exceptionAsString().contains('overflowed')) {
      onError?.call(details);
    }
  };
  addTearDown(() => FlutterError.onError = onError);

  // Providers must be verified, or the app routes them to onboarding.
  final auth = FakeAuthRepository()
    ..verificationStatus = 'approved'
    ..seedSignedIn(owner ? UserRole.requestor : UserRole.provider);
  final jobs = FakeJobRepository([job, ...extra]);
  await pumpApp(
    tester,
    buildApp(
      auth,
      jobRepository: jobs,
      milestoneRepository:
          milestoneRepo?.call(jobs, milestones) ??
          FakeMilestoneRepository(jobs, milestones),
    ),
  );
  GoRouter.of(
    tester.element(find.byType(Scaffold).first),
  ).push<void>('/jobs/${job.id}');
  await tester.pumpAndSettle();
  return jobs;
}

/// What:   Pumps the bundle screen as the bundle owner (`uid-1`), reached the way the app does.
/// Input:  [bundles], [tasks] and [bundleBids] are the fakes behind the screen; [size] is the screen.
/// Output: BundleDetailScreen pushed over a root route, so pop and task/profile pushes have somewhere to go.
Future<void> pumpOwnerBundleScreen(
  WidgetTester tester, {
  required FakeBundleRepository bundles,
  required List<Job> tasks,
  required BundleBidRepository bundleBids,
  Size size = const Size(800, 1600),
}) async {
  final router = GoRouter(
    initialLocation: '/bundle',
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const Scaffold(body: SizedBox()),
        routes: [
          GoRoute(
            path: 'bundle',
            builder: (context, state) => MultiProvider(
              providers: [
                Provider<BundleRepository>.value(value: bundles),
                Provider<JobRepository>.value(value: FakeJobRepository(tasks)),
                Provider<BundleBidRepository>.value(value: bundleBids),
                Provider<PublicProfileRepository>.value(
                  value: FakePublicProfileRepository(),
                ),
                ChangeNotifierProvider<AuthController>(
                  create: (_) => AuthController(
                    FakeAuthRepository()..seedSignedIn(UserRole.requestor),
                  ),
                ),
              ],
              child: const BundleDetailScreen(bundleId: 'b1'),
            ),
          ),
        ],
      ),
      GoRoute(
        path: '/jobs/:id',
        builder: (context, state) =>
            Scaffold(body: Text('Job detail: ${state.pathParameters['id']}')),
      ),
      GoRoute(
        path: '/users/:uid',
        builder: (context, state) =>
            Scaffold(body: Text('Profile: ${state.pathParameters['uid']}')),
      ),
    ],
  );
  await pumpApp(
    tester,
    MaterialApp.router(theme: AppTheme.light, routerConfig: router),
    size: size,
  );
}

/// What:   Taps something that may be below the fold of a tall sheet or form.
/// Input:  [tester]; [finder] of the widget to tap.
/// Output: The tap done and the UI settled.
Future<void> tapAt(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// What:   Pumps the bundle bid sheet on its own, as provider `prov-1`; it is a form, so it needs no router.
/// Input:  [tasks] the sheet prices; [bundleBids] fake to record the submit; [existing] bid to edit; [bundle] override.
/// Output: The fake bundle-bid repository behind the sheet.
Future<FakeBundleBidRepository> pumpBundleBidSheet(
  WidgetTester tester, {
  required List<Job> tasks,
  FakeBundleBidRepository? bundleBids,
  BundleBid? existing,
  Bundle? bundle,
}) async {
  final repo = bundleBids ?? FakeBundleBidRepository();
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      home: ChangeNotifierProvider(
        create: (_) => SubmitBundleBidController(repo),
        child: Scaffold(
          body: SubmitBundleBidSheet(
            bundle:
                bundle ??
                sampleBundle(id: 'b1', taskIds: [for (final t in tasks) t.id]),
            tasks: tasks,
            bidder: const AppUser(
              uid: 'prov-1',
              email: 'pro@test.com',
              displayName: 'Pro Fixer',
              role: UserRole.provider,
            ),
            existing: existing,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}

/// What:   Signs in a requestor with a default location and opens the post-a-job form.
/// Input:  [bundle] and [assist] swap those fakes; [height] is the screen height (taller for bundle task cards).
/// Output: The "+ Post a job" form on screen, with "Where" pre-filled so no map picker opens.
Future<void> openPostJob(
  WidgetTester tester, {
  FakeBundleRepository? bundle,
  FakeAssistRepository? assist,
  double height = 1600,
}) async {
  final auth = FakeAuthRepository()
    ..defaultLat = 5.4164
    ..defaultLng = 100.3327
    ..defaultDistrictCode = 'TL'
    ..defaultTown = 'George Town'
    ..seedSignedIn(UserRole.requestor);
  await pumpApp(
    tester,
    buildApp(auth, bundle: bundle, assist: assist),
    size: Size(800, height),
  );
  await tester.tap(find.text('+ Post a job'));
  await tester.pumpAndSettle();
}

/// What:   Pumps one onboarding step inside a scrollable page, driven by [controller].
/// Input:  [controller] provided to the step; [step] the widget under test; [size] optional screen;
///         [settle] waits for animations, else a single frame is pumped.
/// Output: The step on screen.
Future<void> pumpOnboardingStep<T extends ChangeNotifier>(
  WidgetTester tester,
  T controller,
  Widget step, {
  Size? size,
  bool settle = false,
}) async {
  if (size != null) {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      home: ChangeNotifierProvider<T>.value(
        value: controller,
        child: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: step,
          ),
        ),
      ),
    ),
  );
  settle ? await tester.pumpAndSettle() : await tester.pump();
}
