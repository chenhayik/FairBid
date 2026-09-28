import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../../../../core/widgets/form_widgets.dart';
import '../../../onboarding/data/document_storage_repository.dart';
import '../../data/job_repository.dart';

/// Bottom sheet where the accepted provider of a dependent task records the
/// site handover before starting: a required note plus up to 5 photos.
class RecordHandoverSheet extends StatefulWidget {
  const RecordHandoverSheet({super.key, required this.jobId});

  final String jobId;

  /// Opens the sheet. Resolves to `true` when a handover was recorded.
  static Future<bool?> show(BuildContext context, {required String jobId}) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => RecordHandoverSheet(jobId: jobId),
    );
  }

  @override
  State<RecordHandoverSheet> createState() => _RecordHandoverSheetState();
}

class _RecordHandoverSheetState extends State<RecordHandoverSheet> {
  static const _maxPhotos = 5;

  final _note = TextEditingController();
  final _picker = ImagePicker();
  final _photoUrls = <String>[];
  bool _uploading = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _addPhoto() async {
    if (_uploading) return;
    final storage = context.read<DocumentStorageRepository>();

    final XFile? file;
    try {
      file = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        imageQuality: 85,
      );
    } catch (_) {
      setState(() => _error = 'Could not open the photo picker.');
      return;
    }
    if (file == null || !mounted) return;

    setState(() {
      _uploading = true;
      _error = null;
    });
    try {
      final url = await storage.uploadHandoverPhoto(
        jobId: widget.jobId,
        file: file,
      );
      if (mounted) setState(() => _photoUrls.add(url));
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Could not upload the photo. Please try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  void _removePhoto(String url) {
    setState(() => _photoUrls.remove(url));
    context
        .read<DocumentStorageRepository>()
        .deleteByUrl(url)
        .catchError((_) {});
  }

  Future<void> _submit() async {
    final note = _note.text.trim();
    if (note.isEmpty) {
      setState(() => _error = 'Describe the handover.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<JobRepository>().recordHandover(
        jobId: widget.jobId,
        note: note,
        photoUrls: _photoUrls,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message ?? 'Something went wrong. Please try again.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Could not record the handover. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Record Handover', style: theme.textTheme.headlineMedium),
            const SizedBox(height: 4),
            Text(
              'Note what the site looked like when you took it over.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            if (_error != null) ErrorBanner(_error!),
            AppTextField(
              controller: _note,
              label: 'Handover note',
              hint: 'What condition is the site in, what was already done…',
              maxLines: 4,
            ),
            const SizedBox(height: 16),
            _HandoverPhotoRow(
              urls: _photoUrls,
              uploading: _uploading,
              canAdd: _photoUrls.length < _maxPhotos && !_busy,
              onAdd: _addPhoto,
              onRemove: _removePhoto,
            ),
            const SizedBox(height: 16),
            PrimaryButton(
              label: 'Submit',
              busy: _busy,
              onPressed: _uploading ? null : _submit,
            ),
          ],
        ),
      ),
    );
  }
}

/// Photo thumbnails plus an add-photo tile (up to 5 photos).
class _HandoverPhotoRow extends StatelessWidget {
  const _HandoverPhotoRow({
    required this.urls,
    required this.uploading,
    required this.canAdd,
    required this.onAdd,
    required this.onRemove,
  });

  final List<String> urls;
  final bool uploading;
  final bool canAdd;
  final VoidCallback onAdd;
  final ValueChanged<String> onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('PHOTOS (OPTIONAL)', style: theme.textTheme.labelMedium),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final url in urls)
              Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(
                      url,
                      width: 72,
                      height: 72,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) => Container(
                        width: 72,
                        height: 72,
                        color: context.fairbid.borderSubtle,
                        child: Icon(
                          Icons.broken_image_outlined,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 0,
                    right: 0,
                    child: InkWell(
                      onTap: () => onRemove(url),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(
                          Icons.close,
                          size: 18,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            if (canAdd)
              InkWell(
                onTap: uploading ? null : onAdd,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: context.fairbid.subtleBlue,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: context.fairbid.borderSubtle),
                  ),
                  child: uploading
                      ? const Center(
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : Icon(
                          Icons.add_a_photo_outlined,
                          color: context.fairbid.verified,
                        ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
