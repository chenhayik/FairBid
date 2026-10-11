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

  /// Bundle photos tagged only to other tasks, so task 1's AI skips them.
  Set<String> skipForAssist = {};

  /// The photo the AI assists read: the first one that shows task 1.
  String? get _assistPhoto =>
      photoUrls.where((u) => !skipForAssist.contains(u)).firstOrNull;

  // Separate flags so the submit overlay and the photo spinner never mix.
  bool _isSubmitting = false;
  bool _uploadingPhoto = false;
  String? _errorMessage;

  // Assist state. A price lookup never blocks posting; a draft does (see [isBusy]).
  // Failures leave [_errorMessage] alone: a missing suggestion is not a form error.
  bool assistingPrice = false;
  bool assistingDraft = false;

  bool _disposed = false;

  /// The last suggested fair-price range, shown beside the budget fields.
  ({int minSen, int maxSen})? priceHint;

  /// True while the job is being created; drives the blocking overlay.
  bool get isSubmitting => _isSubmitting;

  /// True while a photo uploads; drives the photo box spinner.
  bool get uploadingPhoto => _uploadingPhoto;

  /// A submit, upload or draft is in flight; gates actions that must not overlap.
  bool get isBusy => _isSubmitting || _uploadingPhoto || assistingDraft;

  String? get errorMessage => _errorMessage;

  /// Set when the job posted but its address didn't save; reported after the pop.
  String? _addressWarning;
  String? get addressWarning => _addressWarning;

  /// Drafts a post from [roughText], or null when none is available.
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

  /// Fetches a fair-price range for [description] into [priceHint].
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

  /// Sets the location from initState without notifying; notifying during the
  /// provider's build trips a framework assertion.
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

  void removePhoto(String url) {
    photoUrls.remove(url);
    notifyListeners();
    _storage.deleteByUrl(url).catchError((_) {});
  }

  /// Creates the job and returns its id, or null on failure. A failed
  /// [pendingAddress] write never loses the job; it sets [addressWarning].
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

  /// Posts [tasks] as one bundle via `createBundle`; returns its id, or null on failure.
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

  /// notifyListeners(), skipped after dispose so late async results are safe.
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
