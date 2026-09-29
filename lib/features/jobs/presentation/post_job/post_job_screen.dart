import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../../../core/config/platform_config.dart';
import '../../../../core/util/bundle_templates.dart';
import '../../../../core/util/service_categories.dart';
import '../../../../core/location/address_hint.dart';
import '../../../../core/location/region.dart';
import '../../../../core/location/region_picker_screen.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/util/money.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../../../../core/widgets/form_widgets.dart';
import '../../../../core/widgets/location_field.dart';
import '../../../auth/presentation/auth_controller.dart';
import '../../../auth/presentation/validators.dart';
import '../../../onboarding/data/document_storage_repository.dart';
import '../../data/assist_repository.dart';
import '../../data/bundle_repository.dart';
import '../../data/job_repository.dart';
import '../../domain/bundle.dart';
import '../../domain/job.dart';
import '../../domain/service_address.dart';
import '../detail/job_video_player.dart';
import '../detail/service_address_sheet.dart';
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
        ctx.read<BundleRepository>(),
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
  DateTime? _deadline;

  /// Task 1's own field keys, so a failed submit can find and scroll to the
  /// first field with an error - mirrors each added task's own keys.
  final _task1CategoryKey = GlobalKey<FormFieldState<String>>();
  final _task1TitleKey = GlobalKey<FormFieldState<String>>();
  final _task1DescriptionKey = GlobalKey<FormFieldState<String>>();
  final _postingTitleKey = GlobalKey<FormFieldState<String>>();

  /// The tasks beyond the first, added with "Add another task". Empty for an
  /// ordinary single-task job, keeping that path unchanged until it isn't.
  final List<_TaskFields> _extraTasks = [];

  /// The bundled posting's own title and summary, asked for only in bundle
  /// mode - what a provider reads atop the bid sheet, above the tasks.
  final _postingTitle = TextEditingController();
  final _postingSummary = TextEditingController();

  bool get _isBundle => _extraTasks.isNotEmpty;

  /// Task 1's template-derived lot/dependency, set only by "Start from a
  /// template" and dropped together by "Clear template" - never by hand.
  String? _task1LotId;
  int? _task1StartsAfterIndex;
  int? _task1GapDays;

  /// True once a template has filled the tasks below, until "Clear
  /// template" - drives that action and each task card's dependency note.
  bool _templateApplied = false;

  /// True while the location shown is still the requestor's saved default
  /// (from onboarding) and hasn't been overridden by picking a new one.
  bool _locationDefaulted = false;

  /// The location [_seededHint] was resolved for, and the pending lookup
  /// itself. A fresh pick already carries its own hint (the picker geocodes
  /// on confirm); a location seeded from the requestor's saved default has
  /// none, so `_addressHint` resolves one and caches it here.
  PickedLocation? _hintFor;
  Future<AddressHint?>? _seededHint;

  @override
  void initState() {
    super.initState();
    final user = context.read<AuthController>().user;
    if (user == null || !user.hasDefaultLocation) return;
    final region = Region(
      districtCode: user.defaultDistrictCode!,
      districtName: Region.districtNameFor(user.defaultDistrictCode!),
      town: user.defaultTown,
    );
    final controller = context.read<PostJobController>();
    controller.seedLocation(PickedLocation(
      lat: user.defaultLat!,
      lng: user.defaultLng!,
      address: region.label,
      region: region,
    ));
    _address.text = region.label;
    _locationDefaulted = true;
    // Warm the pin's reverse geocode now rather than on the tap, so the
    // address sheet opens already filled in.
    _addressHint(controller.location);
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _address.dispose();
    _budgetMin.dispose();
    _budgetMax.dispose();
    _postingTitle.dispose();
    _postingSummary.dispose();
    for (final task in _extraTasks) {
      task.dispose();
    }
    super.dispose();
  }

  Future<void> _pickLocation() async {
    final controller = context.read<PostJobController>();
    final existing = controller.location;
    final picked = await RegionPickerScreen.show(
      context,
      initialCenter:
          existing == null ? null : LatLng(existing.lat, existing.lng),
      initialRegion: existing?.region,
    );
    if (picked == null || !mounted) return;
    controller.setLocation(picked);
    _address.text = picked.address;
    setState(() => _locationDefaulted = false);
  }

  /// The street-level suggestion for [location] - its own if it came from a
  /// fresh pick, otherwise a cached reverse geocode of its coordinates.
  Future<AddressHint?> _addressHint(PickedLocation? location) {
    if (location == null) return Future.value();
    if (location.addressHint != null) return Future.value(location.addressHint);
    if (!identical(_hintFor, location)) {
      _hintFor = location;
      _seededHint = reverseGeocode(LatLng(location.lat, location.lng));
    }
    return _seededHint!;
  }

  /// Opens the address sheet, pre-filling the town from the picked map
  /// location if any, else the requestor's saved default town, plus the
  /// street/postcode reverse-geocoded from the pin. Fully optional - posting
  /// still works without one.
  Future<void> _pickAddress() async {
    final controller = context.read<PostJobController>();
    final user = context.read<AuthController>().user;
    // Only worth resolving when adding an address from scratch - one the
    // requestor already entered always wins over the geocoder's guess.
    final hint = controller.pendingAddress == null
        ? await _addressHint(controller.location)
        : null;
    if (!mounted) return;
    final result = await ServiceAddressSheet.show(
      context,
      initial: controller.pendingAddress,
      defaultCity: controller.location?.region.town ?? user?.defaultTown,
      hint: hint,
    );
    if (result == null) return;
    controller.setAddress(result);
  }

  /// Opens a date picker for the optional bidding deadline (tomorrow through
  /// ~90 days out). The picked date is normalised to end-of-day (23:59:59) so
  /// choosing "today" - the day after tomorrow's midnight boundary aside -
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

  void _addTask() {
    final added = _TaskFields();
    setState(() => _extraTasks.add(added));
    // The button sits halfway down a long form, so without this the tap has
    // no visible result.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = added.key.currentContext;
      if (target == null) return;
      Scrollable.ensureVisible(target,
          duration: const Duration(milliseconds: 300), alignment: 0.1);
    });
  }

  void _removeTask(int index) =>
      setState(() => _extraTasks.removeAt(index).dispose());

  /// Whether the requestor has typed anything into task 1 or the extra tasks
  /// already - the "Replace your tasks with this template?" confirmation
  /// only fires when there's something to lose.
  bool get _hasTaskContent =>
      _title.text.trim().isNotEmpty ||
      _description.text.trim().isNotEmpty ||
      context.read<PostJobController>().category != null ||
      _extraTasks.isNotEmpty;

  /// Opens the template picker, then - only once a template is actually
  /// picked, and only if it would overwrite typed content - confirms before
  /// applying it. Confirming after picking (not before opening the sheet)
  /// means browsing templates never interrupts the requestor with a dialog
  /// they may not even need.
  Future<void> _pickTemplate() async {
    final template = await showModalBottomSheet<BundleTemplate>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const _TemplateSheet(),
    );
    if (template == null || !mounted) return;
    if (_hasTaskContent) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Replace your tasks with this template?'),
          content: const Text(
              'The tasks you\'ve typed so far will be replaced.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Replace'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    _applyTemplate(template);
  }

  /// Replaces task 1 and every extra task with [template]'s tasks (blank
  /// descriptions, for the requestor to fill in); lot/dependency carries over.
  void _applyTemplate(BundleTemplate template) {
    for (final task in _extraTasks) {
      task.dispose();
    }
    final first = template.tasks.first;
    context.read<PostJobController>().setCategory(first.category);
    setState(() {
      _extraTasks.clear();
      _title.text = first.title;
      _task1LotId = first.lotId;
      _task1StartsAfterIndex = first.startsAfter;
      _task1GapDays = first.gapDays;
      for (final t in template.tasks.skip(1)) {
        _extraTasks.add(_TaskFields()
          ..title.text = t.title
          ..category = t.category
          ..lotId = t.lotId
          ..startsAfterIndex = t.startsAfter
          ..gapDays = t.gapDays
          ..fromTemplate = true);
      }
      if (_postingTitle.text.trim().isEmpty) {
        _postingTitle.text = template.name;
      }
      _templateApplied = true;
    });
  }

  /// Drops every task's lot/dependency link, so the requestor can freely
  /// remove tasks again. The tasks themselves - titles, categories - stay.
  void _clearTemplate() {
    setState(() {
      _task1LotId = null;
      _task1StartsAfterIndex = null;
      _task1GapDays = null;
      for (final task in _extraTasks) {
        task.lotId = null;
        task.startsAfterIndex = null;
        task.gapDays = null;
        task.fromTemplate = false;
      }
      _templateApplied = false;
    });
  }

  /// The title of the task at [index] in the whole task list (0 = task 1),
  /// for the "Starts after ..." / "Same provider as ..." notes.
  String _titleAt(int index) {
    final title =
        index == 0 ? _title.text.trim() : _extraTasks[index - 1].title.text.trim();
    return title.isEmpty ? 'Task ${index + 1}' : title;
  }

  /// The other tasks sharing [lotId], by title, excluding the task at
  /// [myIndex] itself.
  List<String> _lotPartnerTitles(String lotId, int myIndex) {
    final titles = <String>[];
    if (myIndex != 0 && _task1LotId == lotId) titles.add(_titleAt(0));
    for (var i = 0; i < _extraTasks.length; i++) {
      if (myIndex != i + 1 && _extraTasks[i].lotId == lotId) {
        titles.add(_titleAt(i + 1));
      }
    }
    return titles;
  }

  /// The read-only dependency note shown under the task at [myIndex], or
  /// null when it carries no template link.
  String? _dependencyNote({
    required int myIndex,
    String? lotId,
    int? startsAfterIndex,
    int? gapDays,
  }) {
    final lines = <String>[];
    if (startsAfterIndex != null) {
      final after = _titleAt(startsAfterIndex);
      lines.add(gapDays != null && gapDays > 0
          ? 'Starts after $after, $gapDays day${gapDays == 1 ? '' : 's'} later'
          : 'Starts after $after');
    }
    if (lotId != null) {
      final partners = _lotPartnerTitles(lotId, myIndex);
      if (partners.isNotEmpty) {
        lines.add('Linked with ${partners.join(', ')} (same provider)');
      }
    }
    return lines.isEmpty ? null : lines.join('\n');
  }

  /// The posting summary to send when the requestor leaves it blank: the
  /// task titles, since `createBundle` requires a description regardless.
  String _composedSummary() {
    final titles = [
      _title.text.trim(),
      for (final task in _extraTasks) task.title.text.trim(),
    ].where((t) => t.isNotEmpty).toList();
    return '${titles.length} tasks: ${titles.join(', ')}.';
  }

  /// Scrolls the first invalid field into view and flags it with a snackbar -
  /// otherwise a failed validate() on this long form gives no feedback at all
  /// when every error lands off-screen.
  void _scrollToFirstError() {
    final keys = [
      _task1CategoryKey,
      _task1TitleKey,
      _task1DescriptionKey,
      for (final task in _extraTasks) ...[
        task.categoryKey,
        task.titleKey,
        task.descriptionKey,
      ],
      if (_isBundle) _postingTitleKey,
    ];
    for (final key in keys) {
      final state = key.currentState;
      final fieldContext = key.currentContext;
      if (state != null && state.hasError && fieldContext != null) {
        Scrollable.ensureVisible(
          fieldContext,
          duration: const Duration(milliseconds: 300),
          alignment: 0.2,
        );
        break;
      }
    }
    _snack('Some fields need attention');
  }

  Future<void> _submit() async {
    final controller = context.read<PostJobController>();
    final auth = context.read<AuthController>();
    if (!_formKey.currentState!.validate()) {
      _scrollToFirstError();
      return;
    }
    if (controller.location == null) {
      _snack('Please pick a location on the map.');
      return;
    }
    final user = auth.user!;
    final location = JobLocation(
      lat: controller.location!.lat,
      lng: controller.location!.lng,
      address: _address.text.trim().isEmpty
          ? controller.location!.address
          : _address.text.trim(),
      districtCode: controller.location!.region.districtCode,
      districtName: controller.location!.region.districtName,
      town: controller.location!.region.town,
    );
    if (_isBundle) {
      await _submitBundle(controller, location);
      return;
    }
    final job = Job(
      id: '',
      requestorId: user.uid,
      requestorName: user.displayName ?? 'Requestor',
      requestorPhotoUrl: user.profilePhotoUrl,
      title: _title.text.trim(),
      description: _description.text.trim(),
      category: controller.category!,
      location: location,
      budget: JobBudget(
        minSen: parseRmToSen(_budgetMin.text),
        maxSen: parseRmToSen(_budgetMax.text),
        hourly: _hourly,
      ),
      photoUrls: List.of(controller.photoUrls),
      videoUrl: controller.videoUrl,
      deadline: _deadline,
    );
    final id = await controller.submit(job);
    if (id != null && mounted) {
      unawaited(HapticFeedback.mediumImpact());
      _snack(controller.addressWarning ?? 'Job posted!');
      context.pop(); // back to home; the job shows in Active Jobs
    }
  }

  /// Posts every task as one bundle. Task 1 is the form's own fields, with
  /// its budget in "When & budget"; each added task carries its own.
  Future<void> _submitBundle(
      PostJobController controller, JobLocation location) async {
    final summary = _postingSummary.text.trim();
    final id = await controller.submitBundle(
      title: _postingTitle.text.trim(),
      description: summary.isEmpty ? _composedSummary() : summary,
      location: location,
      deadline: _deadline,
      tasks: [
        BundleTaskDraft(
          title: _title.text.trim(),
          description: _description.text.trim(),
          category: controller.category!,
          budget: JobBudget(
            minSen: parseRmToSen(_budgetMin.text),
            maxSen: parseRmToSen(_budgetMax.text),
            hourly: _hourly,
          ),
          lotId: _task1LotId,
          startsAfterIndex: _task1StartsAfterIndex,
          gapDays: _task1GapDays,
        ),
        for (final task in _extraTasks)
          BundleTaskDraft(
            title: task.title.text.trim(),
            description: task.description.text.trim(),
            category: task.category!,
            budget: JobBudget(
              minSen: parseRmToSen(task.budgetMin.text),
              maxSen: parseRmToSen(task.budgetMax.text),
              hourly: task.hourly,
            ),
            lotId: task.lotId,
            startsAfterIndex: task.startsAfterIndex,
            gapDays: task.gapDays,
          ),
      ],
    );
    if (id != null && mounted) {
      unawaited(HapticFeedback.mediumImpact());
      _snack('Bundle posted with ${_extraTasks.length + 1} tasks!');
      context.pop(); // back to home; each task shows in the feed
    }
  }

  void _snack(String message) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message)));

  /// One rough note becomes a whole draft: title, category, description and
  /// a budget range, filled into whatever the form has left empty.
  Future<void> _draftFromNote() async {
    final note = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const _DraftSheet(),
    );
    if (note == null || !mounted) return;
    if (note.length < 3) {
      _snack('Tell us a bit more first, e.g. "leaking pipe under sink".');
      return;
    }
    final draft = await context.read<PostJobController>().suggestDraft(note);
    if (!mounted) return;
    if (draft == null) {
      _snack('Couldn\'t draft it right now. Fill the form in yourself.');
      return;
    }
    _applyDraft(draft);
  }

  /// Fills only the fields the requestor has left empty, so a draft can never
  /// overwrite something they typed themselves.
  void _applyDraft(JobDraft draft) {
    final controller = context.read<PostJobController>();
    final filled = <String>[];
    if (_title.text.trim().isEmpty) {
      _title.text = draft.title;
      filled.add('title');
    }
    if (controller.category == null) {
      controller.setCategory(draft.category);
      filled.add('category');
    }
    if (_description.text.trim().isEmpty) {
      _description.text = draft.description;
      filled.add('description');
    }
    final minSen = draft.minSen;
    final maxSen = draft.maxSen;
    if (minSen != null && maxSen != null &&
        _budgetMin.text.trim().isEmpty && _budgetMax.text.trim().isEmpty) {
      _budgetMin.text = (minSen / 100).toStringAsFixed(2);
      _budgetMax.text = (maxSen / 100).toStringAsFixed(2);
      filled.add('budget');
    }
    setState(() {});
    _snack(filled.isEmpty
        ? 'Your form already has all of this, so nothing changed.'
        : 'Filled in ${filled.join(', ')}. Check each one before posting.');
  }

  /// Gemini description helper: expands whatever rough note is in the
  /// description field into an editable draft. Failures are soft - the form
  /// works identically without the assist.
  Future<void> _suggestDescription() async {
    final controller = context.read<PostJobController>();
    if (controller.category == null) {
      _snack('Pick a category first so the suggestion fits.');
      return;
    }
    final rough = _description.text.trim();
    if (rough.length < 3) {
      _snack('Type a rough note first, e.g. "leaking pipe under sink".');
      return;
    }
    final suggestion = await controller.suggestDescription(rough);
    if (!mounted) return;
    if (suggestion == null) {
      _snack('Couldn\'t get a suggestion right now.');
      return;
    }
    final previous = _description.text;
    _description.text = suggestion;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: const Text('Draft written. Edit it to match your situation.'),
      // persist: false - a SnackBar with an action defaults to persisting
      // forever, which would queue every later _snack behind it.
      persist: false,
      duration: const Duration(seconds: 6),
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () {
          if (mounted) _description.text = previous;
        },
      ),
    ));
  }

  /// Gemini fair-price guide: fetches an indicative RM range shown beside the
  /// budget fields. Nothing is auto-filled - the user taps "Use this".
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

  /// Task 1's category, title and description fields, shared by single-job
  /// mode (flat) and bundle mode (inside its own card) so both stay in sync.
  List<Widget> _task1Fields(PostJobController controller, ThemeData theme) {
    return [
      Text('Category', style: theme.textTheme.labelLarge),
      const SizedBox(height: 6),
      DropdownButtonFormField<String>(
        key: _task1CategoryKey,
        // Without this the button takes the width of its widest item
        // ("Moving & Delivery") and overflows a narrow phone.
        isExpanded: true,
        initialValue: controller.category,
        hint: const Text('Select a category...'),
        items: [
          for (final c in kServiceCategories)
            DropdownMenuItem(value: c, child: Text(c)),
        ],
        onChanged: controller.setCategory,
        validator: (v) => v == null ? 'Pick a category.' : null,
      ),
      if (_dependencyNote(
            myIndex: 0,
            lotId: _task1LotId,
            startsAfterIndex: _task1StartsAfterIndex,
            gapDays: _task1GapDays,
          )
          case final note?)
        _DependencyNote(text: note),
      const SizedBox(height: 16),
      AppTextField(
        fieldKey: _task1TitleKey,
        controller: _title,
        // Bundle mode labels task 1 like every other task card ("Task 1
        // title"); single-job mode keeps its own plain label.
        label: _isBundle ? 'Task 1 title' : 'Job title',
        hint: 'e.g. Fix leaking sink pipe',
        textInputAction: TextInputAction.next,
        validator: (v) => Validators.required(v, 'Title'),
      ),
      AppTextField(
        fieldKey: _task1DescriptionKey,
        controller: _description,
        label: _isBundle ? 'Task 1 description' : 'Description',
        hint: 'Describe what needs to be done, the problem, and any '
            'specific requirements...',
        maxLines: 8,
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
    ];
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<PostJobController>();
    final theme = Theme.of(context);
    final uid = context.read<AuthController>().user?.uid ?? '';

    return Stack(
      children: [
        _buildForm(context, controller, theme, uid),
        // Always-visible submit feedback: a screen-wide blocking overlay, so
        // it's obvious regardless of how far down the long form the user has
        // scrolled (unlike the Post Job button's own spinner, at the bottom).
        if (controller.isSubmitting) _SubmitOverlay(isBundle: _isBundle),
      ],
    );
  }

  Widget _buildForm(BuildContext context, PostJobController controller,
      ThemeData theme, String uid) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isBundle ? 'Post a bundle' : 'Post a job'),
      ),
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
                const SizedBox(height: 16),
                _DraftCard(
                  isBundle: _isBundle,
                  busy: controller.assistingDraft,
                  onTap: controller.isBusy ? null : _draftFromNote,
                ),
                const SizedBox(height: 24),
                if (controller.errorMessage != null)
                  ErrorBanner(controller.errorMessage!),

                // ---- The basics (required) ----
                // Bundle mode wraps task 1 in a card, its own budget inside
                // (like every other task's card); single mode keeps the
                // original flat layout, budget included further down.
                if (_isBundle)
                  AppCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text('Task 1', style: theme.textTheme.titleMedium),
                        const SizedBox(height: 8),
                        ..._task1Fields(controller, theme),
                        const SizedBox(height: 8),
                        _BudgetFields(
                          controller: controller,
                          budgetMin: _budgetMin,
                          budgetMax: _budgetMax,
                          hourly: _hourly,
                          onHourly: (v) => setState(() => _hourly = v),
                          onSuggestPrice:
                              controller.isBusy ? null : _suggestPrice,
                        ),
                      ],
                    ),
                  )
                else ...[
                  const _SectionHeader('The basics'),
                  const SizedBox(height: 12),
                  ..._task1Fields(controller, theme),
                ],

                // ---- The other tasks of a bundled posting ----
                for (var i = 0; i < _extraTasks.length; i++)
                  _TaskCard(
                    key: _extraTasks[i].key,
                    number: i + 2,
                    fields: _extraTasks[i],
                    onRemove:
                        _extraTasks[i].fromTemplate ? null : () => _removeTask(i),
                    lockedByTemplate: _extraTasks[i].fromTemplate,
                    onCategory: (v) =>
                        setState(() => _extraTasks[i].category = v),
                    onHourly: (v) =>
                        setState(() => _extraTasks[i].hourly = v),
                    note: _dependencyNote(
                      myIndex: i + 1,
                      lotId: _extraTasks[i].lotId,
                      startsAfterIndex: _extraTasks[i].startsAfterIndex,
                      gapDays: _extraTasks[i].gapDays,
                    ),
                  ),
                const SizedBox(height: 8),
                // Wrap, not Row: at larger text scales the two buttons no
                // longer fit on one line.
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    TextButton.icon(
                      onPressed: controller.isBusy ? null : _pickTemplate,
                      icon: const Icon(Icons.checklist_rtl),
                      label: const Text('Start from a template'),
                    ),
                    if (_templateApplied)
                      TextButton(
                        onPressed: controller.isBusy ? null : _clearTemplate,
                        child: const Text('Clear template'),
                      ),
                  ],
                ),
                if (_extraTasks.length + 1 < PlatformConfig.maxBundleTasks)
                  Row(
                    children: [
                      TextButton.icon(
                        onPressed: controller.isBusy ? null : _addTask,
                        icon: const Icon(Icons.add),
                        label: const Text('Add another task'),
                      ),
                      if (_isBundle)
                        Expanded(
                          child: Text(
                            '${_extraTasks.length + 1} tasks in this posting',
                            textAlign: TextAlign.end,
                            maxLines: 2,
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant),
                          ),
                        ),
                    ],
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'One posting can hold up to '
                      '${PlatformConfig.maxBundleTasks} tasks.',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                if (_isBundle)
                  Padding(
                    padding: const EdgeInsets.only(top: 4, left: 4),
                    child: Text(
                      'Providers bid on the tasks they can do, as one package. '
                      'The location, photos and deadline below are shared by '
                      'every task.',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),

                // ---- Photos & video (optional) ----
                const SizedBox(height: 24),
                _SectionHeader(
                    _isBundle ? 'Photos (optional)' : 'Photos & video (optional)'),
                const SizedBox(height: 8),
                // No optional toggle left to expand - tapping opens the
                // photo picker directly, same as the "Add photo" box below.
                _PhotoAssistHint(
                  hasPhoto: controller.photoUrls.isNotEmpty,
                  onAddPhoto: () => controller.addPhoto(uid),
                ),
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
                  busy: controller.uploadingPhoto,
                ),
                // `createBundle` writes no video or service address, so both
                // are hidden in bundle mode (anything already added says so).
                if (!_isBundle) ...[
                  const SizedBox(height: 16),
                  Text('Video (optional)', style: theme.textTheme.labelLarge),
                  const SizedBox(height: 8),
                  if (controller.videoUrl != null)
                    _VideoThumb(
                      url: controller.videoUrl!,
                      onRemove: controller.removeVideo,
                    )
                  else
                    UploadBox(
                      compact: true,
                      onTap: () => controller.addVideo(uid),
                      icon: Icons.videocam_outlined,
                      hint: 'Up to 60 seconds, under 45 MB',
                      busy: controller.uploadingVideo,
                    ),
                ] else ...[
                  const SizedBox(height: 12),
                  Text(
                    'These photos are shared by every task. A bundled posting '
                    'carries no video.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  if (controller.videoUrl != null)
                    _DroppedField(
                      message: 'The video you added will not be posted.',
                      actionLabel: 'Remove it',
                      onAction: controller.removeVideo,
                    ),
                ],

                // ---- Where (location required, label/address optional) ----
                const SizedBox(height: 24),
                const _SectionHeader('Where'),
                const SizedBox(height: 12),
                LocationField(
                  label: controller.location == null ? null : _address.text,
                  placeholder: 'Pick location on map',
                  onTap: _pickLocation,
                ),
                if (_locationDefaulted && controller.location != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6, left: 4),
                    child: Text(
                      'Defaulted to your saved area. Tap the map to change.',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                if (controller.location != null) ...[
                  const SizedBox(height: 12),
                  AppTextField(
                    controller: _address,
                    label: 'Location label (optional)',
                    hint: 'e.g. Bangsar, Kuala Lumpur',
                  ),
                ],
                const SizedBox(height: 8),
                if (!_isBundle)
                  _AddressField(
                    address: controller.pendingAddress,
                    onTap: _pickAddress,
                  )
                else ...[
                  Text(
                    'Add the exact address from each task once the posting '
                    'is up.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  if (controller.pendingAddress != null)
                    _DroppedField(
                      message: 'The service address you added will not be '
                          'posted.',
                      actionLabel: 'Clear it',
                      onAction: () => controller.setAddress(null),
                    ),
                ],

                // ---- When & budget ----
                // Bundle mode's own budget lives in task 1's card now; only
                // the deadline is shared across every task here, so the
                // heading names just that rather than "budget" too.
                const SizedBox(height: 24),
                _SectionHeader(
                  _isBundle ? 'Deadline (shared)' : 'When & budget (optional)',
                ),
                const SizedBox(height: 12),
                _DeadlineField(
                  deadline: _deadline,
                  onTap: _pickDeadline,
                  onClear: _clearDeadline,
                ),
                if (!_isBundle) ...[
                  const SizedBox(height: 16),
                  _BudgetFields(
                    controller: controller,
                    budgetMin: _budgetMin,
                    budgetMax: _budgetMax,
                    hourly: _hourly,
                    onHourly: (v) => setState(() => _hourly = v),
                    onSuggestPrice: controller.isBusy ? null : _suggestPrice,
                  ),
                ],

                // ---- Naming the posting (bundle mode only) ----
                // Last, not first: nothing required may land off-screen when
                // a task is added, and naming is easier once tasks exist.
                if (_isBundle) ...[
                  const SizedBox(height: 24),
                  const _SectionHeader('Name this posting'),
                  const SizedBox(height: 12),
                  AppTextField(
                    fieldKey: _postingTitleKey,
                    controller: _postingTitle,
                    label: 'Posting title',
                    hint: 'e.g. Bathroom refresh',
                    textInputAction: TextInputAction.next,
                    validator: (v) => Validators.required(v, 'Posting title'),
                  ),
                  AppTextField(
                    controller: _postingSummary,
                    label: 'Posting summary (optional)',
                    hint: 'Leave blank and we\'ll list your tasks.',
                    maxLines: 3,
                  ),
                ],

                const SizedBox(height: 24),
                PrimaryButton(
                  label: _isBundle ? 'Post bundle' : 'Post job',
                  // Its own spinner reflects submitting only - the screen-wide
                  // overlay already covers that - but stays disabled during a
                  // photo/video upload too, so the job can't be created before
                  // an in-flight upload finishes.
                  busy: controller.isSubmitting,
                  onPressed: controller.isBusy ? null : _submit,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A field a bundled posting cannot carry, with the tap that clears it.
class _DroppedField extends StatelessWidget {
  const _DroppedField({
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });

  final String message;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(Icons.info_outline, size: 16, color: context.fairbid.warningText),
        const SizedBox(width: 6),
        Expanded(
          child: Text(message,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: context.fairbid.warningText)),
        ),
        TextButton(onPressed: onAction, child: Text(actionLabel)),
      ],
    );
  }
}

/// The assist entry point: one note in, a whole draft post out.
class _DraftCard extends StatelessWidget {
  const _DraftCard({
    required this.isBundle,
    required this.busy,
    required this.onTap,
  });

  /// True in bundle mode, where the assist only ever fills task 1.
  final bool isBundle;
  final bool busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppCard(
      onTap: busy ? null : onTap,
      child: Row(
        children: [
          Icon(Icons.auto_awesome, color: context.fairbid.verified),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isBundle
                      ? "Describe task 1 once and we'll fill it in"
                      : "Describe it once, we'll fill this in",
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 2),
                Text(
                  'Say what needs doing in your own words. Everything stays '
                  'yours to edit.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          if (busy)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
    );
  }
}

/// Collects the rough note, and hands it back to the form.
class _DraftSheet extends StatefulWidget {
  const _DraftSheet();

  @override
  State<_DraftSheet> createState() => _DraftSheetState();
}

class _DraftSheetState extends State<_DraftSheet> {
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('What needs doing?',
                style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 12),
            AppTextField(
              controller: _note,
              label: 'In your own words',
              hint: 'e.g. kitchen tap drips all night, upstairs unit, I have '
                  'the washer already',
              maxLines: 4,
            ),
            const SizedBox(height: 8),
            PrimaryButton(
              label: 'Draft my post',
              onPressed: () => Navigator.of(context).pop(_note.text.trim()),
            ),
          ],
        ),
      ),
    );
  }
}

/// Lists [kBundleTemplates] for the requestor to start from; picking one
/// pops it back to `_pickTemplate`.
class _TemplateSheet extends StatelessWidget {
  const _TemplateSheet();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // isScrollControlled + a scrollable body (not a fixed Padding/Column) so
    // the list of templates never overflows at larger text scales.
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Start from a template', style: theme.textTheme.headlineMedium),
          const SizedBox(height: 8),
          for (final template in kBundleTemplates)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(template.name),
              subtitle: Text(
                template.tasks.map((t) => t.title).join(' · '),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).pop(template),
            ),
        ],
      ),
    );
  }
}

/// A read-only note under a task card, for the template-derived dependency/
/// lot links `_PostJobViewState._dependencyNote` computes.
class _DependencyNote extends StatelessWidget {
  const _DependencyNote({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.link, size: 14, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Text(text,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
        ],
      ),
    );
  }
}

/// The controllers behind one added task, kept in a class so adding/removing
/// a task is a single list operation and every field is disposed with it.
class _TaskFields {
  /// Identifies this card so adding one can scroll it into view.
  final key = GlobalKey();

  final title = TextEditingController();
  final description = TextEditingController();
  final budgetMin = TextEditingController();
  final budgetMax = TextEditingController();
  String? category;
  bool hourly = false;

  /// Field keys, so a failed submit can find and scroll to the first one
  /// with an error.
  final categoryKey = GlobalKey<FormFieldState<String>>();
  final titleKey = GlobalKey<FormFieldState<String>>();
  final descriptionKey = GlobalKey<FormFieldState<String>>();

  /// Template-derived, read-only lot/dependency links - see
  /// `_PostJobViewState._applyTemplate`/`_clearTemplate`.
  String? lotId;
  int? startsAfterIndex;
  int? gapDays;

  /// True while this task still carries its template's links - hides the
  /// remove button, since deleting it would break a link or split a lot.
  bool fromTemplate = false;

  void dispose() {
    title.dispose();
    description.dispose();
    budgetMin.dispose();
    budgetMax.dispose();
  }
}

/// One added task of a bundled posting ("Task 2" on, since Task 1 uses the
/// form's own fields). Lots/dependencies are read-only in v1 - only ever
/// from a template ([note]) - so [onRemove] is null on a linked task.
class _TaskCard extends StatelessWidget {
  const _TaskCard({
    super.key,
    required this.number,
    required this.fields,
    required this.onRemove,
    required this.onCategory,
    required this.onHourly,
    this.note,
    this.lockedByTemplate = false,
  });

  final int number;
  final _TaskFields fields;
  final VoidCallback? onRemove;
  final ValueChanged<String?> onCategory;
  final ValueChanged<bool> onHourly;
  final String? note;

  /// True while this task still carries a template's lot/dependency link -
  /// its remove button is shown disabled, rather than hidden, so it's clear
  /// why it can't be tapped.
  final bool lockedByTemplate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Task $number',
                      style: theme.textTheme.titleMedium),
                ),
                if (lockedByTemplate)
                  IconButton(
                    tooltip: 'Linked by the template. Tap Clear template to '
                        'remove it.',
                    icon: const Icon(Icons.close),
                    onPressed: null,
                  )
                else if (onRemove != null)
                  IconButton(
                    tooltip: 'Remove task $number',
                    icon: const Icon(Icons.close),
                    onPressed: onRemove,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text('Category', style: theme.textTheme.labelLarge),
            const SizedBox(height: 6),
            DropdownButtonFormField<String>(
              key: fields.categoryKey,
              isExpanded: true,
              initialValue: fields.category,
              hint: const Text('Select a category...'),
              items: [
                for (final c in kServiceCategories)
                  DropdownMenuItem(value: c, child: Text(c)),
              ],
              onChanged: onCategory,
              validator: (v) => v == null ? 'Pick a category.' : null,
            ),
            if (note != null) _DependencyNote(text: note!),
            const SizedBox(height: 16),
            AppTextField(
              fieldKey: fields.titleKey,
              controller: fields.title,
              label: 'Task $number title',
              hint: 'e.g. Re-tile the shower wall',
              textInputAction: TextInputAction.next,
              validator: (v) => Validators.required(v, 'Title'),
            ),
            AppTextField(
              fieldKey: fields.descriptionKey,
              controller: fields.description,
              label: 'Task $number description',
              hint: 'What needs doing, and anything a provider should know...',
              maxLines: 4,
              validator: (v) => Validators.required(v, 'Description'),
            ),
            Row(
              children: [
                Expanded(
                  child: AppTextField(
                    controller: fields.budgetMin,
                    label: 'Min (RM)',
                    hint: '0.00',
                    prefixText: 'RM ',
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: AppTextField(
                    controller: fields.budgetMax,
                    label: 'Max (RM)',
                    hint: '0.00',
                    prefixText: 'RM ',
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                  ),
                ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Hourly rate'),
              value: fields.hourly,
              onChanged: onHourly,
            ),
          ],
        ),
      ),
    );
  }
}

/// Full-screen blocking overlay shown only while [PostJobController.submit]
/// is running: a modal barrier (absorbing all input) plus a centred spinner
/// and label, so submit feedback is immediate no matter where the user has
/// scrolled on the long form. Distinct from the per-upload spinner on each
/// UploadBox, which shows instead while a photo or video is uploading.
class _SubmitOverlay extends StatelessWidget {
  const _SubmitOverlay({required this.isBundle});

  final bool isBundle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Positioned.fill(
      child: Stack(
        children: [
          const ModalBarrier(dismissible: false, color: Colors.black54),
          Center(
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(
                    isBundle ? 'Posting your bundle…' : 'Posting your job…',
                    style: theme.textTheme.bodyLarge,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Section header shown above each of the form's four groups ("The basics",
/// "Photos & video (optional)", "Where", "When & budget (optional)").
class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(label, style: Theme.of(context).textTheme.titleMedium);
  }
}

/// Optional bidding-deadline picker, modelled on [LocationField]'s tappable
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

/// Optional precise service-address affordance, modelled on
/// [_DeadlineField]'s tappable row: shows a prompt or the entered address's
/// one-line summary. Fully optional - posting works without one.
class _AddressField extends StatelessWidget {
  const _AddressField({required this.address, required this.onTap});

  final ServiceAddress? address;
  final VoidCallback onTap;

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
            Icon(Icons.home_outlined, color: context.fairbid.verified),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                address == null
                    ? 'Add address (only your hired provider sees it)'
                    : address!.summary,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyLarge,
              ),
            ),
            Icon(address == null ? Icons.chevron_right : Icons.edit_outlined),
          ],
        ),
      ),
    );
  }
}

/// Budget fields for the "When & budget" group: the min/max RM inputs, the
/// hourly-rate switch and the "Suggest a fair range" assist with its
/// "Use this" shortcut. Split out of the old always-collapsed
/// `_OptionalDetails` now that photos live in their own group and budget is
/// always visible.
class _BudgetFields extends StatelessWidget {
  const _BudgetFields({
    required this.controller,
    required this.budgetMin,
    required this.budgetMax,
    required this.hourly,
    required this.onHourly,
    required this.onSuggestPrice,
  });

  final PostJobController controller;
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
        // Wrap, not Row: nested inside task 1's card (bundle mode) the
        // available width is narrower than the old "When & budget" section,
        // and "Suggest a fair range" no longer reliably fits beside the
        // label.
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('Budget', style: theme.textTheme.labelLarge),
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
                prefixText: 'RM ',
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
                prefixText: 'RM ',
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
      ],
    );
  }
}

/// Nudges the requestor to attach a photo so the Gemini assists (description
/// and price) can analyse it - the assists pass the first photo to the model,
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
            // Decode at display size, not the full upload size.
            cacheWidth: (80 * MediaQuery.devicePixelRatioOf(context)).round(),
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

/// The attached video's preview (first frame + play overlay, via
/// [JobVideoPreview]) with a remove (×) button, mirroring [_PhotoThumb].
class _VideoThumb extends StatelessWidget {
  const _VideoThumb({required this.url, required this.onRemove});
  final String url;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        JobVideoPreview(url: url, height: 140),
        Positioned(
          right: 0,
          top: 0,
          child: Semantics(
            button: true,
            label: 'Remove video',
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
