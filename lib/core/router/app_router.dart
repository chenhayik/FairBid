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
import 'package:flutter/foundation.dart';

/// What:   A listenable that fires only when an input to the redirects changes.
/// Input:  [auth].
/// Output: Notifies on sign in/out, role, suspension or onboarding changes only.
/// Notes:  Refreshing the router on every profile edit swallows a pop made in the same frame.
Listenable _redirectInputs(AuthController auth) {
  final inputs = ValueNotifier<Object?>(null);
  /// What:   Copies the current redirect inputs into the notifier.
  /// Output: Updates `inputs` with a record; equal records do not notify.
  void sync() {
    final user = auth.user;
    // Records compare by value, so unchanged inputs don't notify.
    inputs.value = (auth.isInitializing, user?.uid, user?.role,
    user?.suspended, user?.needsOnboarding);
  }

  sync();
  auth.addListener(sync);
  return inputs;
}

/// What:   Builds the app's GoRouter.
/// Input:  [auth]; its changes (sign in/out, onboarding, suspension) re-run the redirects.
/// Output: Routes for auth, onboarding, pushed screens and the four-tab shell.
GoRouter buildRouter(AuthController auth) {
  return GoRouter(
    refreshListenable: _redirectInputs(auth),
    initialLocation: '/login',
    redirect: (context, state) {
      // Stay put while the first auth state loads.
      if (auth.isInitializing) return null;

      final user = auth.user;
      final location = state.matchedLocation;
      final onAuthScreen = location == '/login' || location == '/register';

      // Signed out → only the auth screens are reachable.
      if (user == null) return onAuthScreen ? null : '/login';

      // Above onboarding so a mid-onboarding suspension still applies; admins are exempt.
      if (user.suspended && user.role != UserRole.admin) {
        return location == '/suspended' ? null : '/suspended';
      }
      if (location == '/suspended') return '/home';

      // Users who haven't finished onboarding are locked into it.
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

      // Pushed full-screen outside the tab shell.
      GoRoute(path: '/post-job', builder: (_, _) => const PostJobScreen()),
      GoRoute(path: '/jobs', builder: (_, _) => const JobFeedScreen()),
      GoRoute(
          path: '/jobs/saved', builder: (_, _) => const SavedJobsScreen()),
      // `?from=bundle`: opened from its bundle, so "View bundle" goes back.
      GoRoute(
        path: '/jobs/:id',
        builder: (_, state) => JobDetailScreen(
          jobId: state.pathParameters['id']!,
          fromBundle: state.uri.queryParameters['from'] == 'bundle',
        ),
      ),

      // `?fromTask=<jobId>`: opened from that task, so tapping it goes back.
      GoRoute(
        path: '/bundles/:id',
        builder: (_, state) => BundleDetailScreen(
          bundleId: state.pathParameters['id']!,
          fromTaskId: state.uri.queryParameters['fromTask'],
        ),
      ),

      // Admin screens take the selected item as `extra`.
      GoRoute(
        path: '/admin/verify',
        builder: (_, state) => VerificationDetailScreen(
            verification: state.extra as PendingVerification),
      ),

      GoRoute(
        path: '/admin/dispute',
        builder: (_, state) =>
            DisputeDetailScreen(dispute: state.extra as Dispute),
      ),

      // `/messages` (no id) is a tab in the shell below.
      GoRoute(
        path: '/messages/:id',
        builder: (_, state) => ConversationThreadScreen(
            conversationId: state.pathParameters['id']!),
      ),

      // Also the landing point for tapped push notifications.
      GoRoute(
          path: '/notifications',
          builder: (_, _) => const NotificationsScreen()),

      GoRoute(
          path: '/suspended', builder: (_, _) => const SuspendedScreen()),

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

      // Your own uid redirects to /profile.
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
