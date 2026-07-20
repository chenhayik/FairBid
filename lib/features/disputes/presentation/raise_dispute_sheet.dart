import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/util/money.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../../core/widgets/form_widgets.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../jobs/domain/milestone.dart';
import '../../onboarding/data/document_storage_repository.dart';
import '../data/dispute_repository.dart';

/// Bottom sheet where a job participant disputes a funded/delivered
/// [milestone]: a statement of the problem plus optional photo evidence.
/// Submitting freezes the milestone and opens the dispute for admin review.
class RaiseDisputeSheet extends StatefulWidget {
  const RaiseDisputeSheet({super.key, required this.milestone});

  final Milestone milestone;

  /// Opens the sheet. Resolves to `true` when a dispute was raised.
  static Future<bool?> show(BuildContext context,
      {required Milestone milestone}) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => RaiseDisputeSheet(milestone: milestone),
    );
  }

  @override
  State<RaiseDisputeSheet> createState() => _RaiseDisputeSheetState();
}

class _RaiseDisputeSheetState extends State<RaiseDisputeSheet> {
  static const _maxPhotos = 3;

  final _statement = TextEditingController();
  final _picker = ImagePicker();
  final _evidenceUrls = <String>[];
  bool _uploading = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _statement.dispose();
    super.dispose();
  }

  Future<void> _addPhoto() async {
    final uid = context.read<AuthController>().user?.uid;
    final storage = context.read<DocumentStorageRepository>();
    if (uid == null || _uploading) return;

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
      final url = await storage.uploadDisputeEvidence(uid: uid, file: file);
      if (mounted) setState(() => _evidenceUrls.add(url));
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not upload the photo. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  void _removePhoto(String url) {
    setState(() => _evidenceUrls.remove(url));
    // Best-effort cleanup of the abandoned upload.
    context.read<DocumentStorageRepository>().deleteByUrl(url).catchError((_) {});
  }

  Future<void> _submit() async {
    final statement = _statement.text.trim();
    if (statement.isEmpty) {
      setState(() => _error = 'Describe the issue.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<DisputeRepository>().raiseDispute(
            jobId: widget.milestone.jobId,
            milestoneId: widget.milestone.id,
            statement: statement,
            evidenceUrls: _evidenceUrls,
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
        _error = 'Could not submit the dispute. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Raise a Dispute', style: theme.textTheme.headlineMedium),
            const SizedBox(height: 4),
            Text(
              '"${widget.milestone.description}" — '
              '${formatRm(widget.milestone.amountSen)} in escrow.',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            const InfoBanner(
              icon: Icons.gavel_rounded,
              title: 'What happens next',
              body: 'This milestone is frozen while a FairBid admin reviews '
                  'both sides and the job chat, then releases or refunds the '
                  'escrowed amount. This cannot be undone.',
            ),
            const SizedBox(height: 16),
            if (_error != null) ErrorBanner(_error!),
            AppTextField(
              controller: _statement,
              label: 'What went wrong?',
              hint: 'Describe the issue factually — what was agreed, what '
                  'was delivered…',
              maxLines: 4,
            ),
            const SizedBox(height: 16),
            _EvidenceRow(
              urls: _evidenceUrls,
              uploading: _uploading,
              canAdd: _evidenceUrls.length < _maxPhotos && !_busy,
              onAdd: _addPhoto,
              onRemove: _removePhoto,
            ),
            const SizedBox(height: 16),
            PrimaryButton(
              label: 'Submit Dispute',
              busy: _busy,
              onPressed: _uploading ? null : _submit,
            ),
          ],
        ),
      ),
    );
  }
}

/// Evidence thumbnails plus an add-photo tile (up to three photos).
class _EvidenceRow extends StatelessWidget {
  const _EvidenceRow({
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
        Text('PHOTO EVIDENCE (OPTIONAL)', style: theme.textTheme.labelMedium),
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
                    child: Image.network(url,
                        width: 72, height: 72, fit: BoxFit.cover),
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
                        child: const Icon(Icons.close,
                            size: 18, color: Colors.white),
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
                      : Icon(Icons.add_a_photo_outlined,
                          color: context.fairbid.verified),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
