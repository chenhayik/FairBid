import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../../../../core/widgets/form_widgets.dart';
import '../onboarding_controller.dart';

/// What:   Provider stage 4: display name, bio, skills, certificates and links.
/// Input:  [OnboardingController.data].
/// Output: Form; Save & Continue writes the fields back and saves.
class ProfileStep extends StatefulWidget {
  const ProfileStep({super.key});

  @override
  State<ProfileStep> createState() => _ProfileStepState();
}

class _ProfileStepState extends State<ProfileStep> {
  late final TextEditingController _displayName;
  late final TextEditingController _bio;
  final _skillInput = TextEditingController();
  final _linkInput = TextEditingController();

  @override
  void initState() {
    super.initState();
    final data = context.read<OnboardingController>().data;
    // Default to the business name, never overwriting a chosen display name.
    _displayName = TextEditingController(
        text: data.displayName.isNotEmpty ? data.displayName : data.businessName);
    _bio = TextEditingController(text: data.bio);
    _linkInput.text = data.portfolioLinks.isEmpty ? '' : data.portfolioLinks.first;
  }

  @override
  void dispose() {
    _displayName.dispose();
    _bio.dispose();
    _skillInput.dispose();
    _linkInput.dispose();
    super.dispose();
  }

  void _saveAndContinue() {
    final onboarding = context.read<OnboardingController>();
    final data = onboarding.data;
    data.displayName = _displayName.text.trim();
    data.bio = _bio.text.trim();
    data.portfolioLinks = [
      if (_linkInput.text.trim().isNotEmpty) _linkInput.text.trim(),
    ];
    onboarding.saveAndContinue();
  }

  @override
  Widget build(BuildContext context) {
    final onboarding = context.watch<OnboardingController>();
    final theme = Theme.of(context);
    final data = onboarding.data;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Build your profile', style: theme.textTheme.headlineMedium),
        const SizedBox(height: 8),
        Text(
          'Tell us a bit about yourself. Clients read this to see what you '
          'do and how much experience you have.',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 24),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppTextField(
                controller: _displayName,
                label: 'Display Name',
                hint: 'E.g. Ah Seng or Seng Aircon Services',
              ),
              AppTextField(
                controller: _bio,
                label: 'Short Bio',
                hint: 'Briefly describe your experience and the jobs you '
                    'usually do...',
                maxLines: 4,
                maxLength: 250,
              ),
              AppTextField(
                controller: _skillInput,
                label: 'Skills',
                hint: 'Add a skill and press Enter...',
                onSubmitted: (value) {
                  onboarding.addSkill(value);
                  _skillInput.clear();
                },
              ),
              if (data.skills.isNotEmpty) const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final skill in data.skills)
                    InputChip(
                      label: Text(skill),
                      onDeleted: () => onboarding.removeSkill(skill),
                      backgroundColor: context.fairbid.subtleBlue,
                      side: BorderSide.none,
                    ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: context.fairbid.subtleBlue,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.workspace_premium_outlined,
                      size: 20, color: context.fairbid.verified),
                  const SizedBox(width: 8),
                  Text('Trust Boosters', style: theme.textTheme.titleLarge),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'These sections are optional, but certificates (e.g. a '
                'wireman or gas licence) and links help clients trust you.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              Text('Certificates (Optional)', style: theme.textTheme.labelLarge),
              const SizedBox(height: 8),
              UploadBox(
                compact: true,
                onTap: onboarding.pickCertificate,
                busy: onboarding.isUploading('certificate'),
                icon: Icons.upload_file_outlined,
                hint: 'PDF, JPG, PNG up to 5MB',
                pickedName: data.certificateUrls.isEmpty
                    ? null
                    : '${data.certificateUrls.length} file(s) added',
              ),
              const SizedBox(height: 16),
              AppTextField(
                controller: _linkInput,
                label: 'Portfolio Links (Optional)',
                hint: 'Facebook page or Google Maps listing link',
                prefixIcon: Icons.link,
                keyboardType: TextInputType.url,
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        PrimaryButton(
          label: 'Save & Continue',
          trailingIcon: Icons.arrow_forward,
          busy: onboarding.isBusy,
          onPressed: _saveAndContinue,
        ),
      ],
    );
  }
}
