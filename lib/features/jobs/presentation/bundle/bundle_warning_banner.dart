import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';

/// What:   Tinted warning row: icon, message and optional action.
/// Input:  [message]; [trailing] such as a Refresh button.
/// Output: Rendered banner.
class WarningBanner extends StatelessWidget {
  const WarningBanner(this.message, {super.key, this.trailing});

  final String message;

  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = context.fairbid.warningText;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.fairbid.warning.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Body text uses onSurface: warningText on this fill is ~3.4:1, below 4.5:1.
          Icon(Icons.warning_amber_rounded, color: accent, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurface),
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        ],
      ),
    );
  }
}
