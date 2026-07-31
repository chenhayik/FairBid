import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../features/admin/data/moderation_repository.dart';
import '../features/admin/data/stats_repository.dart';
import '../features/admin/data/user_admin_repository.dart';
import '../features/admin/data/verification_repository.dart';
import '../features/auth/data/auth_repository.dart';
import '../features/auth/presentation/auth_controller.dart';
import '../features/disputes/data/dispute_repository.dart';
import '../features/jobs/data/assist_repository.dart';
import '../features/jobs/data/bid_repository.dart';
import '../features/jobs/data/job_repository.dart';
import '../features/jobs/data/milestone_repository.dart';
import '../features/messages/data/chat_repository.dart';
import '../features/notifications/data/notification_repository.dart';
import '../features/notifications/data/push_service.dart';
import '../features/onboarding/data/document_storage_repository.dart';
import '../features/onboarding/data/onboarding_repository.dart';
import '../features/onboarding/data/requestor_onboarding_repository.dart';
import '../features/onboarding/presentation/onboarding_controller.dart';
import '../features/onboarding/presentation/requestor_onboarding_controller.dart';
import '../features/profile/data/review_repository.dart';
import '../features/wallet/data/wallet_repository.dart';
import 'router/app_router.dart';
import 'theme/app_theme.dart';

/// Root widget. Repositories are injected so production can pass the Firebase
/// implementations and tests can pass fakes without any Firebase setup.
class FairBidApp extends StatelessWidget {
  const FairBidApp({
    super.key,
    required this.authRepository,
    required this.onboardingRepository,
    required this.requestorOnboardingRepository,
    required this.documentStorageRepository,
    required this.jobRepository,
    required this.bidRepository,
    required this.reviewRepository,
    required this.verificationRepository,
    required this.userAdminRepository,
    required this.chatRepository,
    required this.milestoneRepository,
    required this.walletRepository,
    required this.disputeRepository,
    required this.moderationRepository,
    required this.statsRepository,
    required this.notificationRepository,
    required this.pushService,
    required this.assistRepository,
  });

  final AuthRepository authRepository;
  final OnboardingRepository onboardingRepository;
  final RequestorOnboardingRepository requestorOnboardingRepository;
  final DocumentStorageRepository documentStorageRepository;
  final JobRepository jobRepository;
  final BidRepository bidRepository;
  final ReviewRepository reviewRepository;
  final VerificationRepository verificationRepository;
  final UserAdminRepository userAdminRepository;
  final ChatRepository chatRepository;
  final MilestoneRepository milestoneRepository;
  final WalletRepository walletRepository;
  final DisputeRepository disputeRepository;
  final ModerationRepository moderationRepository;
  final StatsRepository statsRepository;
  final NotificationRepository notificationRepository;
  final PushService pushService;
  final AssistRepository assistRepository;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        // Plain repositories, read by scoped controllers (e.g. Post-a-Job).
        Provider<JobRepository>.value(value: jobRepository),
        Provider<BidRepository>.value(value: bidRepository),
        Provider<ReviewRepository>.value(value: reviewRepository),
        Provider<VerificationRepository>.value(
            value: verificationRepository),
        Provider<UserAdminRepository>.value(value: userAdminRepository),
        Provider<DocumentStorageRepository>.value(
            value: documentStorageRepository),
        Provider<ChatRepository>.value(value: chatRepository),
        Provider<MilestoneRepository>.value(value: milestoneRepository),
        Provider<WalletRepository>.value(value: walletRepository),
        Provider<DisputeRepository>.value(value: disputeRepository),
        Provider<ModerationRepository>.value(value: moderationRepository),
        Provider<StatsRepository>.value(value: statsRepository),
        Provider<NotificationRepository>.value(value: notificationRepository),
        Provider<PushService>.value(value: pushService),
        Provider<AssistRepository>.value(value: assistRepository),
        ChangeNotifierProvider(create: (_) => AuthController(authRepository)),
        ChangeNotifierProvider(
            create: (_) => OnboardingController(
                onboardingRepository, documentStorageRepository)),
        ChangeNotifierProvider(
            create: (_) => RequestorOnboardingController(
                requestorOnboardingRepository, documentStorageRepository)),
      ],
      child: const _FairBidAppView(),
    );
  }
}

class _FairBidAppView extends StatefulWidget {
  const _FairBidAppView();

  @override
  State<_FairBidAppView> createState() => _FairBidAppViewState();
}

class _FairBidAppViewState extends State<_FairBidAppView> {
  // Built once, the first time auth state is known. Its `refreshListenable`
  // keeps redirects in sync after that.
  GoRouter? _router;

  // Push bootstrap state: init once per app run, register the device token
  // once per signed-in uid.
  bool _pushInited = false;
  String? _pushTokenUid;

  /// Keeps push wiring in step with auth state. Idempotent — runs on every
  /// build but only acts on transitions (first signed-in build, uid change).
  void _syncPush(AuthController auth) {
    final user = auth.user;
    if (user == null) {
      _pushTokenUid = null; // next sign-in re-registers
      return;
    }
    // Wait until onboarding is done so the permission prompt appears on the
    // home screen, when the app has shown its value — not at cold start.
    if (user.needsOnboarding || _pushTokenUid == user.uid) return;
    _pushTokenUid = user.uid;

    final notifications = context.read<NotificationRepository>();
    final push = context.read<PushService>();

    // Detach this device's token before sign-out completes, so the next
    // account on this device can't receive this user's notifications.
    auth.onBeforeSignOut = notifications.removeToken;

    if (!_pushInited) {
      _pushInited = true;
      push.init(
        onOpenRoute: (route) => _router?.push(route),
        onTokenRefresh: () {
          final uid = auth.user?.uid;
          if (uid != null) {
            notifications.registerToken(uid).catchError((_) {});
          }
        },
      );
    }
    push.requestPermission();
    notifications.registerToken(user.uid).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();

    // Show a splash until we know whether someone is already signed in.
    if (auth.isInitializing) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        home: const SplashScreen(),
      );
    }

    _router ??= buildRouter(auth);
    _syncPush(auth);
    return MaterialApp.router(
      title: 'FairBid',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      routerConfig: _router!,
    );
  }
}
