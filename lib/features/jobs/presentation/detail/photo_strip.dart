import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import 'photo_viewer_screen.dart';

/// What:   Horizontal strip of photo thumbnails.
/// Input:  [photoUrls] from job.photoUrls.
/// Output: Thumbnails; tapping one opens [PhotoViewerScreen].
class PhotoStrip extends StatelessWidget {
  const PhotoStrip({super.key, required this.photoUrls});

  final List<String> photoUrls;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 120,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: photoUrls.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) => InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => PhotoViewerScreen.show(
            context,
            photoUrls: photoUrls,
            initialIndex: i,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.network(
              photoUrls[i],
              width: 120,
              height: 120,
              // Without cacheWidth each thumbnail decodes at the full 1600px (~7.7MB).
              cacheWidth: (120 * MediaQuery.devicePixelRatioOf(context))
                  .round(),
              fit: BoxFit.cover,
              loadingBuilder: (context, child, loadingProgress) {
                if (loadingProgress == null) return child;
                return const SizedBox(
                  width: 120,
                  height: 120,
                  child: Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                );
              },
              errorBuilder: (context, error, stackTrace) => Container(
                width: 120,
                height: 120,
                color: context.fairbid.borderSubtle,
                child: Icon(
                  Icons.broken_image_outlined,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
