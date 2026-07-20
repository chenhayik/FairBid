import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../features/admin/domain/pending_verification.dart';
import '../../features/admin/presentation/verification_detail_screen.dart';
import '../../features/auth/presentation/auth_controller.dart';
import '../../features/auth/presentation/login_screen.dart';
import '../../features/auth/presentation/register_screen.dart';
import '../../features/disputes/domain/dispute.dart';
import '../../features/disputes/presentation/dispute_detail_screen.dart';
import '../../features/home/presentation/home_screen.dart';
import '../../features/jobs/presentation/detail/job_detail_screen.dart';
import '../../features/jobs/presentation/feed/job_feed_screen.dart';
import '../../features/jobs/presentation/my_jobs_screen.dart';
import '../../features/jobs/presentation/post_job/post_job_screen.dart';
import '../../features/messages/presentation/conversation_thread_screen.dart';
import '../../features/messages/presentation/messages_screen.dart';
import '../../features/notifications/presentation/notifications_screen.dart';
import '../../features/onboarding/presentation/onboarding_flow_screen.dart';
import '../../features/profile/presentation/earnings_screen.dart';
import '../../features/profile/presentation/edit_profile_screen.dart';
import '../../features/profile/presentation/profile_screen.dart';
import '../navigation/app_shell.dart';

/// Builds the app router. It listens to [auth] so that signing in/out or
/// finishing onboarding automatically redirects to the right screen.
GoRouter buildRouter(AuthController auth) {
  return GoRouter(
    refreshListenable: auth,
    initialLocation: '/login',
    redirect: (context, state) {
      // While the first auth state is loading, stay put (splash is shown).
      if (auth.isInitializing) return null;

      final user = auth.user;
      final location = state.matchedLocation;
      final onAuthScreen = location == '/login' || location == '/register';

      // Signed out → only the auth screens are reachable.
      if (user == null) return onAuthScreen ? null : '/login';

      // Providers who haven't submitted onboarding are locked into it.
      if (user.needsOnboarding) {
        return location == '/onboarding' ? null : '/onboarding';
      }

      // Signed in but sitting on an auth screen → send home.
      if (onAuthScreen) return '/home';

      return null;
    },
    routes: [
      GoRoute(path: '/login', builder: (_, _) => const LoginScreen()),
      GoRoute(path: '/register', builder: (_, _) => const RegisterScreen()),
      GoRoute(
          path: '/onboarding',
          builder: (_, _) => const OnboardingFlowScreen()),

      // Jobs — pushed full-screen (outside the tab shell) with a back button.
      GoRoute(path: '/post-job', builder: (_, _) => const PostJobScreen()),
      GoRoute(path: '/jobs', builder: (_, _) => const JobFeedScreen()),
      GoRoute(
        path: '/jobs/:id',
        builder: (_, state) =>
            JobDetailScreen(jobId: state.pathParameters['id']!),
      ),

      // Admin — the verification review screen, pushed from the queue with the
      // selected applicant passed as `extra`.
      GoRoute(
        path: '/admin/verify',
        builder: (_, state) => VerificationDetailScreen(
            verification: state.extra as PendingVerification),
      ),

      // Admin — the dispute ruling screen, pushed from the disputes queue with
      // the selected dispute passed as `extra`.
      GoRoute(
        path: '/admin/dispute',
        builder: (_, state) =>
            DisputeDetailScreen(dispute: state.extra as Dispute),
      ),

      // Chat thread — pushed full-screen (outside the tab shell) with a back
      // button. `/messages` (no id) stays a tab inside the shell below.
      GoRoute(
        path: '/messages/:id',
        builder: (_, state) => ConversationThreadScreen(
            conversationId: state.pathParameters['id']!),
      ),

      // Notification centre — pushed from the app bar bell; also the landing
      // point for tapped push notifications.
      GoRoute(
          path: '/notifications',
          builder: (_, _) => const NotificationsScreen()),

      // Profile — pushed full-screen (outside the tab shell) with a back button.
      GoRoute(
          path: '/profile/edit', builder: (_, _) => const EditProfileScreen()),
      GoRoute(
          path: '/profile/earnings',
          builder: (_, _) => const EarningsScreen()),

      // The four main tabs live in a persistent bottom-nav shell.
      StatefulShellRoute.indexedStack(
        builder: (_, _, navigationShell) =>
            AppShell(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(routes: [
            GoRoute(path: '/home', builder: (_, _) => const HomeScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
                path: '/my-jobs', builder: (_, _) => const MyJobsScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
                path: '/messages',
                builder: (_, _) => const MessagesScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
                path: '/profile', builder: (_, _) => const ProfileScreen()),
          ]),
        ],
      ),
    ],
  );
}

/// Shown while the app determines whether someone is already signed in.
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}
