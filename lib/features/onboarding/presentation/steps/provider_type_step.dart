import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../../domain/onboarding_data.dart';
import '../onboarding_controller.dart';

/// Stage 2 — "Choose Provider Type": Individual/Freelancer vs Registered
/// Business, each with its verification-requirement badge.
class ProviderTypeStep extends StatelessWidget {
  const ProviderTypeStep({super.key});

  @override
  Widget build(BuildContext context) {
    final onboarding = context.watch<OnboardingController>();
    final theme = Theme.of(context);
    final selected = onboarding.data.providerType;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Text('Choose Provider Type',
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineMedium),
        const SizedBox(height: 8),
        Text(
          'Select the legal structure that best describes how you operate '
          'on FairBid.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 24),
        _TypeCard(
          type: ProviderType.individual,
          icon: Icons.person_outline,
          description:
              'You operate as an independent professional. Ideal for tutors, '
              'freelance designers, consultants, and independent contractors.',
          badge: 'Identity Verification Required',
          badgeIcon: Icons.verified_user_outlined,
          selected: selected == ProviderType.individual,
        ),
        const SizedBox(height: 16),
        _TypeCard(
          type: ProviderType.business,
          icon: Icons.business_outlined,
          description:
              'You operate as a formally registered company (e.g., SSM '
              'registered). Ideal for agencies, established firms, and '
              'service companies.',
          badge: 'Business Verification Required',
          badgeIcon: Icons.badge_outlined,
          selected: selected == ProviderType.business,
        ),
        const SizedBox(height: 32),
        PrimaryButton(
          label: 'Continue',
          busy: onboarding.isBusy,
          onPressed:
              selected == null ? null : () => onboarding.saveAndContinue(),
        ),
        const SizedBox(height: 24),
        Text(
          '© 2026 FairBid. All payments processed in RM.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _TypeCard extends StatelessWidget {
  const _TypeCard({
    required this.type,
    required this.icon,
    required this.description,
    required this.badge,
    required this.badgeIcon,
    required this.selected,
  });

  final ProviderType type;
  final IconData icon;
  final String description;
  final String badge;
  final IconData badgeIcon;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SelectableCard(
      selected: selected,
      onTap: () =>
          context.read<OnboardingController>().selectProviderType(type),
      child: Column(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: context.fairbid.subtleBlue,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: context.fairbid.verified, size: 26),
          ),
          const SizedBox(height: 12),
          Text(type.label, style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            description,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          PillBadge(label: badge, icon: badgeIcon),
        ],
      ),
    );
  }
}
