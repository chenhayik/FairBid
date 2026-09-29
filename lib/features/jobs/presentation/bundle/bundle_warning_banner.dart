import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';

/// Tinted warning row: icon + message, with enough contrast to read as a
/// warning rather than small amber-only text. Used on the bundle detail
/// screen for the "bids changed" notice and uncovered-task/warning notes.
class WarningBanner extends StatelessWidget {
  const WarningBanner(this.message, {super.key, this.trailing});

  final String message;

  /// Optional action, e.g. a "Refresh" button, placed after the text.
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
          // The icon keeps the amber tint; the body text uses onSurface -
          // warningText on this fill sat at ~3.4:1, short of the 4.5:1 body
          // text needs.
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
