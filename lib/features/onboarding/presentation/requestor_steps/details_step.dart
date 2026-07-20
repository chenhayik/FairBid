import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/widgets/app_widgets.dart';
import '../../../../core/widgets/form_widgets.dart';
import '../../../auth/presentation/validators.dart';
import '../requestor_onboarding_controller.dart';

/// Stage 2 — the requestor's contact details and (for businesses) company info.
class DetailsStep extends StatefulWidget {
  const DetailsStep({super.key});

  @override
  State<DetailsStep> createState() => _DetailsStepState();
}

class _DetailsStepState extends State<DetailsStep> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _fullName;
  late final TextEditingController _phone;
  late final TextEditingController _location;
  late final TextEditingController _companyName;
  late final TextEditingController _ssmNumber;

  @override
  void initState() {
    super.initState();
    final data = context.read<RequestorOnboardingController>().data;
    _fullName = TextEditingController(text: data.fullName);
    _phone = TextEditingController(text: data.phone);
    _location = TextEditingController(text: data.location);
    _companyName = TextEditingController(text: data.companyName);
    _ssmNumber = TextEditingController(text: data.ssmNumber);
  }

  @override
  void dispose() {
    _fullName.dispose();
    _phone.dispose();
    _location.dispose();
    _companyName.dispose();
    _ssmNumber.dispose();
    super.dispose();
  }

  void _saveAndContinue() {
    if (!_formKey.currentState!.validate()) return;
    final onboarding = context.read<RequestorOnboardingController>();
    onboarding.data
      ..fullName = _fullName.text.trim()
      ..phone = _phone.text.trim()
      ..location = _location.text.trim()
      ..companyName = _companyName.text.trim()
      ..ssmNumber = _ssmNumber.text.trim();
    onboarding.saveAndContinue();
  }

  @override
  Widget build(BuildContext context) {
    final onboarding = context.watch<RequestorOnboardingController>();
    final theme = Theme.of(context);
    final data = onboarding.data;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Your details', style: theme.textTheme.headlineMedium),
        const SizedBox(height: 8),
        Text(
          'Providers use this to understand who they are working with and how '
          'to reach you.',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 24),
        if (onboarding.errorMessage != null)
          ErrorBanner(onboarding.errorMessage!),
        Text('Profile Photo (Optional)', style: theme.textTheme.labelLarge),
        const SizedBox(height: 8),
        UploadBox(
          compact: true,
          onTap: onboarding.pickProfilePhoto,
          icon: Icons.add_a_photo_outlined,
          hint: 'JPEG or PNG',
          pickedName: data.profilePhotoUrl == null ? null : 'Photo added',
        ),
        const SizedBox(height: 16),
        Form(
          key: _formKey,
          child: Column(
            children: [
              AppTextField(
                controller: _fullName,
                label: 'Full Name',
                hint: 'Jane Doe',
                prefixIcon: Icons.person_outline,
                textInputAction: TextInputAction.next,
                validator: (v) => Validators.required(v, 'Name'),
              ),
              AppTextField(
                controller: _phone,
                label: 'Phone Number',
                hint: 'e.g. 012-345 6789',
                prefixIcon: Icons.phone_outlined,
                keyboardType: TextInputType.phone,
                textInputAction: TextInputAction.next,
                helperText: 'Used to connect you with providers.',
                validator: (v) => Validators.required(v, 'Phone number'),
              ),
              AppTextField(
                controller: _location,
                label: 'Default Location',
                hint: 'e.g. Kuala Lumpur',
                prefixIcon: Icons.location_on_outlined,
                textInputAction: TextInputAction.next,
                helperText: 'New jobs will default to this area.',
                validator: (v) => Validators.required(v, 'Location'),
              ),
              if (data.isBusiness) ...[
                AppTextField(
                  controller: _companyName,
                  label: 'Company Name',
                  hint: 'e.g. Acme Sdn Bhd',
                  prefixIcon: Icons.business_outlined,
                  textInputAction: TextInputAction.next,
                  validator: (v) => Validators.required(v, 'Company name'),
                ),
                AppTextField(
                  controller: _ssmNumber,
                  label: 'SSM Registration Number',
                  hint: 'e.g. 202301234567',
                  prefixIcon: Icons.tag_outlined,
                  validator: (v) => Validators.required(v, 'SSM number'),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 8),
        PrimaryButton(
          label: 'Continue',
          trailingIcon: Icons.arrow_forward,
          busy: onboarding.isBusy,
          onPressed: _saveAndContinue,
        ),
      ],
    );
  }
}
