import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../theme/app_theme.dart';

/// Asks whether to take a new photo or pick an existing one, so uploads are
/// never locked to a single source. Resolves to the chosen [ImageSource], or
/// null if the sheet was dismissed.
Future<ImageSource?> showImageSourceSheet(
  BuildContext context, {
  String title = 'Add a photo',
}) {
  return showModalBottomSheet<ImageSource>(
    context: context,
    useSafeArea: true,
    builder: (context) {
      final theme = Theme.of(context);
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
              child: Text(title, style: theme.textTheme.titleLarge),
            ),
            ListTile(
              leading: Icon(Icons.photo_camera_outlined,
                  color: context.fairbid.verified),
              title: const Text('Take a photo'),
              onTap: () => Navigator.of(context).pop(ImageSource.camera),
            ),
            ListTile(
              leading: Icon(Icons.photo_library_outlined,
                  color: context.fairbid.verified),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.of(context).pop(ImageSource.gallery),
            ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
}
