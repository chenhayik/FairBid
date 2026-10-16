import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../core/config/platform_config.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/util/money.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../../core/widgets/form_widgets.dart';
import '../../../core/widgets/keyed_stream_builder.dart';
import '../../../core/widgets/user_avatar.dart';
import '../../admin/data/verification_repository.dart';
import '../../admin/domain/pending_verification.dart';
import '../../auth/domain/app_user.dart';
import '../../auth/domain/user_role.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../auth/presentation/mfa_code_sheet.dart';
import '../../home/presentation/home_app_bar.dart';
import '../../onboarding/domain/onboarding_data.dart';
import '../data/review_repository.dart';
import '../domain/review.dart';
import 'widgets/review_list.dart';

/// What:   The Profile tab: a role-aware view of the signed-in user.
/// Input:  [AuthController.user]; reviews via ReviewRepository.watchReviews() (review_repository.dart).
/// Output: Header, Trust Score, wallet and security links, About, Basic Details and Reviews (admins get access and activity cards instead).
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
            // Admins are staff, not marketplace participants: no score, wallet or reviews.
            if (isAdmin) ...[
              const _AdminAccessCard(),
              const SizedBox(height: 16),
              const _AdminActivityCard(),
              const SizedBox(height: 16),
              _BasicDetailsCard(user: user),
            ] else ...[
              _TrustScoreCard(user: user),
              const SizedBox(height: 16),
              _NavCard(
                icon: Icons.account_balance_wallet_outlined,
                title: isProvider ? 'Earnings & payouts' : 'My wallet',
                subtitle: isProvider
                    ? 'Manage your income and payout method'
                    : 'Top up and track your job payments',
                route: '/profile/earnings',
              ),
              const SizedBox(height: 16),
              _AboutCard(user: user),
              const SizedBox(height: 16),
              _BasicDetailsCard(user: user),
              const SizedBox(height: 16),
              ReviewList(
                uid: user.uid,
                seeAllCount: user.ratingCount,
                header: Text('Reviews (${user.ratingCount})',
                    style: Theme.of(context).textTheme.titleLarge),
                onFlag: (review) => _flagReview(context, user, review),
              ),
            ],
            const SizedBox(height: 16),
            const _NavCard(
              icon: Icons.shield_outlined,
              title: 'Security',
              subtitle: 'Two-factor authentication',
              route: '/profile/security',
            ),
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

/// What:   Deletes the signed-in account after a confirm dialog.
/// Input:  [auth] and [user]; the password from _DeleteAccountDialog (null = cancelled).
/// Output: AuthController.deleteAccount(); the `cleanupUserDoc` function removes the data and the router returns to sign-in; an error snackbar on failure.
/// Notes:  deleteAccount re-authenticates internally, so an MFA challenge surfaces here: the code sheet is shown and the delete retried once.
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

  var success = await auth.deleteAccount(
    password: password.isEmpty ? null : password,
  );
  if (!context.mounted) return;

  if (!success) {
    // deleteAccount re-authenticates internally, so an MFA challenge surfaces here, not in a reauth dialog.
    final challenge = auth.takePendingChallenge();
    if (challenge != null) {
      final verified = await MfaCodeSheet.show(context, challenge: challenge);
      if (!context.mounted) return;
      if (verified) {
        success = await auth.deleteAccount(
          password: password.isEmpty ? null : password,
        );
        if (!context.mounted) return;
      }
    }
  }
  if (success) return;

  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(
        auth.errorMessage ?? 'Could not delete your account. Please try again.'),
  ));
}

/// What:   Delete-account confirmation with an optional password field.
/// Input:  [requiresPassword] true for email/password accounts.
/// Output: Pops the typed password (empty when not required) on Delete, null on Cancel.
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

/// What:   Avatar, name and role subtitle at the top of the profile.
/// Input:  [user] from AuthController.
/// Output: Column with the photo, display name (or email) and provider type or role label.
class _Header extends StatelessWidget {
  const _Header({required this.user});
  final AppUser user;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        UserAvatar(photoUrl: user.profilePhotoUrl, radius: 36, iconSize: 36),
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
        _ => ProviderType.fromStorage(user.providerType)?.label ??
            user.role.label,
      };
}

/// What:   Admin-only banner describing platform access.
/// Input:  None.
/// Output: InfoBanner pointing to the Home tab tools.
class _AdminAccessCard extends StatelessWidget {
  const _AdminAccessCard();

  @override
  Widget build(BuildContext context) {
    return const InfoBanner(
      icon: Icons.admin_panel_settings_outlined,
      title: 'Administrator Access',
      body: 'You can review verification submissions and manage marketplace '
          'participants from the Home tab.',
      leftAccent: true,
    );
  }
}

/// What:   Admin-only live count of applicants awaiting review.
/// Input:  VerificationRepository.watchPending() (verification_repository.dart).
/// Output: StatCard with the count, "-" until loaded.
class _AdminActivityCard extends StatelessWidget {
  const _AdminActivityCard();

  @override
  Widget build(BuildContext context) {
    return KeyedStreamBuilder<List<PendingVerification>>(
      create: context.read<VerificationRepository>().watchPending,
      builder: (context, snapshot) {
        final count = snapshot.data?.length;
        return StatCard(
          label: 'Pending Verifications',
          value: count == null ? '-' : formatCount(count),
          icon: Icons.verified_user_outlined,
        );
      },
    );
  }
}

/// What:   The user's Trust Score with its four sub-score bars.
/// Input:  [user] with the server-computed score and breakdown.
/// Output: Score out of 100 once visible, otherwise a "New" pill and jobs-to-go text; Reviews, Track Record, Verification and Profile bars with coaching hints.
/// Notes:  The Verification and Profile bars link to onboarding and Edit Profile when they can still improve.
class _TrustScoreCard extends StatelessWidget {
  const _TrustScoreCard({required this.user});
  final AppUser user;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Server-computed; reads 0 until the Cloud Function has scored this profile.
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
                  label: 'New',
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
                      'jobs, $jobsToGo to go.'
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
                    '+${PlatformConfig.trackRecordPerJob}; each lost dispute '
                    'takes off ${PlatformConfig.disputeLostPenalty}.'
                : null,
          ),
          TrustScoreBar(
            label: 'Verification',
            percent: trust?.verificationScore ?? 0,
            hint: switch (user.verificationStatus) {
              'approved' => null,
              'pending' => 'Awaiting admin review.',
              'rejected' => 'Not approved. Tap to send your documents again.',
              _ => 'Tap to send your documents and get verified.',
            },
            // Skipped or rejected users can restart verification.
            onTap: user.verificationStatus == 'approved' ||
                    user.verificationStatus == 'pending'
                ? null
                : () => context.push('/onboarding'),
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

  /// What:   Names what the Profile sub-score still lacks.
  /// Input:  [user] name, phone, bio, photo and location.
  /// Output: "Add your ..." text, or null when complete.
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

/// What:   Tappable card with an icon, title, subtitle and chevron that opens [route].
/// Input:  [icon], [title], [subtitle], [route].
/// Output: AppCard that pushes [route] on tap.
class _NavCard extends StatelessWidget {
  const _NavCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.route,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final String route;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppCard(
      onTap: () => context.push(route),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: context.fairbid.subtleBlue,
            child: Icon(icon, color: context.fairbid.verified),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleLarge),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
          Icon(Icons.chevron_right, color: theme.colorScheme.onSurfaceVariant),
        ],
      ),
    );
  }
}

/// What:   The user's bio with an Edit link.
/// Input:  [user].bio.
/// Output: The bio, or a muted prompt to add one.
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

/// What:   Name, email, phone and location rows with an Edit link.
/// Input:  [user].
/// Output: AppCard; empty values show "Not set".
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

/// What:   The blue "Edit" link to Edit Profile.
/// Input:  None.
/// Output: Tappable text (48px minimum target) that pushes `/profile/edit`.
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

/// What:   Reports a review on the user's own profile to the admins.
/// Input:  [review] and [user]; the reason from a ReasonDialog (null = cancelled).
/// Output: ReviewRepository.flagReview() puts it in the moderation queue; it stays visible until an admin rules; snackbar with the result.
Future<void> _flagReview(
    BuildContext context, AppUser user, Review review) async {
  final reviews = context.read<ReviewRepository>();
  final messenger = ScaffoldMessenger.of(context);
  final reason = await showDialog<String>(
    context: context,
    builder: (_) => const ReasonDialog(
      title: 'Report this review?',
      message: 'Tell the admins why this review is unfair or abusive. It '
          'stays visible until they decide.',
      hint: 'e.g. This reviewer was never my client.',
      confirmLabel: 'Report',
    ),
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
        content: Text('Review reported. An admin will look at it.')));
  } catch (_) {
    messenger.showSnackBar(const SnackBar(
        content: Text('Could not report the review. Please try again.')));
  }
}
