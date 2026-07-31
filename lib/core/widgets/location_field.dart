import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Tappable row showing a picked location's label (or a [placeholder]),
/// styled to match [AppTextField] — used to launch `RegionPickerScreen`.
/// Shared by the post-job form and the onboarding steps that capture a
/// Penang-scoped location.
class LocationField extends StatelessWidget {
  const LocationField({
    super.key,
    required this.label,
    required this.placeholder,
    required this.onTap,
  });

  /// The current pick's composed label, or null/empty to show [placeholder].
  final String? label;
  final String placeholder;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: context.fairbid.borderSubtle),
        ),
        child: Row(
          children: [
            Icon(Icons.location_on_outlined, color: context.fairbid.verified),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label == null || label!.isEmpty ? placeholder : label!,
                style: theme.textTheme.bodyLarge,
              ),
            ),
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    );
  }
}
