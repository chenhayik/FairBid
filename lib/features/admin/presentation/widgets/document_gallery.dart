import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../../domain/pending_verification.dart';

/// What:   Gallery of labelled document or evidence images.
/// Input:  [documents]; shared by the verification and dispute detail screens.
/// Output: Tiles that open a zoomable full-screen viewer, or an empty state.
class DocumentGallery extends StatelessWidget {
  const DocumentGallery({
    super.key,
    required this.documents,
    this.emptyTitle = 'No documents uploaded',
    this.emptyMessage = 'Nothing was attached.',
  });

  final List<VerificationDocument> documents;
  final String emptyTitle;
  final String emptyMessage;

  @override
  Widget build(BuildContext context) {
    if (documents.isEmpty) {
      return AppCard(
        child: EmptyState(
          icon: Icons.image_not_supported_outlined,
          title: emptyTitle,
          message: emptyMessage,
        ),
      );
    }
    return Column(
      children: [
        for (final doc in documents)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _DocumentTile(document: doc),
          ),
      ],
    );
  }
}

/// What:   Thumbnail row for one document.
/// Input:  [document], a VerificationDocument (pending_verification.dart).
/// Output: Label, 64px thumbnail and "Tap to view full size"; tap opens _DocumentViewer.
class _DocumentTile extends StatelessWidget {
  const _DocumentTile({required this.document});

  final VerificationDocument document;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppCard(
        onTap: () => _DocumentViewer.show(context, document),
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.network(
                document.url,
                width: 64,
                height: 64,
                cacheWidth: (64 * MediaQuery.devicePixelRatioOf(context)).round(),
                fit: BoxFit.cover,
                loadingBuilder: (context, child, progress) => progress == null
                    ? child
                    : _thumbPlaceholder(context, const CircularProgressIndicator(
                        strokeWidth: 2)),
                errorBuilder: (context, _, _) => _thumbPlaceholder(
                    context, Icon(Icons.broken_image_outlined,
                        color: theme.colorScheme.onSurfaceVariant)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(document.label, style: theme.textTheme.labelLarge),
                  const SizedBox(height: 2),
                  Text('Tap to view full size',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                ],
              ),
            ),
            Icon(Icons.open_in_full_rounded,
                size: 18, color: context.fairbid.verified),
          ],
        ),
      );
  }

  /// What:   Square 64px box shown while a thumbnail loads or fails.
  /// Input:  [child], a spinner or broken-image icon.
  /// Output: Tinted container with [child] centred.
  Widget _thumbPlaceholder(BuildContext context, Widget child) => Container(
        width: 64,
        height: 64,
        alignment: Alignment.center,
        color: context.fairbid.subtleBlue,
        child: SizedBox(width: 24, height: 24, child: Center(child: child)),
      );
}

/// What:   Full-screen, pinch-to-zoom viewer for a single document image.
/// Input:  [document]; opened through [show].
/// Output: Dialog with zoomable image (0.5x to 4x), label and close button.
class _DocumentViewer extends StatelessWidget {
  const _DocumentViewer({required this.document});

  final VerificationDocument document;

  /// What:   Opens the full-screen viewer for [document].
  /// Input:  [document], a VerificationDocument.
  /// Output: Dark dialog route that completes when closed.
  static Future<void> show(
      BuildContext context, VerificationDocument document) {
    return showDialog(
      context: context,
      barrierColor: Colors.black87,
      builder: (_) => _DocumentViewer(document: document),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      backgroundColor: Colors.transparent,
      child: Stack(
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 4,
              child: Center(
                child: Image.network(
                  document.url,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const Icon(
                      Icons.broken_image_outlined,
                      color: Colors.white,
                      size: 64),
                ),
              ),
            ),
          ),
          Positioned(
            top: 8,
            left: 8,
            child: SafeArea(
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  Text(document.label,
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
