import 'package:flutter/material.dart';

/// Full-screen photo viewer: swipe between [photoUrls] (`PageView`), pinch to
/// zoom and pan each one (`InteractiveViewer`) - built entirely from Flutter
/// SDK widgets, no new dependency. Pushed as a full-screen dialog route by
/// [show], which `job_detail_screen.dart`'s Photos list calls on tap.
class PhotoViewerScreen extends StatefulWidget {
  const PhotoViewerScreen({
    super.key,
    required this.photoUrls,
    required this.initialIndex,
  });

  final List<String> photoUrls;
  final int initialIndex;

  /// Pushes the viewer as a full-screen dialog route, starting at
  /// [initialIndex].
  static Future<void> show(
    BuildContext context, {
    required List<String> photoUrls,
    int initialIndex = 0,
  }) {
    return Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) =>
          PhotoViewerScreen(photoUrls: photoUrls, initialIndex: initialIndex),
    ));
  }

  @override
  State<PhotoViewerScreen> createState() => _PhotoViewerScreenState();
}

class _PhotoViewerScreenState extends State<PhotoViewerScreen> {
  late final PageController _pageController =
      PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          tooltip: 'Close',
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text('${_index + 1} / ${widget.photoUrls.length}'),
        centerTitle: true,
      ),
      body: PageView.builder(
        controller: _pageController,
        itemCount: widget.photoUrls.length,
        onPageChanged: (i) => setState(() => _index = i),
        // Same loading/error builders as job_detail_screen.dart's Photos
        // list, lifted here so a broken or slow image degrades identically.
        itemBuilder: (context, i) => InteractiveViewer(
          minScale: 1,
          maxScale: 4,
          child: Center(
            child: Image.network(
              widget.photoUrls[i],
              fit: BoxFit.contain,
              loadingBuilder: (context, child, loadingProgress) {
                if (loadingProgress == null) return child;
                return const Center(
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                );
              },
              errorBuilder: (context, error, stackTrace) => const Center(
                child: Icon(Icons.broken_image_outlined,
                    color: Colors.white54, size: 48),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
