import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../../domain/requestor_onboarding_data.dart';
import '../requestor_onboarding_controller.dart';

/// Stage 1 - how the requestor hires: as an individual or as a business.
class AccountTypeStep extends StatelessWidget {
  const AccountTypeStep({super.key});

  @override
  Widget build(BuildContext context) {
    final onboarding = context.watch<RequestorOnboardingController>();
    final theme = Theme.of(context);
    final selected = onboarding.data.type;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Text('How will you hire?',
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineMedium),
        const SizedBox(height: 8),
        Text(
          'Tell us who is posting jobs so we can tailor invoices and '
          'verification.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 24),
        _TypeCard(
          type: RequestorType.individual,
          icon: Icons.person_outline,
          description:
              'You hire providers for your own personal or household needs.',
          selected: selected == RequestorType.individual,
        ),
        const SizedBox(height: 16),
        _TypeCard(
          type: RequestorType.business,
          icon: Icons.business_outlined,
          description:
              'You hire on behalf of a company. We collect company details '
              'for proper invoicing.',
          selected: selected == RequestorType.business,
        ),
        const SizedBox(height: 32),
        PrimaryButton(
          label: 'Continue',
          trailingIcon: Icons.arrow_forward,
          busy: onboarding.isBusy,
          onPressed:
              selected == null ? null : () => onboarding.saveAndContinue(),
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
    required this.selected,
  });

  final RequestorType type;
  final IconData icon;
  final String description;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brand = context.fairbid.verified;
    return SelectableCard(
      selected: selected,
      onTap: () =>
          context.read<RequestorOnboardingController>().selectType(type),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: context.fairbid.subtleBlue,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: brand),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(type.label, style: theme.textTheme.titleLarge),
                Text(description,
                    style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
          if (selected) Icon(Icons.check_circle, color: brand),
        ],
      ),
    );
  }
}
