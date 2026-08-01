import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A user's avatar: their network photo when [photoUrl] is set, else the
/// standard `person_outline` placeholder. If the network image fails to
/// load, falls back to the placeholder rather than showing a broken image.
///
/// Used everywhere a user's photo appears — the profile header, bids, job
/// cards and the conversation list — so the fallback behaviour stays
/// consistent across the app.
class UserAvatar extends StatefulWidget {
  const UserAvatar({super.key, this.photoUrl, this.radius, this.iconSize});

  /// The user's `profilePhotoUrl` (or a denormalised snapshot of it, e.g. on
  /// a `Bid` or `Conversation`). Null or empty shows the placeholder.
  final String? photoUrl;

  /// Passed straight to the underlying [CircleAvatar]; null uses its default.
  final double? radius;

  /// Passed straight to the placeholder [Icon]; null uses its default.
  final double? iconSize;

  @override
  State<UserAvatar> createState() => _UserAvatarState();
}

class _UserAvatarState extends State<UserAvatar> {
  /// Set once the photo fails to load, so the fallback icon is shown instead
  /// of a broken image.
  bool _failed = false;

  @override
  void didUpdateWidget(covariant UserAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A newly saved/loaded photo deserves a fresh chance to load.
    if (oldWidget.photoUrl != widget.photoUrl) _failed = false;
  }

  @override
  Widget build(BuildContext context) {
    final photo = widget.photoUrl;
    final hasPhoto = photo != null && photo.isNotEmpty && !_failed;
    return CircleAvatar(
      radius: widget.radius,
      backgroundColor: context.fairbid.subtleBlue,
      backgroundImage: hasPhoto ? NetworkImage(photo) : null,
      onBackgroundImageError: hasPhoto
          ? (_, _) {
              if (mounted) setState(() => _failed = true);
            }
          : null,
      child: hasPhoto
          ? null
          : Icon(Icons.person_outline,
              size: widget.iconSize, color: context.fairbid.verified),
    );
  }
}
