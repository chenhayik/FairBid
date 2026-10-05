import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../../../core/location/region.dart';
import '../../../../core/location/region_picker_screen.dart';
import '../../../../core/util/ssm_number.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../../../../core/widgets/form_widgets.dart';
import '../../../../core/widgets/location_field.dart';
import '../../../auth/presentation/validators.dart';
import '../requestor_onboarding_controller.dart';

/// Stage 2 - the requestor's contact details and (for businesses) company info.
class DetailsStep extends StatefulWidget {
  const DetailsStep({super.key});

  @override
  State<DetailsStep> createState() => _DetailsStepState();
}

class _DetailsStepState extends State<DetailsStep> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _fullName;
  late final TextEditingController _phone;
  late final TextEditingController _companyName;
  late final TextEditingController _ssmNumber;

  @override
  void initState() {
    super.initState();
    final data = context.read<RequestorOnboardingController>().data;
    _fullName = TextEditingController(text: data.fullName);
    _phone = TextEditingController(text: data.phone);
    _companyName = TextEditingController(text: data.companyName);
    _ssmNumber = TextEditingController(text: data.ssmNumber);
  }

  @override
  void dispose() {
    _fullName.dispose();
    _phone.dispose();
    _companyName.dispose();
    _ssmNumber.dispose();
    super.dispose();
  }

  /// Opens the Penang-scoped picker and stores both the composed label
  /// ([RequestorOnboardingData.location]) and the structured pick behind it.
  Future<void> _pickLocation() async {
    final onboarding = context.read<RequestorOnboardingController>();
    final data = onboarding.data;
    final picked = await RegionPickerScreen.show(
      context,
      initialCenter: data.lat == null || data.lng == null
          ? null
          : LatLng(data.lat!, data.lng!),
      initialRegion: data.districtCode == null
          ? null
          : Region(
              districtCode: data.districtCode!,
              districtName: Region.districtNameFor(data.districtCode!),
              town: data.town,
            ),
    );
    if (picked == null) return;
    setState(() {
      data.location = picked.address;
      data.districtCode = picked.region.districtCode;
      data.town = picked.region.town;
      data.lat = picked.lat;
      data.lng = picked.lng;
    });
  }

  void _saveAndContinue() {
    if (!_formKey.currentState!.validate()) return;
    final onboarding = context.read<RequestorOnboardingController>();
    if (onboarding.data.districtCode == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Please pick a location.')));
      return;
    }
    final ssm = SsmNumber.parse(_ssmNumber.text);
    onboarding.data
      ..fullName = _fullName.text.trim()
      ..phone = _phone.text.trim()
      ..companyName = _companyName.text.trim()
      ..ssmNumber = _ssmNumber.text.trim()
      ..ssmNumberNormalized = ssm?.normalized ?? '';
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
          busy: onboarding.isUploading('avatar'),
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
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Default Location', style: theme.textTheme.labelLarge),
                    const SizedBox(height: 6),
                    LocationField(
                      label: data.location,
                      placeholder: 'Pick your default location in Penang',
                      onTap: _pickLocation,
                    ),
                    const SizedBox(height: 4),
                    Text('New jobs will default to this area.',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant)),
                  ],
                ),
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
                  hint: 'e.g. 201903350205 or 003058656-T',
                  prefixIcon: Icons.tag_outlined,
                  helperText: 'As printed on your SSM certificate',
                  validator: SsmNumber.validate,
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
