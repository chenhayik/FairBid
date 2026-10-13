import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/widgets/app_widgets.dart';
import '../../../auth/presentation/auth_controller.dart';
import '../onboarding_controller.dart';

/// What:   Provider stage 6: payout explainer and submit for review.
/// Input:  [OnboardingController]; [AuthController] to refresh the user.
/// Output: Save for Later / Submit for Review. The payout method is added before the first withdrawal.
class PayoutStep extends StatelessWidget {
  const PayoutStep({super.key});

  Future<void> _saveForLater(BuildContext context) async {
    final saved = await context.read<OnboardingController>().saveDraft();
    if (saved && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Progress saved.')));
    }
  }

  Future<void> _submit(BuildContext context) async {
    final onboarding = context.read<OnboardingController>();
    final auth = context.read<AuthController>();
    final submitted = await onboarding.submitForReview();
    // Refresh so status 'pending' switches to the pending screen.
    if (submitted) await auth.refreshUser();
  }

  @override
  Widget build(BuildContext context) {
    final onboarding = context.watch<OnboardingController>();
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text("How you'll get paid", style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(
          'Clients pay into escrow and it is released to your FairBid '
          'balance when they approve the work.',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        const InfoBanner(
          icon: Icons.account_balance_wallet_outlined,
          leftAccent: true,
          title: 'No bank details needed yet',
          body: 'Before your first withdrawal you add a DuitNow ID (mobile '
              "or MyKad, works with Touch 'n Go eWallet) or a bank account, "
              'under Earnings.',
        ),
        const SizedBox(height: 24),
        if (onboarding.errorMessage != null)
          ErrorBanner(onboarding.errorMessage!),
        SecondaryButton(
          label: 'Save for Later',
          onPressed: () => _saveForLater(context),
        ),
        const SizedBox(height: 12),
        PrimaryButton(
          label: 'Submit for Review',
          trailingIcon: Icons.verified_outlined,
          busy: onboarding.isBusy,
          onPressed: () => _submit(context),
        ),
      ],
    );
  }
}
