import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/widgets/app_widgets.dart';
import '../../../../core/widgets/icon_choice_card.dart';
import '../../domain/requestor_onboarding_data.dart';
import '../requestor_onboarding_controller.dart';

/// What:   Requestor stage 1: hiring as an individual or a business.
/// Input:  [RequestorOnboardingController.data].type.
/// Output: Two IconChoiceCards and Continue.
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
          'Tell us who is posting jobs so we can set up the right '
          'verification.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 24),
        IconChoiceCard(
          icon: Icons.person_outline,
          title: RequestorType.individual.label,
          subtitle:
              'You hire providers for your own personal or household needs.',
          selected: selected == RequestorType.individual,
          onTap: () => onboarding.selectType(RequestorType.individual),
        ),
        const SizedBox(height: 16),
        IconChoiceCard(
          icon: Icons.business_outlined,
          title: RequestorType.business.label,
          subtitle: 'You hire on behalf of a company. We collect company '
              'details for proper invoicing.',
          selected: selected == RequestorType.business,
          onTap: () => onboarding.selectType(RequestorType.business),
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
