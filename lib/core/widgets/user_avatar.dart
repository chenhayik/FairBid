import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// What:   A user's avatar, used wherever a photo appears.
/// Input:  [photoUrl] (the profile photo or a denormalised copy); null or empty shows the placeholder.
/// Output: The network photo, or the `person_outline` placeholder when unset or failed to load.
class UserAvatar extends StatefulWidget {
  const UserAvatar({super.key, this.photoUrl, this.radius, this.iconSize});

  final String? photoUrl;

  final double? radius;

  final double? iconSize;

  @override
  State<UserAvatar> createState() => _UserAvatarState();
}

class _UserAvatarState extends State<UserAvatar> {
  /// Set once the photo fails to load.
  bool _failed = false;

  @override
  void didUpdateWidget(covariant UserAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new photo URL gets a fresh load attempt.
    if (oldWidget.photoUrl != widget.photoUrl) _failed = false;
  }

  @override
  Widget build(BuildContext context) {
    final photo = widget.photoUrl;
    final hasPhoto = photo != null && photo.isNotEmpty && !_failed;
    return CircleAvatar(
      radius: widget.radius,
      backgroundColor: context.fairbid.subtleBlue,
      // Decode at display size, not the photo's full resolution.
      backgroundImage: hasPhoto
          ? ResizeImage(NetworkImage(photo),
              width: ((widget.radius ?? 20) * 2 *
                      MediaQuery.devicePixelRatioOf(context))
                  .round())
          : null,
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
