import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'user_avatar.dart';

/// A tappable user identity — avatar, name and an optional subtitle (e.g.
/// `★4.8 (12) · Verified`) — that pushes `/users/{uid}` on tap. The app's one
/// reusable entry point into a public profile, used from a bid card's
/// identity row, a chat thread's app-bar title and a review's author name.
///
/// [showAvatar] and [showChevron] can be turned off for compact, text-only
/// contexts (e.g. a reviewer's name inline in `ReviewCard`) while keeping the
/// same tap target and navigation everywhere else.
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
  });

  /// The profile this chip opens, via `/users/$uid`.
  final String uid;
  final String name;
  final String? photoUrl;

  /// A short second line under the name, e.g. a trust label. Null hides it.
  final String? subtitle;

  /// Passed straight to the inner [UserAvatar]; null uses its default.
  final double? avatarRadius;
  final bool showAvatar;
  final bool showChevron;

  /// Style for the name line. Null defers to the ambient text style, so this
  /// reads correctly dropped straight into an `AppBar` title.
  final TextStyle? nameStyle;

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
                      maxLines: 1,
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
