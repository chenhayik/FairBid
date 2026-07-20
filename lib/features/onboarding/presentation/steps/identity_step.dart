import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../../../../core/widgets/form_widgets.dart';
import '../../../../core/widgets/image_source_sheet.dart';
import '../onboarding_controller.dart';

/// Stage 3 — "Verify your identity": ID + selfie uploads and tips.
class IdentityStep extends StatelessWidget {
  const IdentityStep({super.key});

  /// Lets the user pick camera or gallery, then runs [upload] with the choice.
  Future<void> _chooseAndUpload(
    BuildContext context,
    String title,
    Future<void> Function(ImageSource) upload,
  ) async {
    final source = await showImageSourceSheet(context, title: title);
    if (source != null) await upload(source);
  }

  @override
  Widget build(BuildContext context) {
    final onboarding = context.watch<OnboardingController>();
    final theme = Theme.of(context);
    final data = onboarding.data;
    final canContinue = data.idDocumentUrl != null && data.selfieUrl != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Verify your identity', style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(
          'To ensure a safe environment for all users, we require a valid '
          'government-issued ID. This is a one-time process to unlock full '
          'bidding capabilities.',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        const InfoBanner(
          icon: Icons.verified_user,
          title: 'Unlock "Identity Verified" Badge',
          body: 'Profiles with this badge receive 3x more responses from '
              'clients. Your details are encrypted and securely stored.',
        ),
        const SizedBox(height: 24),
        Text('Upload Documents', style: theme.textTheme.labelLarge),
        const SizedBox(height: 12),
        Text('Front of ID (MyKad or Passport)',
            style: theme.textTheme.bodyMedium),
        const SizedBox(height: 8),
        UploadBox(
          onTap: () => _chooseAndUpload(
              context, 'Add your ID', onboarding.pickIdDocument),
          icon: Icons.badge_outlined,
          hint: 'Take a photo or choose one\nJPEG, PNG up to 10MB',
          pickedName: data.idDocumentUrl == null ? null : 'Document uploaded',
        ),
        const SizedBox(height: 16),
        Text('Selfie holding your ID', style: theme.textTheme.bodyMedium),
        const SizedBox(height: 8),
        UploadBox(
          onTap: () =>
              _chooseAndUpload(context, 'Add your selfie', onboarding.pickSelfie),
          icon: Icons.portrait_outlined,
          hint: 'Take a photo or choose one\nMake sure face and ID are clear',
          pickedName: data.selfieUrl == null ? null : 'Photo uploaded',
        ),
        const SizedBox(height: 24),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.lightbulb_outline,
                      size: 18, color: context.fairbid.warning),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('Tips for a successful verification',
                        style: theme.textTheme.labelLarge),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const CheckBullet(
                  'Ensure good lighting without glare or shadows.'),
              const CheckBullet(
                  'All text on the document must be clearly legible.'),
              const CheckBullet(
                  'Do not crop or cut off the edges of the ID.'),
            ],
          ),
        ),
        const SizedBox(height: 24),
        PrimaryButton(
          label: 'Continue',
          trailingIcon: Icons.arrow_forward,
          busy: onboarding.isBusy,
          onPressed:
              canContinue ? () => onboarding.saveAndContinue() : null,
        ),
      ],
    );
  }
}
