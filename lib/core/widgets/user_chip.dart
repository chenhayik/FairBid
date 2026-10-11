import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'user_avatar.dart';

/// What:   Tappable user identity (avatar, name, optional subtitle) and the app's one entry into a public profile.
/// Input:  [uid], [name], optional [photoUrl] and [subtitle]; [showAvatar] / [showChevron] allow compact text-only use.
/// Output: Pushes `/users/{uid}` on tap.
class UserChip extends StatelessWidget {
  const UserChip({
    super.key,
    required this.uid,
    required this.name,
    this.photoUrl,
    this.subtitle,
    this.avatarRadius,
    this.showAvatar = true,
    this.showChevron = true,
    this.nameStyle,
    this.subtitleMaxLines = 1,
  });

  final String uid;
  final String name;
  final String? photoUrl;

  /// Second line under the name, e.g. a trust label; null hides it.
  final String? subtitle;

  final double? avatarRadius;
  final bool showAvatar;
  final bool showChevron;

  /// Name style; null uses the ambient style (right for an AppBar title).
  final TextStyle? nameStyle;

  final int subtitleMaxLines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      label: "View $name's profile",
      child: InkWell(
        onTap: () => context.push('/users/$uid'),
        borderRadius: BorderRadius.circular(8),
        child: Row(
          children: [
            if (showAvatar) ...[
              UserAvatar(photoUrl: photoUrl, radius: avatarRadius),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: nameStyle,
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      maxLines: subtitleMaxLines,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            if (showChevron) ...[
              const SizedBox(width: 4),
              Icon(
                Icons.chevron_right,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
