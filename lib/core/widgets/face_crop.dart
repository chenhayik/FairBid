import 'package:flutter/material.dart';

import '../../features/onboarding/domain/face_box.dart';

/// What:   Where to place the full image so only the padded face box shows in a [size]-wide window.
/// Input:  A FaceBox and the window size.
/// Output: Image size and offset; pure maths, testable without pixels.
class FaceCropLayout {
  const FaceCropLayout({
    required this.imageW,
    required this.imageH,
    required this.cropH,
    required this.left,
    required this.top,
  });

  final double imageW, imageH, cropH, left, top;

  /// Pads [box] by 20% per side (within the image) so the whole head shows.
  static FaceCropLayout of(FaceBox box, double size) {
    final l = (box.left - box.width * 0.2).clamp(0.0, 1.0);
    final t = (box.top - box.height * 0.2).clamp(0.0, 1.0);
    final w = (box.left + box.width * 1.2).clamp(0.0, 1.0) - l;
    final h = (box.top + box.height * 1.2).clamp(0.0, 1.0) - t;
    final imageW = size / w;
    final imageH = imageW / box.aspect;
    return FaceCropLayout(
      imageW: imageW,
      imageH: imageH,
      cropH: h * imageH,
      left: -l * imageW,
      top: -t * imageH,
    );
  }
}

/// What:   The face from a photo when its [box] is known, else the whole photo squared off.
/// Input:  [url], optional [box], [size].
/// Output: A square image.
class FaceCrop extends StatelessWidget {
  const FaceCrop({super.key, required this.url, this.box, this.size = 140});

  final String url;
  final FaceBox? box;
  final double size;

  @override
  Widget build(BuildContext context) {
    final b = box;
    final layout = b == null ? null : FaceCropLayout.of(b, size);
    final window = Size(size, layout?.cropH ?? size);
    final theme = Theme.of(context);

    // Cropped images sit in a huge offset box; pin loading/error states to the visible window.
    Widget inWindow(Widget child) => OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: 0,
          minHeight: 0,
          maxWidth: window.width,
          maxHeight: window.height,
          child: Transform.translate(
            offset: Offset(-(layout?.left ?? 0), -(layout?.top ?? 0)),
            child: SizedBox.fromSize(
              size: window,
              child: ColoredBox(
                color: theme.colorScheme.surfaceContainerHighest,
                child: Center(child: child),
              ),
            ),
          ),
        );

    final image = Image.network(
      url,
      fit: layout == null ? BoxFit.cover : BoxFit.fill,
      loadingBuilder: (_, child, progress) => progress == null
          ? child
          : inWindow(const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2))),
      errorBuilder: (_, _, _) =>
          inWindow(const Icon(Icons.broken_image_outlined)),
    );

    return ClipRect(
      child: SizedBox.fromSize(
        size: window,
        child: layout == null
            ? image
            : Stack(
                clipBehavior: Clip.hardEdge,
                children: [
                  Positioned(
                    left: layout.left,
                    top: layout.top,
                    width: layout.imageW,
                    height: layout.imageH,
                    child: image,
                  ),
                ],
              ),
      ),
    );
  }
}
