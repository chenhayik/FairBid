import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../features/admin/domain/pending_verification.dart';
import '../../features/admin/presentation/verification_detail_screen.dart';
import '../../features/auth/presentation/auth_controller.dart';
import '../../features/auth/domain/user_role.dart';
import '../../features/auth/presentation/login_screen.dart';
import '../../features/auth/presentation/register_screen.dart';
import '../../features/auth/presentation/security_screen.dart';
import '../../features/auth/presentation/suspended_screen.dart';
import '../../features/disputes/domain/dispute.dart';
import '../../features/disputes/presentation/dispute_detail_screen.dart';
import '../../features/home/presentation/home_screen.dart';
import '../../features/jobs/presentation/bundle/bundle_detail_screen.dart';
import '../../features/jobs/presentation/detail/job_detail_screen.dart';
import '../../features/jobs/presentation/feed/job_feed_screen.dart';
import '../../features/jobs/presentation/my_jobs_screen.dart';
import '../../features/jobs/presentation/post_job/post_job_screen.dart';
import '../../features/jobs/presentation/saved_jobs_screen.dart';
import '../../features/messages/presentation/conversation_thread_screen.dart';
import '../../features/messages/presentation/messages_screen.dart';
import '../../features/notifications/presentation/notifications_screen.dart';
import '../../features/onboarding/presentation/onboarding_flow_screen.dart';
import '../../features/profile/presentation/earnings_screen.dart';
import '../../features/profile/presentation/edit_profile_screen.dart';
import '../../features/profile/presentation/profile_screen.dart';
import '../../features/profile/presentation/public_profile_screen.dart';
import '../../features/profile/presentation/user_reviews_screen.dart';
import '../../features/wallet/presentation/payout_method_screen.dart';
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

      // Suspended users (never admins) are locked to the suspended notice -
      // above onboarding so a mid-onboarding suspension still applies.
      if (user.suspended && user.role != UserRole.admin) {
        return location == '/suspended' ? null : '/suspended';
      }
      // A reinstated user must never linger on the suspended screen.
      if (location == '/suspended') return '/home';

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

      // Jobs - pushed full-screen (outside the tab shell) with a back button.
      GoRoute(path: '/post-job', builder: (_, _) => const PostJobScreen()),
      GoRoute(path: '/jobs', builder: (_, _) => const JobFeedScreen()),
      GoRoute(
          path: '/jobs/saved', builder: (_, _) => const SavedJobsScreen()),
      // `?from=bundle` means it was opened from that task's bundle screen, so
      // "View bundle" goes back instead of stacking another copy.
      GoRoute(
        path: '/jobs/:id',
        builder: (_, state) => JobDetailScreen(
          jobId: state.pathParameters['id']!,
          fromBundle: state.uri.queryParameters['from'] == 'bundle',
        ),
      ),

      // A bundled posting: the requestor's tasks, bids and award options, or a
      // provider's read-only view. `?fromTask=<jobId>` names the task it was
      // opened from, so tapping that task goes back instead of stacking.
      GoRoute(
        path: '/bundles/:id',
        builder: (_, state) => BundleDetailScreen(
          bundleId: state.pathParameters['id']!,
          fromTaskId: state.uri.queryParameters['fromTask'],
        ),
      ),

      // Admin - the verification review screen, pushed from the queue with the
      // selected applicant passed as `extra`.
      GoRoute(
        path: '/admin/verify',
        builder: (_, state) => VerificationDetailScreen(
            verification: state.extra as PendingVerification),
      ),

      // Admin - the dispute ruling screen, pushed from the disputes queue with
      // the selected dispute passed as `extra`.
      GoRoute(
        path: '/admin/dispute',
        builder: (_, state) =>
            DisputeDetailScreen(dispute: state.extra as Dispute),
      ),

      // Chat thread - pushed full-screen (outside the tab shell) with a back
      // button. `/messages` (no id) stays a tab inside the shell below.
      GoRoute(
        path: '/messages/:id',
        builder: (_, state) => ConversationThreadScreen(
            conversationId: state.pathParameters['id']!),
      ),

      // Notification centre - pushed from the app bar bell; also the landing
      // point for tapped push notifications.
      GoRoute(
          path: '/notifications',
          builder: (_, _) => const NotificationsScreen()),

      // Shown when an admin has suspended the account (router redirects every
      // other route here for a suspended non-admin user).
      GoRoute(
          path: '/suspended', builder: (_, _) => const SuspendedScreen()),

      // Profile - pushed full-screen (outside the tab shell) with a back button.
      GoRoute(
          path: '/profile/edit', builder: (_, _) => const EditProfileScreen()),
      GoRoute(
          path: '/profile/earnings',
          builder: (_, _) => const EarningsScreen()),
      GoRoute(
          path: '/profile/payout-method',
          builder: (_, _) => const PayoutMethodScreen()),
      GoRoute(
          path: '/profile/security',
          builder: (_, _) => const SecurityScreen()),

      // Public profile - pushed full-screen (outside the tab shell) with a
      // back button, matching /jobs/:id. Viewing your own uid redirects to
      // the canonical /profile screen instead of a second copy of it.
      GoRoute(
        path: '/users/:uid',
        redirect: (context, state) {
          final uid = state.pathParameters['uid'];
          return uid != null && uid == auth.user?.uid ? '/profile' : null;
        },
        builder: (_, state) =>
            PublicProfileScreen(uid: state.pathParameters['uid']!),
      ),
      GoRoute(
        path: '/users/:uid/reviews',
        builder: (_, state) =>
            UserReviewsScreen(uid: state.pathParameters['uid']!),
      ),

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
