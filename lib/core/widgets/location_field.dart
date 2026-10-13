import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// What:   Tappable form-style row showing a picked value or a placeholder.
/// Input:  [label] (null/empty shows [placeholder]); optional [icon], [trailing].
/// Output: Rendered row with a ripple; calls [onTap] when pressed.
/// Notes:  Used for Penang locations, addresses and deadlines.
class LocationField extends StatelessWidget {
  const LocationField({
    super.key,
    required this.label,
    required this.placeholder,
    required this.onTap,
    this.icon = Icons.location_on_outlined,
    this.trailing,
  });

  final String? label;
  final String placeholder;
  final VoidCallback onTap;
  final IconData icon;

  /// Replaces the default chevron.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(8);
    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: context.fairbid.borderSubtle),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(icon, color: context.fairbid.verified),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label == null || label!.isEmpty ? placeholder : label!,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
              trailing ?? const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}
