import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'app_widgets.dart';

/// What:   Selectable card with an icon tile, a title, a subtitle and a check when chosen.
/// Input:  [icon], [title], [subtitle], [selected], [onTap] from the hosting screen's state.
/// Output: Rendered SelectableCard; calls [onTap] when pressed.
class IconChoiceCard extends StatelessWidget {
  const IconChoiceCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brand = context.fairbid.verified;
    return SelectableCard(
      selected: selected,
      onTap: onTap,
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: context.fairbid.subtleBlue,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: brand),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleLarge),
                Text(subtitle,
                    style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
          if (selected) Icon(Icons.check_circle, color: brand),
        ],
      ),
    );
  }
}
