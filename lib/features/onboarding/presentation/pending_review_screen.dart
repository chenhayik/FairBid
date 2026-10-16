import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_widgets.dart';

/// What:   Post-submission screen shown while an admin reviews the provider.
/// Input:  None; opened when verificationStatus is 'pending'.
/// Output: Status tiles plus Go to Home / Explore Jobs.
class PendingReviewScreen extends StatelessWidget {
  const PendingReviewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Onboarding'),
        leading: BackButton(
          // The account is usable during review, so back leaves for the dashboard.
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/home'),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  InfoBanner(
                    icon: Icons.pending_actions_outlined,
                    color: context.fairbid.warningText,
                    background:
                        context.fairbid.warning.withValues(alpha: 0.12),
                    title: 'Admin Verification in Progress',
                    body: 'Estimated time: 1-2 business days.',
                  ),
                  const SizedBox(height: 32),
                  const _ReviewSpinnerArt(),
                  const SizedBox(height: 24),
                  Text("You're almost there.",
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineMedium),
                  const SizedBox(height: 8),
                  Text(
                    "We've received your identity and business documents. "
                    'Our team is currently reviewing them to ensure a secure '
                    'environment for everyone on the platform.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 24),
                  _StatusTile(
                    icon: Icons.check_circle,
                    iconColor: context.fairbid.successText,
                    title: 'Profile Completed',
                    subtitle: 'All details submitted.',
                  ),
                  const SizedBox(height: 12),
                  _StatusTile(
                    icon: Icons.manage_search_outlined,
                    iconColor: theme.colorScheme.onSurfaceVariant,
                    title: 'Identity & Business',
                    subtitle: 'Under admin review.',
                  ),
                  const SizedBox(height: 16),
                  const InfoBanner(
                    icon: Icons.info_outline,
                    title: 'What can you do now?',
                    body: 'You can explore the marketplace and view available '
                        'jobs. However, bidding is temporarily locked until '
                        'your verification is complete.',
                  ),
                  const SizedBox(height: 24),
                  PrimaryButton(
                    label: 'Go to Home',
                    onPressed: () => context.go('/home'),
                  ),
                  const SizedBox(height: 12),
                  SecondaryButton(
                    label: 'Explore Jobs',
                    // The feed is outside the shell; seed the dashboard beneath it for back and nav.
                    onPressed: () {
                      context.go('/home');
                      context.push('/jobs');
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// What:   Hourglass inside a spinning ring on a tinted circle.
/// Input:  None.
/// Output: 120px decorative header.
class _ReviewSpinnerArt extends StatelessWidget {
  const _ReviewSpinnerArt();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 120,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: context.fairbid.subtleBlue,
            ),
          ),
          SizedBox(
            width: 88,
            height: 88,
            child: CircularProgressIndicator(
              strokeWidth: 6,
              color: context.fairbid.verified,
              backgroundColor: Colors.white,
            ),
          ),
          Icon(Icons.hourglass_top_rounded,
              color: context.fairbid.verified, size: 32),
        ],
      ),
    );
  }
}

/// What:   One status row with an icon, title and subtitle.
/// Input:  [icon], [iconColor], [title], [subtitle].
/// Output: AppCard row.
class _StatusTile extends StatelessWidget {
  const _StatusTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppCard(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Icon(icon, color: iconColor),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.labelLarge),
                Text(subtitle,
                    style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
