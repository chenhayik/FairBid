import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../../../../core/widgets/form_widgets.dart';
import '../../../auth/presentation/auth_controller.dart';
import '../requestor_onboarding_controller.dart';

/// What:   Requestor stage 3: optional verification document, escrow intro and finish actions.
/// Input:  [RequestorOnboardingController]; [AuthController] to refresh the user.
/// Output: Finish completes onboarding (with the document under review); Skip clears the document first.
class VerifyStep extends StatelessWidget {
  const VerifyStep({super.key});

  Future<void> _finish(
    BuildContext context, {
    required bool withVerification,
  }) async {
    final onboarding = context.read<RequestorOnboardingController>();
    final auth = context.read<AuthController>();
    if (!withVerification) onboarding.data.clientDocumentUrl = null;
    final ok = await onboarding.finish();
    if (!ok || !context.mounted) return;
    await auth.refreshUser();
    if (context.mounted) context.go('/home');
  }

  @override
  Widget build(BuildContext context) {
    final onboarding = context.watch<RequestorOnboardingController>();
    final theme = Theme.of(context);
    final data = onboarding.data;

    final docLabel =
        data.isBusiness ? 'SSM / Company Registration' : 'Government ID';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Get verified', style: theme.textTheme.headlineMedium),
        const SizedBox(height: 8),
        Text(
          'Optional, but verified clients look more trustworthy and attract '
          'more competitive bids from providers.',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        InfoBanner(
          icon: Icons.verified_user,
          title: 'Verified ${data.isBusiness ? 'Business' : 'Client'} Badge',
          body: 'Upload your $docLabel to earn a trust badge. Your details are '
              'encrypted and stored securely.',
        ),
        const SizedBox(height: 16),
        if (onboarding.errorMessage != null)
          ErrorBanner(onboarding.errorMessage!),
        Text('$docLabel (Optional)', style: theme.textTheme.labelLarge),
        const SizedBox(height: 8),
        UploadBox(
          onTap: onboarding.pickVerificationDocument,
          busy: onboarding.isUploading('client_document'),
          icon: Icons.badge_outlined,
          hint: 'JPEG, PNG up to 10MB',
          pickedName:
              data.clientDocumentUrl == null ? null : 'Document uploaded',
        ),
        const SizedBox(height: 24),
        AppCard(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.account_balance_wallet_outlined,
                  color: context.fairbid.verified),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('How paying works', style: theme.textTheme.labelLarge),
                    const SizedBox(height: 4),
                    Text(
                      'You fund each job from your in-app wallet. The amount is '
                      'held safely in escrow and only released to the provider '
                      'once you confirm the work is complete.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        PrimaryButton(
          label: 'Finish',
          trailingIcon: Icons.check,
          busy: onboarding.isBusy,
          onPressed: () => _finish(context, withVerification: true),
        ),
        const SizedBox(height: 12),
        SecondaryButton(
          label: 'Skip for now',
          onPressed: onboarding.isBusy
              ? null
              : () => _finish(context, withVerification: false),
        ),
      ],
    );
  }
}
