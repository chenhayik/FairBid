import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../../../core/location/region.dart';
import '../../../../core/location/region_picker_screen.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/util/money.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../../../../core/widgets/form_widgets.dart';
import '../../../../core/widgets/location_field.dart';
import '../onboarding_controller.dart';

/// Service categories offered on FairBid (Malaysian market).
const kServiceCategories = [
  'Cleaning',
  'Plumbing',
  'Electrical',
  'Aircon Servicing',
  'Home Repair',
  'Moving & Delivery',
  'Tutoring',
  'IT & Tech Support',
  'Design & Creative',
  'Other',
];

/// Stage 5 — "Define Your Services": category, coverage area, rate, portfolio.
class ServiceStep extends StatefulWidget {
  const ServiceStep({super.key});

  @override
  State<ServiceStep> createState() => _ServiceStepState();
}

class _ServiceStepState extends State<ServiceStep> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _rate;

  @override
  void initState() {
    super.initState();
    final data = context.read<OnboardingController>().data;
    _rate = TextEditingController(text: data.hourlyRate);
  }

  @override
  void dispose() {
    _rate.dispose();
    super.dispose();
  }

  /// Opens the Penang-scoped picker and stores both the composed label
  /// ([OnboardingData.coverageArea]) and the structured pick behind it.
  Future<void> _pickLocation() async {
    final onboarding = context.read<OnboardingController>();
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
      data.coverageArea = picked.address;
      data.districtCode = picked.region.districtCode;
      data.town = picked.region.town;
      data.lat = picked.lat;
      data.lng = picked.lng;
    });
  }

  void _saveAndContinue() {
    if (!_formKey.currentState!.validate()) return;
    final onboarding = context.read<OnboardingController>();
    if (onboarding.data.districtCode == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please pick a coverage area.')));
      return;
    }
    onboarding.data.hourlyRate = _rate.text.trim();
    onboarding.saveAndContinue();
  }

  @override
  Widget build(BuildContext context) {
    final onboarding = context.watch<OnboardingController>();
    final theme = Theme.of(context);
    final data = onboarding.data;

    return Form(
      key: _formKey,
      child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Define Your Services', style: theme.textTheme.titleLarge),
              const SizedBox(height: 16),
              Text('Primary Service Category',
                  style: theme.textTheme.labelLarge),
              const SizedBox(height: 6),
              DropdownButtonFormField<String>(
                initialValue: data.category,
                hint: const Text('Select a category...'),
                items: [
                  for (final category in kServiceCategories)
                    DropdownMenuItem(value: category, child: Text(category)),
                ],
                onChanged: (value) => setState(() => data.category = value),
                validator: (v) =>
                    v == null ? 'Please select a category.' : null,
              ),
              const SizedBox(height: 16),
              Text('Coverage Area', style: theme.textTheme.labelLarge),
              const SizedBox(height: 6),
              LocationField(
                label: data.coverageArea,
                placeholder: 'Pick your coverage area in Penang',
                onTap: _pickLocation,
              ),
              const SizedBox(height: 16),
              AppTextField(
                controller: _rate,
                label: 'Indicative Hourly Rate (RM)',
                hint: '50.00',
                prefixText: 'RM ',
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                validator: (v) {
                  if ((v ?? '').trim().isEmpty) return null; // optional
                  return parseRmToSen(v) == null
                      ? 'Enter a valid amount.'
                      : null;
                },
              ),
              Row(
                children: [
                  Text('Portfolio', style: theme.textTheme.labelLarge),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: onboarding.pickPortfolioImage,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Add Item'),
                  ),
                ],
              ),
              Text(
                'Showcase your past work to build trust with potential '
                'clients.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              UploadBox(
                onTap: onboarding.pickPortfolioImage,
                icon: Icons.add_photo_alternate_outlined,
                hint: 'PNG, JPG up to 5MB',
              ),
              for (final url in data.portfolioImageUrls) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    border: Border.all(color: context.fairbid.borderSubtle),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: Image.network(
                          url,
                          width: 40,
                          height: 40,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => Icon(
                            Icons.broken_image_outlined,
                            size: 20,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text('Portfolio image',
                            style: theme.textTheme.bodyMedium),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 20),
                        onPressed: () =>
                            onboarding.removePortfolioImage(url),
                      ),
                    ],
                  ),
                ),
              ],
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
      ),
    );
  }
}
