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

/// ViewModel for the Post-a-Job form: holds the category, picked location and
/// uploaded photo URLs, creates the job, and runs the optional Gemini
/// assists (description helper, fair-price guide).
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

  /// The precise service address to attach once the job is created, if the
  /// requestor added one - entirely optional (see `setAddress`).
  ServiceAddress? pendingAddress;
  final List<String> photoUrls = [];

  /// Bundle photos tagged only to other tasks, so task 1's AI skips them.
  Set<String> skipForAssist = {};

  /// The photo the AI assists read: the first one that shows task 1.
  String? get _assistPhoto {
    for (final url in photoUrls) {
      if (!skipForAssist.contains(url)) return url;
    }
    return null;
  }

  // Separate flags so the submit overlay and the photo spinner never mix.
  bool _isSubmitting = false;
  bool _uploadingPhoto = false;
  String? _errorMessage;

  // Assist state. Separate busy flags so a pending suggestion never blocks
  // the Post Job button, and vice versa. Failures never touch
  // [_errorMessage] - a missing suggestion is not a form error.
  bool assistingPrice = false;
  bool assistingDraft = false;

  /// Set once [dispose] has run. Checked by [_notify] so a suggestion that
  /// completes after the screen was closed never calls `notifyListeners()`
  /// on a disposed controller.
  bool _disposed = false;

  /// The last suggested fair-price range, shown beside the budget fields.
  ({int minSen, int maxSen})? priceHint;

  /// True while the job itself is being created - drives the full-screen
  /// blocking overlay, so submit feedback is visible regardless of scroll
  /// position.
  bool get isSubmitting => _isSubmitting;

  /// True while a photo is being picked/uploaded - drives the in-place
  /// spinner on the photo UploadBox only.
  bool get uploadingPhoto => _uploadingPhoto;

  /// Any of the above in flight. Used to gate actions - like the AI assists -
  /// that shouldn't run concurrently with a submit or an upload; the submit
  /// button and each UploadBox use their own specific flag above instead.
  bool get isBusy =>
      _isSubmitting || _uploadingPhoto || assistingDraft;

  String? get errorMessage => _errorMessage;

  /// Set when the job was created but its service address write failed. Not a
  /// form error (the post succeeded), so it is reported after the pop rather
  /// than in the banner.
  String? _addressWarning;
  String? get addressWarning => _addressWarning;

  /// Drafts a whole post from [roughText], or null when none is available.
  /// The screen decides which fields to fill.
  Future<JobDraft?> suggestDraft(String roughText) async {
    assistingDraft = true;
    _notify();
    try {
      return await _assist.suggestDraft(
          roughText: roughText,
          photoUrl: _assistPhoto);
    } finally {
      assistingDraft = false;
      _notify();
    }
  }

  /// Fetches a fair-price range for [description] into [priceHint] (null on
  /// a miss).
  Future<void> suggestPrice(String description) async {
    final selectedCategory = category;
    if (selectedCategory == null) return;
    assistingPrice = true;
    _notify();
    try {
      priceHint = await _assist.suggestPriceRange(
          category: selectedCategory,
          description: description,
          photoUrl: _assistPhoto);
    } finally {
      assistingPrice = false;
      _notify();
    }
  }

  void setCategory(String? value) {
    category = value;
    notifyListeners();
  }

  void setLocation(PickedLocation value) {
    location = value;
    notifyListeners();
  }

  /// Seeds the location before the first build, without notifying.
  ///
  /// Called from `initState` to pre-fill "Where" from the requestor's saved
  /// default. [setLocation] cannot be used there: notifying while the owning
  /// `ChangeNotifierProvider` is still building trips a framework assertion
  /// (`'!_dirty': is not true`), so opening Post-a-Job threw for every
  /// requestor who had completed onboarding. No notification is needed here
  /// anyway, since the first build reads this straight after.
  void seedLocation(PickedLocation value) {
    location = value;
  }

  void setAddress(ServiceAddress? a) {
    pendingAddress = a;
    notifyListeners();
  }

  Future<void> addPhoto(String uid) async {
    final XFile? file;
    try {
      file = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        imageQuality: 85,
      );
    } catch (_) {
      _fail('Could not open the photo picker.');
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

  void removePhoto(String url) {
    photoUrls.remove(url);
    notifyListeners();
    _storage.deleteByUrl(url).catchError((_) {});
  }

  /// Creates the job and returns its new id, or null on failure. When an
  /// optional [pendingAddress] was set, best-effort attaches it after the
  /// job is created - a failed address write never loses the created job.
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
          // Best-effort only - the job itself was created successfully, so
          // this must not fail the post. But it can't be silent either: the
          // requestor typed a full address and access notes, and would
          // otherwise only find out it was lost when the hired provider
          // could not find them.
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

  /// Posts several related tasks as ONE bundled posting via `createBundle`,
  /// returning the new bundle's id (null on failure). The precise service
  /// address has no bundle equivalent, so the form hides it.
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
      // The server writes these to be read by a requestor ("Task 2 has no
      // valid category."), so they are shown as they are.
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

  void _fail(String message) {
    _errorMessage = message;
    _notify();
  }

  /// notifyListeners(), skipped once this controller has been disposed - a
  /// suggestion or upload that completes after the screen was closed must
  /// not touch a disposed ChangeNotifier.
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
