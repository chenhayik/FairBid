import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

import '../../../../core/location/region.dart';
import '../../../onboarding/data/document_storage_repository.dart';
import '../../data/assist_repository.dart';
import '../../data/bundle_repository.dart';
import '../../data/job_repository.dart';
import '../../domain/bundle.dart';
import '../../domain/job.dart';
import '../../domain/service_address.dart';

/// What:   State and actions for the Post-a-Job form (single job or bundle).
/// Input:  JobRepository, DocumentStorageRepository, AssistRepository, BundleRepository.
/// Output: submit()/submitBundle() return the new id or null; errors in [errorMessage].
class PostJobController extends ChangeNotifier {
  PostJobController(
    this._jobs,
    this._storage,
    this._assist,
    this._bundles, {
    ImagePicker? imagePicker,
  }) : _picker = imagePicker ?? ImagePicker();

  final JobRepository _jobs;
  final DocumentStorageRepository _storage;
  final AssistRepository _assist;
  final BundleRepository _bundles;
  final ImagePicker _picker;

  String? category;
  PickedLocation? location;

  /// Optional service address, attached after the job is created.
  ServiceAddress? pendingAddress;
  final List<String> photoUrls = [];

  // Separate flags so the submit overlay and the photo spinner never mix.
  bool _isSubmitting = false;
  bool _uploadingPhoto = false;
  String? _errorMessage;

  // Assist state, keyed by the screen's task tags. A price lookup never blocks
  // posting; a draft does (see [isBusy]).
  // Failures leave [_errorMessage] alone: a missing suggestion is not a form error.
  Object? draftingTask;
  final Map<Object, ({int minSen, int maxSen})> priceHints = {};
  final Set<Object> _pricingTasks = {};

  bool _disposed = false;

  /// What:   Whether a draft is in flight.
  /// Output: True while [draftingTask] is set.
  bool get assistingDraft => draftingTask != null;

  /// What:   Whether a task's price suggestion is loading.
  /// Input:  [task], the screen's tag for that task.
  /// Output: True while its suggestPrice() runs.
  bool isPricing(Object task) => _pricingTasks.contains(task);

  /// What:   Whether the job is being created.
  /// Output: True while submitting; drives the blocking overlay.
  bool get isSubmitting => _isSubmitting;

  /// What:   Whether a photo is uploading.
  /// Output: True during an upload; drives the photo box spinner.
  bool get uploadingPhoto => _uploadingPhoto;

  /// What:   Whether a submit, upload or draft is in flight.
  /// Output: True while any runs; gates actions that must not overlap.
  bool get isBusy => _isSubmitting || _uploadingPhoto || assistingDraft;

  String? get errorMessage => _errorMessage;

  /// Set when the job posted but its address didn't save; reported after the pop.
  String? _addressWarning;
  String? get addressWarning => _addressWarning;

  /// What:   Drafts one task from a rough note.
  /// Input:  [task] tag, [roughText] and that task's [photoUrl]; AssistRepository.suggestDraft() (assist_repository.dart).
  /// Output: JobDraft, or null when none is available; sets [draftingTask] meanwhile.
  Future<JobDraft?> suggestDraft(Object task, String roughText,
      {String? photoUrl}) async {
    draftingTask = task;
    _notify();
    try {
      return await _assist.suggestDraft(
          roughText: roughText, photoUrl: photoUrl);
    } finally {
      draftingTask = null;
      _notify();
    }
  }

  /// What:   Fetches a fair-price range for one task.
  /// Input:  [task] tag, its [category], [description] and [photoUrl]; AssistRepository.suggestPriceRange().
  /// Output: The range, or null; stores it in [priceHints] (clears it on null) and marks the task as pricing meanwhile.
  Future<({int minSen, int maxSen})?> suggestPrice(
    Object task, {
    required String category,
    required String description,
    String? photoUrl,
  }) async {
    _pricingTasks.add(task);
    _notify();
    try {
      final hint = await _assist.suggestPriceRange(
          category: category, description: description, photoUrl: photoUrl);
      if (hint != null) {
        priceHints[task] = hint;
      } else {
        priceHints.remove(task);
      }
      return hint;
    } finally {
      _pricingTasks.remove(task);
      _notify();
    }
  }

  /// What:   Drops a removed task's price hint.
  void forgetTask(Object task) => priceHints.remove(task);

  void setCategory(String? value) {
    category = value;
    notifyListeners();
  }

  void setLocation(PickedLocation value) {
    location = value;
    notifyListeners();
  }

  /// What:   Sets the initial location without notifying.
  /// Notes:  Called from initState; notifying during the provider's build trips a framework assertion.
  void seedLocation(PickedLocation value) {
    location = value;
  }

  void setAddress(ServiceAddress? a) {
    pendingAddress = a;
    notifyListeners();
  }

  /// What:   Picks a gallery photo and uploads it.
  /// Input:  [uid] of the poster.
  /// Output: Adds the URL to [photoUrls] via DocumentStorageRepository.uploadJobPhoto(); sets [errorMessage] on failure.
  Future<void> addPhoto(String uid) async {
    final XFile? file;
    try {
      file = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        imageQuality: 85,
      );
    } catch (_) {
      _errorMessage = 'Could not open the photo picker.';
      _notify();
      return;
    }
    if (file == null) return;

    _setUploadingPhoto(true);
    try {
      photoUrls.add(await _storage.uploadJobPhoto(uid: uid, file: file));
    } catch (_) {
      _errorMessage = 'Could not upload the photo. Please try again.';
    } finally {
      _setUploadingPhoto(false);
    }
  }

  /// What:   Removes a photo from the post.
  /// Output: Drops the URL and deletes the stored file in the background.
  void removePhoto(String url) {
    photoUrls.remove(url);
    notifyListeners();
    _storage.deleteByUrl(url).catchError((_) {});
  }

  /// What:   Creates a single job.
  /// Input:  [job] built by the form; [pendingAddress].
  /// Output: The new job id, or null on failure with [errorMessage].
  /// Notes:  A failed address write never loses the job; it sets [addressWarning].
  Future<String?> submit(Job job) async {
    _isSubmitting = true;
    _errorMessage = null;
    _addressWarning = null;
    _notify();
    try {
      final id = await _jobs.create(job);
      final address = pendingAddress;
      if (address != null) {
        try {
          await _jobs.setJobAddress(id, address);
        } catch (_) {
          // Must not fail the post, but can't be silent: the requestor would
          // only learn the address was lost when the provider couldn't find them.
          _addressWarning =
              "Job posted, but the service address didn't save. Add it "
              'again from the job page.';
        }
      }
      return id;
    } catch (_) {
      _errorMessage = 'Could not post the job. Please try again.';
      return null;
    } finally {
      _isSubmitting = false;
      _notify();
    }
  }

  /// What:   Posts several tasks as one bundle.
  /// Input:  Title, description, shared [location], [tasks] and optional [deadline]; the current [photoUrls].
  /// Output: The new bundle id via BundleRepository.create(), or null on failure with [errorMessage].
  Future<String?> submitBundle({
    required String title,
    required String description,
    required JobLocation location,
    required List<BundleTaskDraft> tasks,
    DateTime? deadline,
  }) async {
    _isSubmitting = true;
    _errorMessage = null;
    _addressWarning = null;
    _notify();
    try {
      return await _bundles.create(
        title: title,
        description: description,
        location: location,
        tasks: tasks,
        photoUrls: List.of(photoUrls),
        deadline: deadline,
      );
    } on BundleRejectedException catch (e) {
      // Server-written for requestors, so shown as-is.
      _errorMessage = e.message;
      return null;
    } catch (_) {
      _errorMessage = 'Could not post the bundle. Please try again.';
      return null;
    } finally {
      _isSubmitting = false;
      _notify();
    }
  }

  void _setUploadingPhoto(bool value) {
    _uploadingPhoto = value;
    _notify();
  }

  /// What:   notifyListeners() that is safe after dispose.
  /// Notes:  Skipped once disposed, so late async results don't throw.
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
