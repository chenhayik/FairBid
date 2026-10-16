import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../../../core/config/platform_config.dart';
import '../../../../core/util/service_categories.dart';
import '../../../../core/location/address_hint.dart';
import '../../../../core/location/geo.dart';
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
import '../detail/service_address_sheet.dart';
import '../widgets/deadline_picker.dart';
import 'post_job_controller.dart';

/// What:   Requestor form for posting a job, or a bundle once a second task is added.
/// Input:  User defaults from AuthController; a PostJobController scoped to this screen.
/// Output: Creates the job/bundle through the controller, then pops home.
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

/// What:   The form itself, under the PostJobController provider.
/// Input:  PostJobController via context.watch (post_job_controller.dart); user defaults from AuthController.
/// Output: Job form that becomes a bundle form once a task is added, with a blocking overlay while submitting.
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
  // Bidding closes in 14 days unless changed, so old jobs leave the feed.
  DateTime? _deadline = endOfDay(DateTime.now().add(const Duration(days: 14)));

  // Task 1's field keys, so a failed submit can scroll to the first error.
  final _task1CategoryKey = GlobalKey<FormFieldState<String>>();
  final _task1TitleKey = GlobalKey<FormFieldState<String>>();
  final _task1DescriptionKey = GlobalKey<FormFieldState<String>>();
  final _postingTitleKey = GlobalKey<FormFieldState<String>>();

  /// Tasks beyond the first; empty for an ordinary single job.
  final List<_TaskFields> _extraTasks = [];

  /// The bundle's own title and summary (bundle mode only).
  final _postingTitle = TextEditingController();
  final _postingSummary = TextEditingController();

  bool get _isBundle => _extraTasks.isNotEmpty;

  /// Bundle photo url -> the tasks it shows (task 1's tag or a [_TaskFields]).
  /// A photo with no tasks shows on every task.
  final Map<String, Set<Object>> _photoTasks = {};
  static const _task1Tag = 'task1';

  List<Object> get _taskTags => [_task1Tag, ..._extraTasks];

  /// True while the location is still the saved default.
  bool _locationDefaulted = false;

  /// A fresh pick carries its own hint; a seeded default has none, so
  /// `_addressHint` resolves and caches one here.
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
      // Profiles saved before rounding may hold exact coordinates.
      lat: coarseCoord(user.defaultLat!),
      lng: coarseCoord(user.defaultLng!),
      address: region.label,
      region: region,
    ));
    _address.text = region.label;
    _locationDefaulted = true;
    // Warm the geocode so the address sheet opens pre-filled.
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

  /// What:   Opens the map picker for the job location.
  /// Output: Sets the controller location and the address field; the location is no longer the saved default.
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

  /// What:   Street-level suggestion for [location].
  /// Output: Its own hint, else a cached reverse geocode of the pin, or null.
  Future<AddressHint?> _addressHint(PickedLocation? location) {
    if (location == null) return Future.value();
    if (location.addressHint != null) return Future.value(location.addressHint);
    if (!identical(_hintFor, location)) {
      _hintFor = location;
      _seededHint = reverseGeocode(LatLng(location.lat, location.lng));
    }
    return _seededHint!;
  }

  /// What:   Opens the optional service-address sheet.
  /// Output: Pre-filled from the pin and town (a typed address wins); the result goes to PostJobController.setAddress().
  Future<void> _pickAddress() async {
    final controller = context.read<PostJobController>();
    final user = context.read<AuthController>().user;
    // An address already entered beats the geocoder's guess.
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

  /// What:   Picks the bidding deadline.
  /// Output: Sets [_deadline] from pickBiddingDeadline().
  Future<void> _pickDeadline() async {
    final picked = await pickBiddingDeadline(context, initial: _deadline);
    if (picked != null) setState(() => _deadline = picked);
  }

  /// What:   Adds a task, turning the post into a bundle.
  /// Output: Appends a _TaskFields and scrolls the new card into view.
  void _addTask() {
    final added = _TaskFields();
    setState(() => _extraTasks.add(added));
    // The button is halfway down a long form; scroll so the tap shows a result.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = added.key.currentContext;
      if (target == null) return;
      Scrollable.ensureVisible(target,
          duration: const Duration(milliseconds: 300), alignment: 0.1);
    });
  }

  /// What:   Removes an added task.
  /// Output: Disposes it, drops its photo tags and re-syncs the assist photos.
  void _removeTask(int index) {
    setState(() {
      final removed = _extraTasks.removeAt(index);
      for (final tags in _photoTasks.values) {
        tags.remove(removed);
      }
      removed.dispose();
    });
    _syncAssistPhotos();
  }

  /// What:   Tag text for a bundle photo.
  /// Output: "All tasks", or "Task 1, 3" for the tasks it is tagged with.
  String _photoLabel(String url) {
    final tags = _photoTasks[url] ?? const {};
    final numbers = [
      for (final (i, tag) in _taskTags.indexed)
        if (tags.contains(tag)) i + 1,
    ];
    return numbers.isEmpty ? 'All tasks' : 'Task ${numbers.join(', ')}';
  }

  /// What:   Photos that belong to one task.
  /// Input:  Task [tag] and the photo [urls].
  /// Output: Positions in [urls] of the photos tagged with it.
  List<int> _photoIndexesFor(Object tag, List<String> urls) => [
    for (final (i, url) in urls.indexed)
      if (_photoTasks[url]?.contains(tag) ?? false) i,
  ];

  /// What:   Tells the AI assists which photos don't show task 1.
  /// Output: Sets PostJobController.skipForAssist to photos tagged only to other tasks.
  void _syncAssistPhotos() {
    context.read<PostJobController>().skipForAssist = {
      for (final MapEntry(key: url, value: tags) in _photoTasks.entries)
        if (tags.isNotEmpty && !tags.contains(_task1Tag)) url,
    };
  }

  /// What:   Removes a photo and its task tags.
  void _removePhoto(String url) {
    context.read<PostJobController>().removePhoto(url);
    _photoTasks.remove(url);
    _syncAssistPhotos();
  }

  /// What:   Lets the user tag a bundle photo with the tasks it shows.
  /// Output: Sets [_photoTasks] for [url] from _PhotoTasksSheet and re-syncs the assist photos.
  Future<void> _pickPhotoTasks(String url) async {
    // Otherwise closing the sheet re-focuses the last text field.
    FocusScope.of(context).unfocus();
    final tags = _taskTags;
    final current = _photoTasks[url] ?? const {};
    final picked = await showModalBottomSheet<Set<int>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _PhotoTasksSheet(
        taskTitles: [for (var i = 0; i < tags.length; i++) _taskTitle(i)],
        selected: {
          for (final (i, tag) in tags.indexed)
            if (current.contains(tag)) i,
        },
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _photoTasks[url] = {for (final i in picked) tags[i]});
    _syncAssistPhotos();
  }

  /// What:   Label for a task.
  /// Output: "Task 2: Re-tile the wall", or just "Task 2" before it has a title.
  String _taskTitle(int index) {
    final title = (index == 0 ? _title : _extraTasks[index - 1].title)
        .text
        .trim();
    return title.isEmpty ? 'Task ${index + 1}' : 'Task ${index + 1}: $title';
  }

  /// What:   Bundle summary used when the user leaves it blank.
  /// Output: "N tasks: title, title."; needed because `createBundle` requires a description.
  String _composedSummary() {
    final titles = [
      _title.text.trim(),
      for (final task in _extraTasks) task.title.text.trim(),
    ].where((t) => t.isNotEmpty).toList();
    return '${titles.length} tasks: ${titles.join(', ')}.';
  }

  /// What:   Scrolls to the first invalid field.
  /// Output: Brings it into view (its error may be off-screen) and shows a snackbar.
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

  /// What:   "Post without photos?" dialog.
  /// Output: True to post anyway; "Add a photo" opens the picker and returns false.
  Future<bool> _confirmNoMedia() async {
    final postAnyway = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Post without photos?'),
        content: const Text(
          'Photos help providers understand the job and quote '
          'accurately. They are also useful evidence if anything goes wrong '
          'later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Post anyway'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Add a photo'),
          ),
        ],
      ),
    );
    if (postAnyway == false && mounted) {
      final uid = context.read<AuthController>().user?.uid ?? '';
      unawaited(context.read<PostJobController>().addPhoto(uid));
    }
    return postAnyway == true;
  }

  /// What:   Post button handler.
  /// Input:  Form fields, the picked location, budget and deadline.
  /// Output: Validates (scrolls to the first error), requires a location, confirms no photos, then PostJobController.submit()
  ///         for one task or [_submitBundle] for several; success pops home with a snackbar.
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
    final hasMedia = controller.photoUrls.isNotEmpty;
    if (!hasMedia && !await _confirmNoMedia()) return;
    if (!mounted) return;
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
      ),
      photoUrls: List.of(controller.photoUrls),
      deadline: _deadline,
    );
    final id = await controller.submit(job);
    if (id != null && mounted) {
      unawaited(HapticFeedback.mediumImpact());
      _snack(controller.addressWarning ?? 'Job posted!');
      context.pop(); // back to home; the job shows in Active Jobs
    }
  }

  /// What:   Posts the form as a bundle.
  /// Input:  [controller] and the shared [location]; task 1 plus every extra task as BundleTaskDrafts with their photo indexes.
  /// Output: PostJobController.submitBundle(); success pops home with a snackbar.
  Future<void> _submitBundle(
      PostJobController controller, JobLocation location) async {
    final summary = _postingSummary.text.trim();
    final photos = controller.photoUrls;
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
          ),
          photoIndexes: _photoIndexesFor(_task1Tag, photos),
        ),
        for (final task in _extraTasks)
          BundleTaskDraft(
            title: task.title.text.trim(),
            description: task.description.text.trim(),
            category: task.category!,
            budget: JobBudget(
              minSen: parseRmToSen(task.budgetMin.text),
              maxSen: parseRmToSen(task.budgetMax.text),
            ),
            photoIndexes: _photoIndexesFor(task, photos),
          ),
      ],
    );
    if (id != null && mounted) {
      unawaited(HapticFeedback.mediumImpact());
      _snack('Bundle posted with ${_extraTasks.length + 1} tasks!');
      context.pop(); // back to home; each task shows in the feed
    }
  }

  /// What:   Shows a snackbar.
  void _snack(String message) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message)));

  /// What:   AI draft flow.
  /// Output: Asks for a rough note in _DraftSheet, then PostJobController.suggestDraft() and [_applyDraft]; a snackbar if unavailable.
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

  /// What:   Fills the form from an AI draft.
  /// Input:  [draft] (title, category, description, budget range).
  /// Output: Fills only empty fields, never overwriting what the user typed; a snackbar lists what changed.
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

  /// What:   Fair-price assist.
  /// Output: Needs a category and a description; PostJobController.suggestPrice() sets the range hint the user can apply with "Use this".
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

  /// What:   Task 1's category, title and description fields.
  /// Output: Widgets placed flat in single mode or inside a card in bundle mode.
  List<Widget> _task1Fields(PostJobController controller, ThemeData theme) {
    return [
      _categoryField(
        theme,
        key: _task1CategoryKey,
        value: controller.category,
        onChanged: controller.setCategory,
      ),
      const SizedBox(height: 16),
      AppTextField(
        fieldKey: _task1TitleKey,
        controller: _title,
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
        // Blocking overlay: the button's own spinner may be scrolled off-screen.
        if (controller.isSubmitting) _SubmitOverlay(isBundle: _isBundle),
      ],
    );
  }

  /// What:   The scrollable form scaffold.
  /// Output: Draft card, basics (task 1), extra task cards, photos, location and address, deadline and budget, bundle name, Post button.
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
                // Bundle mode wraps task 1 and its budget in a card.
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
                    onRemove: () => _removeTask(i),
                    onCategory: (v) =>
                        setState(() => _extraTasks[i].category = v),
                  ),
                const SizedBox(height: 8),
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
                      'The location and deadline below are shared by every '
                      'task.',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),

                // ---- Photos (optional) ----
                const SizedBox(height: 24),
                const _SectionHeader('Photos (optional)'),
                const SizedBox(height: 8),
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
                          onRemove: () => _removePhoto(url),
                          tagLabel: _isBundle ? _photoLabel(url) : null,
                          onTag: () => _pickPhotoTasks(url),
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
                if (_isBundle) ...[
                  const SizedBox(height: 12),
                  Text(
                    "Tap a photo's label to choose which tasks it shows. "
                    'Untagged photos show on every task.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
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
                  LocationField(
                    icon: Icons.home_outlined,
                    label: controller.pendingAddress?.summary,
                    placeholder: 'Add address (only your hired provider sees it)',
                    onTap: _pickAddress,
                    trailing: Icon(
                      controller.pendingAddress == null
                          ? Icons.chevron_right
                          : Icons.edit_outlined,
                    ),
                  )
                else ...[
                  Text(
                    'Add the exact address from each task once the posting '
                    'is up.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  if (controller.pendingAddress != null)
                    Row(
                      children: [
                        Icon(Icons.info_outline,
                            size: 16, color: context.fairbid.warningText),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'The service address you added will not be '
                            'posted.',
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: context.fairbid.warningText),
                          ),
                        ),
                        TextButton(
                          onPressed: () => controller.setAddress(null),
                          child: const Text('Clear it'),
                        ),
                      ],
                    ),
                ],

                // ---- When & budget ----
                // In bundle mode only the deadline is shared; budgets are per task.
                const SizedBox(height: 24),
                _SectionHeader(
                  _isBundle ? 'Bidding deadline (shared)' : 'Bidding deadline & price',
                ),
                const SizedBox(height: 12),
                LocationField(
                  icon: Icons.timer_outlined,
                  label: _deadline == null
                      ? null
                      : 'Bidding closes ${DateFormat.yMMMd().format(_deadline!)}',
                  placeholder: 'Set a bidding deadline',
                  onTap: _pickDeadline,
                  trailing: _deadline == null
                      ? null
                      : IconButton(
                          tooltip: 'Remove deadline',
                          icon: const Icon(Icons.close),
                          onPressed: () => setState(() => _deadline = null),
                        ),
                ),
                if (!_isBundle) ...[
                  const SizedBox(height: 16),
                  _BudgetFields(
                    controller: controller,
                    budgetMin: _budgetMin,
                    budgetMax: _budgetMax,
                    onSuggestPrice: controller.isBusy ? null : _suggestPrice,
                  ),
                ],

                // ---- Naming the posting (bundle mode only) ----
                // Last, so no required field lands off-screen when a task is added.
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
                  // Disabled during an upload too, so the job can't post before it finishes.
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

/// What:   Entry card for the AI draft: one note in, a draft post out.
/// Input:  [isBundle] (the assist only fills task 1), [busy], [onTap].
/// Output: Tappable card with a spinner while drafting.
class _DraftCard extends StatelessWidget {
  const _DraftCard({
    required this.isBundle,
    required this.busy,
    required this.onTap,
  });

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

/// What:   Bottom sheet that collects the rough note for the AI draft.
/// Output: Pops with the trimmed note text.
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

/// What:   The controllers and keys behind one added task.
/// Output: Title, description, budget controllers, category and field keys; one object to add, remove and dispose.
class _TaskFields {
  final key = GlobalKey(); // So a new card can be scrolled into view.

  final title = TextEditingController();
  final description = TextEditingController();
  final budgetMin = TextEditingController();
  final budgetMax = TextEditingController();
  String? category;

  final categoryKey = GlobalKey<FormFieldState<String>>();
  final titleKey = GlobalKey<FormFieldState<String>>();
  final descriptionKey = GlobalKey<FormFieldState<String>>();

  void dispose() {
    title.dispose();
    description.dispose();
    budgetMin.dispose();
    budgetMax.dispose();
  }
}

/// What:   One added task of a bundle ("Task 2" on; Task 1 uses the form's own fields).
/// Input:  [number], [fields], [onRemove], [onCategory].
/// Output: Card with category, title, description and budget range fields.
class _TaskCard extends StatelessWidget {
  const _TaskCard({
    super.key,
    required this.number,
    required this.fields,
    required this.onRemove,
    required this.onCategory,
  });

  final int number;
  final _TaskFields fields;
  final VoidCallback onRemove;
  final ValueChanged<String?> onCategory;

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
                IconButton(
                    tooltip: 'Remove task $number',
                    icon: const Icon(Icons.close),
                    onPressed: onRemove,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            _categoryField(
              theme,
              key: fields.categoryKey,
              value: fields.category,
              onChanged: onCategory,
            ),
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
            Text('Likely price range (optional)',
                style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            _rangeFields(fields.budgetMin, fields.budgetMax),
          ],
        ),
      ),
    );
  }
}

/// What:   Category dropdown.
/// Input:  Form field [key], current [value] and [onChanged]; options from kServiceCategories.
/// Output: Dropdown that fails validation until a category is picked.
Widget _categoryField(
  ThemeData theme, {
  required Key key,
  required String? value,
  required ValueChanged<String?> onChanged,
}) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('Category', style: theme.textTheme.labelLarge),
      const SizedBox(height: 6),
      DropdownButtonFormField<String>(
        key: key,
        // Without this the button takes its widest item's width and overflows.
        isExpanded: true,
        initialValue: value,
        hint: const Text('Select a category...'),
        items: [
          for (final c in kServiceCategories)
            DropdownMenuItem(value: c, child: Text(c)),
        ],
        onChanged: onChanged,
        validator: (v) => v == null ? 'Pick a category.' : null,
      ),
    ],
  );
}

/// What:   From/To RM amount fields.
/// Input:  [min] and [max] controllers.
/// Output: Two decimal-number fields side by side.
Widget _rangeFields(TextEditingController min, TextEditingController max) {
  return Row(
    children: [
      Expanded(
        child: AppTextField(
          controller: min,
          label: 'From (RM)',
          hint: '0.00',
          prefixText: 'RM ',
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: AppTextField(
          controller: max,
          label: 'To (RM)',
          hint: '0.00',
          prefixText: 'RM ',
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
        ),
      ),
    ],
  );
}

/// What:   Blocking overlay while a submit runs.
/// Input:  [isBundle] picks the wording.
/// Output: Dimmed barrier with a progress card, since the button's own spinner may be scrolled off-screen.
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

/// What:   Section title text.
/// Input:  [label].
class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(label, style: Theme.of(context).textTheme.titleMedium);
  }
}

/// What:   Price range inputs with the fair-range assist.
/// Input:  [controller] priceHint and assisting state; [budgetMin], [budgetMax]; [onSuggestPrice].
/// Output: "Suggest a fair range" button and, once a hint exists, a "Use this" shortcut that fills the fields.
class _BudgetFields extends StatelessWidget {
  const _BudgetFields({
    required this.controller,
    required this.budgetMin,
    required this.budgetMax,
    required this.onSuggestPrice,
  });

  final PostJobController controller;
  final TextEditingController budgetMin;
  final TextEditingController budgetMax;
  final VoidCallback? onSuggestPrice;

  static String _senToField(int sen) => (sen / 100).toStringAsFixed(2);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final priceHint = controller.priceHint;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Wrap, not Row: in bundle mode the narrow card can't fit the button beside the label.
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('Likely price range', style: theme.textTheme.labelLarge),
            TextButton.icon(
              onPressed: controller.assistingPrice ? null : onSuggestPrice,
              icon: controller.assistingPrice
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_awesome, size: 18),
              label: const Text('Suggest a fair range'),
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
        _rangeFields(budgetMin, budgetMax),
      ],
    );
  }
}

/// What:   Nudge to add a photo for the AI assists.
/// Input:  [hasPhoto]; [onAddPhoto].
/// Output: "Add a photo" button, or a confirmation once a photo exists.
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

/// What:   Sheet to tick which bundle tasks a photo shows.
/// Input:  [taskTitles] and the [selected] task indexes.
/// Output: Pops with the chosen indexes; none means the photo shows on all tasks.
class _PhotoTasksSheet extends StatefulWidget {
  const _PhotoTasksSheet({required this.taskTitles, required this.selected});
  final List<String> taskTitles;
  final Set<int> selected;

  @override
  State<_PhotoTasksSheet> createState() => _PhotoTasksSheetState();
}

class _PhotoTasksSheetState extends State<_PhotoTasksSheet> {
  late final Set<int> _picked = {...widget.selected};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Which tasks does this photo show?',
              style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            'Leave all unticked to show it on every task.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          for (final (i, title) in widget.taskTitles.indexed)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _picked.contains(i),
              title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
              onChanged: (on) => setState(
                  () => on == true ? _picked.add(i) : _picked.remove(i)),
            ),
          const SizedBox(height: 8),
          PrimaryButton(
            label: 'Done',
            onPressed: () => Navigator.of(context).pop(_picked),
          ),
        ],
      ),
    );
  }
}

/// What:   Photo thumbnail with a remove button.
/// Input:  [url], [onRemove]; optional [tagLabel] and [onTag] in bundle mode.
/// Output: 80px image with a remove icon, plus a task-tag button under it when [tagLabel] is set.
class _PhotoThumb extends StatelessWidget {
  const _PhotoThumb({
    required this.url,
    required this.onRemove,
    this.tagLabel,
    this.onTag,
  });
  final String url;
  final VoidCallback onRemove;

  final String? tagLabel;
  final VoidCallback? onTag;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final thumb = Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.network(
            url,
            width: 80,
            height: 80,
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
    if (tagLabel == null) return thumb;
    return SizedBox(
      width: 80,
      child: Column(
        children: [
          thumb,
          TextButton.icon(
            onPressed: onTag,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              minimumSize: const Size(80, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: theme.textTheme.labelSmall,
            ),
            icon: const Icon(Icons.sell_outlined, size: 14),
            label: Text(
              tagLabel!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
