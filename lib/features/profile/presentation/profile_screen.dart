import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../core/config/platform_config.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../admin/data/verification_repository.dart';
import '../../admin/domain/pending_verification.dart';
import '../../auth/domain/app_user.dart';
import '../../auth/domain/user_role.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../home/presentation/home_app_bar.dart';
import '../data/review_repository.dart';
import '../domain/review.dart';
import 'widgets/review_card.dart';

/// The "Profile" tab. A role-aware view of the signed-in user: header, Trust
/// Score, a provider-only Earnings & Payouts entry, editable About and Basic
/// Details, and the reviews read from Firestore.
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    final user = auth.user;
    if (user == null) {
      return const Scaffold(
        appBar: HomeAppBar(),
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final isProvider = user.role == UserRole.provider;
    final isAdmin = user.role == UserRole.admin;

    return Scaffold(
      appBar: const HomeAppBar(),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            _Header(user: user),
            const SizedBox(height: 24),
            // Admins are platform staff, not marketplace participants, so the
            // Trust Score / earnings / client bio / reviews don't apply — show
            // their access and account details instead.
            if (isAdmin) ...[
              const _AdminAccessCard(),
              const SizedBox(height: 16),
              const _AdminActivityCard(),
              const SizedBox(height: 16),
              _BasicDetailsCard(user: user),
            ] else ...[
              _TrustScoreCard(user: user),
              const SizedBox(height: 16),
              _EarningsNavCard(isProvider: isProvider),
              const SizedBox(height: 16),
              _AboutCard(user: user),
              const SizedBox(height: 16),
              _BasicDetailsCard(user: user),
              const SizedBox(height: 16),
              _ReviewsCard(user: user),
            ],
            const SizedBox(height: 24),
            SecondaryButton(
              label: 'Log out',
              onPressed: auth.isBusy ? null : auth.signOut,
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed:
                  auth.isBusy ? null : () => _confirmDelete(context, auth, user),
              style: TextButton.styleFrom(
                foregroundColor: context.fairbid.danger,
                minimumSize: const Size.fromHeight(44),
              ),
              child: const Text('Delete Account'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shows the delete-account confirmation dialog and, if confirmed, deletes
/// the account. Firestore cleanup happens server-side (`cleanupUserDoc` Cloud
/// Function) once the Auth account is gone; the router redirects to sign-in
/// once [AuthController] observes the signed-out state.
Future<void> _confirmDelete(
  BuildContext context,
  AuthController auth,
  AppUser user,
) async {
  final password = await showDialog<String>(
    context: context,
    builder: (_) =>
        _DeleteAccountDialog(requiresPassword: user.isPasswordAccount),
  );
  if (password == null || !context.mounted) return;

  final success = await auth.deleteAccount(
    password: password.isEmpty ? null : password,
  );
  if (!context.mounted || success) return;

  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(
        auth.errorMessage ?? 'Could not delete your account. Please try again.'),
  ));
}

class _DeleteAccountDialog extends StatefulWidget {
  const _DeleteAccountDialog({required this.requiresPassword});

  final bool requiresPassword;

  @override
  State<_DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<_DeleteAccountDialog> {
  final _passwordController = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Delete account?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'This permanently deletes your account and all your data '
            '(profile, jobs, bids, reviews). This cannot be undone.',
          ),
          if (widget.requiresPassword) ...[
            const SizedBox(height: 16),
            TextField(
              controller: _passwordController,
              obscureText: _obscure,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Confirm your password',
                suffixIcon: IconButton(
                  tooltip: _obscure ? 'Show password' : 'Hide password',
                  icon: Icon(
                      _obscure ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: context.fairbid.danger,
          ),
          onPressed: () =>
              Navigator.of(context).pop(_passwordController.text),
          child: const Text('Delete'),
        ),
      ],
    );
  }
}

class _Header extends StatefulWidget {
  const _Header({required this.user});
  final AppUser user;

  @override
  State<_Header> createState() => _HeaderState();
}

class _HeaderState extends State<_Header> {
  AppUser get user => widget.user;

  /// Set once the avatar fails to load, so the fallback icon is shown instead
  /// of a broken image.
  bool _avatarFailed = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final photo = user.profilePhotoUrl;
    final hasPhoto = photo != null && photo.isNotEmpty && !_avatarFailed;
    return Column(
      children: [
        CircleAvatar(
          radius: 36,
          backgroundColor: context.fairbid.subtleBlue,
          backgroundImage: hasPhoto ? NetworkImage(photo) : null,
          onBackgroundImageError: hasPhoto
              ? (_, _) {
                  if (mounted) setState(() => _avatarFailed = true);
                }
              : null,
          child: hasPhoto
              ? null
              : Icon(Icons.person_outline,
                  size: 36, color: context.fairbid.verified),
        ),
        const SizedBox(height: 12),
        Text(user.displayName ?? user.email ?? 'User',
            style: theme.textTheme.headlineMedium),
        const SizedBox(height: 4),
        Text(_subtitle(user),
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ],
    );
  }

  String _subtitle(AppUser user) => switch (user.role) {
        UserRole.admin => 'Administrator',
        _ => switch (user.providerType) {
            'individual' => 'Individual / Freelancer',
            'business' => 'Registered Business',
            _ => user.role.label,
          },
      };
}

/// Admin-only: a short banner explaining the account's platform access.
class _AdminAccessCard extends StatelessWidget {
  const _AdminAccessCard();

  @override
  Widget build(BuildContext context) {
    return const InfoBanner(
      icon: Icons.admin_panel_settings_outlined,
      title: 'Administrator Access',
      body: 'You can review verification submissions and manage marketplace '
          'participants from the Dashboard.',
      leftAccent: true,
    );
  }
}

/// Admin-only: a live count of applicants still awaiting review, so the admin
/// sees outstanding work at a glance from their profile too.
class _AdminActivityCard extends StatelessWidget {
  const _AdminActivityCard();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<PendingVerification>>(
      stream: context.read<VerificationRepository>().watchPending(),
      builder: (context, snapshot) {
        final count = snapshot.data?.length;
        return StatCard(
          label: 'Pending Verifications',
          value: count?.toString() ?? '—',
          icon: Icons.verified_user_outlined,
        );
      },
    );
  }
}

class _TrustScoreCard extends StatelessWidget {
  const _TrustScoreCard({required this.user});
  final AppUser user;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The server-computed breakdown behind the headline score. Until the
    // Cloud Function has scored this profile, everything reads 0 / hidden.
    final trust = user.trustBreakdown;
    final trustPercent = (user.trustScore / 10).round();
    final jobsToGo =
        (PlatformConfig.minJobsForVisibleScore - user.jobsCompleted)
            .clamp(0, PlatformConfig.minJobsForVisibleScore);

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                  child:
                      Text('Trust Score', style: theme.textTheme.titleLarge)),
              if (user.scoreVisible)
                Text('$trustPercent/100',
                    style: theme.textTheme.titleLarge
                        ?.copyWith(color: context.fairbid.verified))
              else
                PillBadge(
                  label: 'New User',
                  icon: Icons.auto_awesome,
                  color: context.fairbid.verified,
                ),
            ],
          ),
          if (!user.scoreVisible) ...[
            const SizedBox(height: 8),
            Text(
              user.verificationStatus == 'approved'
                  ? 'Your score unlocks after '
                      '${PlatformConfig.minJobsForVisibleScore} completed '
                      'jobs — $jobsToGo to go.'
                  : 'Your score unlocks once you\'re verified and have '
                      'completed ${PlatformConfig.minJobsForVisibleScore} '
                      'jobs (${user.jobsCompleted}/'
                      '${PlatformConfig.minJobsForVisibleScore}).',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
          const Divider(height: 32),
          Text('Ways to build trust', style: theme.textTheme.labelMedium),
          const SizedBox(height: 12),
          TrustScoreBar(
            label: 'Reviews',
            percent: trust?.reviewScore ?? 0,
            hint: user.ratingCount == 0
                ? 'Great reviews from completed jobs raise this.'
                : null,
          ),
          TrustScoreBar(
            label: 'Track Record',
            percent: trust?.trackRecordScore ?? 0,
            hint: (trust?.trackRecordScore ?? 0) < 100
                ? 'Each completed job adds '
                    '+${PlatformConfig.trackRecordPerJob}.'
                : null,
          ),
          TrustScoreBar(
            label: 'Verification',
            percent: trust?.verificationScore ?? 0,
            hint: switch (user.verificationStatus) {
              'approved' => null,
              'pending' => 'Awaiting admin review.',
              _ => 'Submit your documents to get verified.',
            },
          ),
          TrustScoreBar(
            label: 'Profile',
            percent: trust?.profileScore ?? 0,
            hint: _missingProfileHint(),
            onTap: (trust?.profileScore ?? 0) < 100
                ? () => context.push('/profile/edit')
                : null,
          ),
        ],
      ),
    );
  }

  /// Names what's still missing from the profile sub-score, or null when
  /// everything the score counts is filled in.
  String? _missingProfileHint() {
    final missing = [
      if ((user.displayName ?? '').isEmpty) 'name',
      if ((user.phone ?? '').isEmpty) 'phone',
      if ((user.bio ?? '').isEmpty) 'bio',
      if ((user.profilePhotoUrl ?? '').isEmpty) 'photo',
      if ((user.location ?? '').isEmpty) 'location',
    ];
    return missing.isEmpty ? null : 'Add your ${missing.join(', ')}.';
  }
}

/// Navigation card to the wallet screen — Earnings & Payouts for providers,
/// My Wallet (with the demo top-up) for requestors.
class _EarningsNavCard extends StatelessWidget {
  const _EarningsNavCard({required this.isProvider});
  final bool isProvider;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: () => context.push('/profile/earnings'),
      borderRadius: BorderRadius.circular(12),
      child: AppCard(
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: context.fairbid.subtleBlue,
              child: Icon(Icons.account_balance_wallet_outlined,
                  color: context.fairbid.verified),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(isProvider ? 'Earnings & Payouts' : 'My Wallet',
                      style: theme.textTheme.titleLarge),
                  const SizedBox(height: 2),
                  Text(
                      isProvider
                          ? 'Manage your income and bank details'
                          : 'Top up and track your job payments',
                      style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: theme.colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

class _AboutCard extends StatelessWidget {
  const _AboutCard({required this.user});
  final AppUser user;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bio = user.bio;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                  child: Text('About', style: theme.textTheme.titleLarge)),
              _EditLink(),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            bio == null || bio.isEmpty
                ? 'Add a short bio so clients know your experience and skills.'
                : bio,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: bio == null || bio.isEmpty
                  ? theme.colorScheme.onSurfaceVariant
                  : theme.colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

class _BasicDetailsCard extends StatelessWidget {
  const _BasicDetailsCard({required this.user});
  final AppUser user;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget row(String label, String? value) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: theme.textTheme.labelMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              const SizedBox(height: 2),
              Text(value == null || value.isEmpty ? 'Not set' : value,
                  style: theme.textTheme.bodyLarge),
            ],
          ),
        );

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                  child: Text('Basic Details',
                      style: theme.textTheme.titleLarge)),
              _EditLink(),
            ],
          ),
          const SizedBox(height: 16),
          row('Full Name', user.displayName),
          row('Email Address', user.email),
          row('Phone Number', user.phone),
          row('Location', user.location),
        ],
      ),
    );
  }
}

/// The blue "Edit" text link opening the Edit Profile screen.
class _EditLink extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Edit profile',
      child: InkWell(
        onTap: () => context.push('/profile/edit'),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          child: Text('Edit',
              style: Theme.of(context)
                  .textTheme
                  .labelLarge
                  ?.copyWith(color: context.fairbid.verified)),
        ),
      ),
    );
  }
}

class _ReviewsCard extends StatelessWidget {
  const _ReviewsCard({required this.user});
  final AppUser user;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reviews = context.read<ReviewRepository>();

    return AppCard(
      child: StreamBuilder<List<Review>>(
        stream: reviews.watchReviews(user.uid),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const EmptyState(
              icon: Icons.error_outline,
              title: "Couldn't load reviews",
              message: 'Please check your connection and try again.',
            );
          }
          final items = snapshot.data ?? const <Review>[];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Reviews (${user.ratingCount})',
                  style: theme.textTheme.titleLarge),
              const SizedBox(height: 12),
              if (items.isEmpty)
                const EmptyState(
                  icon: Icons.star_border_rounded,
                  title: 'No reviews yet',
                  message: 'Reviews from completed jobs will appear here.',
                )
              else
                for (final (i, review) in items.take(3).indexed) ...[
                  if (i > 0) ...[
                    const Divider(height: 24),
                  ],
                  // These are the viewer's own reviews, so they may report an
                  // unfair one for admin moderation.
                  ReviewCard(
                    review: review,
                    onFlag: () => _flagReview(context, review),
                  ),
                ],
            ],
          );
        },
      ),
    );
  }

  /// Asks for a reason, then flags [review] for the admin moderation queue.
  Future<void> _flagReview(BuildContext context, Review review) async {
    final reviews = context.read<ReviewRepository>();
    final messenger = ScaffoldMessenger.of(context);
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => const _FlagReviewDialog(),
    );
    if (reason == null) return; // cancelled

    try {
      await reviews.flagReview(
        revieweeId: user.uid,
        reviewId: review.id,
        reason: reason,
        flaggedByUid: user.uid,
      );
      messenger.showSnackBar(const SnackBar(
          content: Text('Review reported — an admin will look at it.')));
    } catch (_) {
      messenger.showSnackBar(const SnackBar(
          content: Text('Could not report the review. Please try again.')));
    }
  }
}

/// Reason dialog for reporting a review. Returns the reason on confirm
/// (required) or null on cancel.
class _FlagReviewDialog extends StatefulWidget {
  const _FlagReviewDialog();

  @override
  State<_FlagReviewDialog> createState() => _FlagReviewDialogState();
}

class _FlagReviewDialogState extends State<_FlagReviewDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Report this review?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
              'Tell the admins why this review is unfair or abusive. It stays '
              'visible until they decide.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            maxLines: 3,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              hintText: 'e.g. This reviewer was never my client.',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _controller.text.trim().isEmpty
              ? null
              : () => Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('Report'),
        ),
      ],
    );
  }
}
