import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../../../core/location/location_picker_screen.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/util/money.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../../../../core/widgets/form_widgets.dart';
import '../../../auth/presentation/auth_controller.dart';
import '../../../auth/presentation/validators.dart';
import '../../../onboarding/data/document_storage_repository.dart';
import '../../../onboarding/presentation/steps/service_step.dart';
import '../../data/assist_repository.dart';
import '../../data/job_repository.dart';
import '../../domain/job.dart';
import 'post_job_controller.dart';

/// Requestor form for posting a new job. Owns a scoped [PostJobController] so
/// state resets each time the screen is opened.
class PostJobScreen extends StatelessWidget {
  const PostJobScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (ctx) => PostJobController(
        ctx.read<JobRepository>(),
        ctx.read<DocumentStorageRepository>(),
        ctx.read<AssistRepository>(),
      ),
      child: const _PostJobView(),
    );
  }
}

class _PostJobView extends StatefulWidget {
  const _PostJobView();

  @override
  State<_PostJobView> createState() => _PostJobViewState();
}

class _PostJobViewState extends State<_PostJobView> {
  final _formKey = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _description = TextEditingController();
  final _address = TextEditingController();
  final _budgetMin = TextEditingController();
  final _budgetMax = TextEditingController();
  bool _hourly = false;
  bool _showOptional = false;
  DateTime? _deadline;

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _address.dispose();
    _budgetMin.dispose();
    _budgetMax.dispose();
    super.dispose();
  }

  Future<void> _pickLocation() async {
    final controller = context.read<PostJobController>();
    final existing = controller.location;
    final picked = await LocationPickerScreen.show(
      context,
      initial: existing == null
          ? null
          : LatLng(existing.lat, existing.lng),
    );
    if (picked == null) return;
    controller.setLocation(picked);
    _address.text = picked.address;
  }

  /// Opens a date picker for the optional bidding deadline (tomorrow through
  /// ~90 days out). The picked date is normalised to end-of-day (23:59:59) so
  /// choosing "today" — the day after tomorrow's midnight boundary aside —
  /// never reads as already expired.
  Future<void> _pickDeadline() async {
    final tomorrow = DateTime.now().add(const Duration(days: 1));
    final firstDate = DateTime(tomorrow.year, tomorrow.month, tomorrow.day);
    final picked = await showDatePicker(
      context: context,
      initialDate: _deadline ?? firstDate,
      firstDate: firstDate,
      lastDate: firstDate.add(const Duration(days: 90)),
    );
    if (picked == null) return;
    setState(() => _deadline =
        DateTime(picked.year, picked.month, picked.day, 23, 59, 59));
  }

  void _clearDeadline() => setState(() => _deadline = null);

  Future<void> _submit() async {
    final controller = context.read<PostJobController>();
    final auth = context.read<AuthController>();
    if (!_formKey.currentState!.validate()) return;
    if (controller.location == null) {
      _snack('Please pick a location on the map.');
      return;
    }
    final user = auth.user!;
    final job = Job(
      id: '',
      requestorId: user.uid,
      requestorName: user.displayName ?? 'Requestor',
      title: _title.text.trim(),
      description: _description.text.trim(),
      category: controller.category!,
      location: JobLocation(
        lat: controller.location!.lat,
        lng: controller.location!.lng,
        address: _address.text.trim().isEmpty
            ? controller.location!.address
            : _address.text.trim(),
      ),
      budget: JobBudget(
        minSen: parseRmToSen(_budgetMin.text),
        maxSen: parseRmToSen(_budgetMax.text),
        hourly: _hourly,
      ),
      photoUrls: List.of(controller.photoUrls),
      deadline: _deadline,
    );
    final id = await controller.submit(job);
    if (id != null && mounted) {
      _snack('Job posted!');
      context.pop(); // back to home; the job shows in Active Jobs
    }
  }

  void _snack(String message) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message)));

  /// Gemini description helper: expands whatever rough note is in the
  /// description field into an editable draft. Failures are soft — the form
  /// works identically without the assist.
  Future<void> _suggestDescription() async {
    final controller = context.read<PostJobController>();
    if (controller.category == null) {
      _snack('Pick a category first so the suggestion fits.');
      return;
    }
    final rough = _description.text.trim();
    if (rough.length < 3) {
      _snack('Type a rough note first — e.g. "leaking pipe under sink".');
      return;
    }
    final suggestion = await controller.suggestDescription(rough);
    if (!mounted) return;
    if (suggestion == null) {
      _snack('Couldn\'t get a suggestion right now.');
      return;
    }
    _description.text = suggestion;
    _snack('Draft written — edit it to match your situation.');
  }

  /// Gemini fair-price guide: fetches an indicative RM range shown beside the
  /// budget fields. Nothing is auto-filled — the user taps "Use this".
  Future<void> _suggestPrice() async {
    final controller = context.read<PostJobController>();
    if (controller.category == null) {
      _snack('Pick a category first.');
      return;
    }
    final description = _description.text.trim();
    if (description.length < 3) {
      _snack('Describe the job first, then ask for a price range.');
      return;
    }
    await controller.suggestPrice(description);
    if (!mounted) return;
    if (context.read<PostJobController>().priceHint == null) {
      _snack('Couldn\'t get a suggestion right now.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<PostJobController>();
    final theme = Theme.of(context);
    final uid = context.read<AuthController>().user?.uid ?? '';

    return Scaffold(
      appBar: AppBar(title: const Text('Post a New Job')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Provide details so professionals can understand what you '
                  'need.',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 24),
                if (controller.errorMessage != null)
                  ErrorBanner(controller.errorMessage!),
                Text('Category', style: theme.textTheme.labelLarge),
                const SizedBox(height: 6),
                DropdownButtonFormField<String>(
                  initialValue: controller.category,
                  hint: const Text('Select a category...'),
                  items: [
                    for (final c in kServiceCategories)
                      DropdownMenuItem(value: c, child: Text(c)),
                  ],
                  onChanged: controller.setCategory,
                  validator: (v) => v == null ? 'Pick a category.' : null,
                ),
                const SizedBox(height: 16),
                AppTextField(
                  controller: _title,
                  label: 'Job Title',
                  hint: 'e.g. Fix leaking sink pipe',
                  textInputAction: TextInputAction.next,
                  validator: (v) => Validators.required(v, 'Title'),
                ),
                AppTextField(
                  controller: _description,
                  label: 'Description',
                  hint: 'Describe what needs to be done, the problem, and any '
                      'specific requirements...',
                  maxLines: 4,
                  validator: (v) => Validators.required(v, 'Description'),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: _AssistButton(
                    label: 'Help me write this',
                    busy: controller.assistingDescription,
                    onPressed: controller.isBusy ? null : _suggestDescription,
                  ),
                ),
                _PhotoAssistHint(
                  hasPhoto: controller.photoUrls.isNotEmpty,
                  onAddPhoto: () => setState(() => _showOptional = true),
                ),
                _LocationField(
                  address: controller.location == null ? null : _address.text,
                  onTap: _pickLocation,
                ),
                if (controller.location != null) ...[
                  const SizedBox(height: 12),
                  AppTextField(
                    controller: _address,
                    label: 'Location label',
                    hint: 'e.g. Bangsar, Kuala Lumpur',
                  ),
                ],
                const SizedBox(height: 8),
                _DeadlineField(
                  deadline: _deadline,
                  onTap: _pickDeadline,
                  onClear: _clearDeadline,
                ),
                const SizedBox(height: 8),
                _OptionalToggle(
                  expanded: _showOptional,
                  onTap: () =>
                      setState(() => _showOptional = !_showOptional),
                ),
                if (_showOptional)
                  _OptionalDetails(
                    controller: controller,
                    uid: uid,
                    budgetMin: _budgetMin,
                    budgetMax: _budgetMax,
                    hourly: _hourly,
                    onHourly: (v) => setState(() => _hourly = v),
                    onSuggestPrice: controller.isBusy ? null : _suggestPrice,
                  ),
                const SizedBox(height: 24),
                PrimaryButton(
                  label: 'Post Job',
                  busy: controller.isBusy,
                  onPressed: _submit,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LocationField extends StatelessWidget {
  const _LocationField({required this.address, required this.onTap});
  final String? address;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: context.fairbid.borderSubtle),
          ),
          child: Row(
            children: [
              Icon(Icons.location_on_outlined,
                  color: context.fairbid.verified),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  address == null || address!.isEmpty
                      ? 'Pick location on map'
                      : address!,
                  style: theme.textTheme.bodyLarge,
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

/// Optional bidding-deadline picker, modelled on [_LocationField]'s tappable
/// row: shows "Set a bidding deadline" or the chosen date, with a clear (×)
/// affordance once one is set.
class _DeadlineField extends StatelessWidget {
  const _DeadlineField({
    required this.deadline,
    required this.onTap,
    required this.onClear,
  });

  final DateTime? deadline;
  final VoidCallback onTap;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: context.fairbid.borderSubtle),
        ),
        child: Row(
          children: [
            Icon(Icons.timer_outlined, color: context.fairbid.verified),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                deadline == null
                    ? 'Set a bidding deadline'
                    : 'Bidding closes ${DateFormat.yMMMd().format(deadline!)}',
                style: theme.textTheme.bodyLarge,
              ),
            ),
            if (deadline != null)
              IconButton(
                tooltip: 'Remove deadline',
                icon: const Icon(Icons.close),
                onPressed: onClear,
              )
            else
              const Icon(Icons.chevron_right),
          ],
        ),
      ),
    );
  }
}

class _OptionalToggle extends StatelessWidget {
  const _OptionalToggle({required this.expanded, required this.onTap});
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onTap,
      icon: Icon(expanded ? Icons.remove : Icons.add),
      label: const Text('Add optional details (Budget, Photos)'),
    );
  }
}

class _OptionalDetails extends StatelessWidget {
  const _OptionalDetails({
    required this.controller,
    required this.uid,
    required this.budgetMin,
    required this.budgetMax,
    required this.hourly,
    required this.onHourly,
    required this.onSuggestPrice,
  });

  final PostJobController controller;
  final String uid;
  final TextEditingController budgetMin;
  final TextEditingController budgetMax;
  final bool hourly;
  final ValueChanged<bool> onHourly;
  final VoidCallback? onSuggestPrice;

  /// Sen → an editable field value, e.g. 12050 → "120.50".
  static String _senToField(int sen) => (sen / 100).toStringAsFixed(2);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final priceHint = controller.priceHint;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child:
                  Text('Budget (optional)', style: theme.textTheme.labelLarge),
            ),
            _AssistButton(
              label: 'Suggest a fair range',
              busy: controller.assistingPrice,
              onPressed: onSuggestPrice,
            ),
          ],
        ),
        if (priceHint != null)
          Row(
            children: [
              Expanded(
                child: Text(
                  'Similar jobs: ${formatRm(priceHint.minSen)} – '
                  '${formatRm(priceHint.maxSen)}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
              TextButton(
                onPressed: () {
                  budgetMin.text = _senToField(priceHint.minSen);
                  budgetMax.text = _senToField(priceHint.maxSen);
                },
                child: const Text('Use this'),
              ),
            ],
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: AppTextField(
                controller: budgetMin,
                label: 'Min (RM)',
                hint: '0.00',
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: AppTextField(
                controller: budgetMax,
                label: 'Max (RM)',
                hint: '0.00',
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
              ),
            ),
          ],
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Hourly rate'),
          value: hourly,
          onChanged: onHourly,
        ),
        const SizedBox(height: 8),
        Text('Photos (optional)', style: theme.textTheme.labelLarge),
        const SizedBox(height: 8),
        if (controller.photoUrls.isNotEmpty)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final url in controller.photoUrls)
                _PhotoThumb(
                  url: url,
                  onRemove: () => controller.removePhoto(url),
                ),
            ],
          ),
        const SizedBox(height: 8),
        UploadBox(
          compact: true,
          onTap: () => controller.addPhoto(uid),
          icon: Icons.add_photo_alternate_outlined,
          hint: 'JPEG or PNG',
        ),
      ],
    );
  }
}

/// Nudges the requestor to attach a photo so the Gemini assists (description
/// and price) can analyse it — the assists pass the first photo to the model,
/// so a photo of the actual problem yields a sharper draft and estimate. Once
/// a photo is attached it flips to a confirmation.
class _PhotoAssistHint extends StatelessWidget {
  const _PhotoAssistHint({required this.hasPhoto, required this.onAddPhoto});
  final bool hasPhoto;
  final VoidCallback onAddPhoto;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (hasPhoto) {
      return Padding(
        padding: const EdgeInsets.only(left: 12, bottom: 4),
        child: Row(
          children: [
            Icon(Icons.auto_awesome,
                size: 14, color: context.fairbid.verified),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'The AI reads your photo for a sharper draft and price.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      );
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: onAddPhoto,
        icon: const Icon(Icons.add_photo_alternate_outlined, size: 16),
        label: const Text('Add a photo for a more accurate estimate'),
      ),
    );
  }
}

/// A small "✨ assist" text button that swaps its icon for a spinner while
/// the suggestion call is in flight. Used by both Gemini assists.
class _AssistButton extends StatelessWidget {
  const _AssistButton({
    required this.label,
    required this.busy,
    required this.onPressed,
  });

  final String label;
  final bool busy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: busy ? null : onPressed,
      icon: busy
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.auto_awesome, size: 18),
      label: Text(label),
    );
  }
}

class _PhotoThumb extends StatelessWidget {
  const _PhotoThumb({required this.url, required this.onRemove});
  final String url;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.network(
            url,
            width: 80,
            height: 80,
            fit: BoxFit.cover,
            loadingBuilder: (context, child, loadingProgress) {
              if (loadingProgress == null) return child;
              return const SizedBox(
                width: 80,
                height: 80,
                child: Center(
                    child: CircularProgressIndicator(strokeWidth: 2)),
              );
            },
            errorBuilder: (context, error, stackTrace) => Container(
              width: 80,
              height: 80,
              color: context.fairbid.borderSubtle,
              child: Icon(Icons.broken_image_outlined,
                  color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ),
        Positioned(
          right: 0,
          top: 0,
          child: Semantics(
            button: true,
            label: 'Remove photo',
            child: InkWell(
              onTap: onRemove,
              customBorder: const CircleBorder(),
              child: const SizedBox(
                width: 48,
                height: 48,
                child: Align(
                  alignment: Alignment.topRight,
                  child: Padding(
                    padding: EdgeInsets.all(4),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                          color: Colors.black54, shape: BoxShape.circle),
                      child: Padding(
                        padding: EdgeInsets.all(2),
                        child:
                            Icon(Icons.close, size: 16, color: Colors.white),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
