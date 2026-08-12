import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

import '../../../../core/location/region.dart';
import '../../../onboarding/data/document_storage_repository.dart';
import '../../data/assist_repository.dart';
import '../../data/job_repository.dart';
import '../../domain/job.dart';
import '../../domain/service_address.dart';

/// ViewModel for the Post-a-Job form: holds the category, picked location and
/// uploaded photo URLs, creates the job, and runs the optional Gemini
/// assists (description helper, fair-price guide).
class PostJobController extends ChangeNotifier {
  PostJobController(
    this._jobs,
    this._storage,
    this._assist, {
    ImagePicker? imagePicker,
  }) : _picker = imagePicker ?? ImagePicker();

  final JobRepository _jobs;
  final DocumentStorageRepository _storage;
  final AssistRepository _assist;
  final ImagePicker _picker;

  String? category;
  PickedLocation? location;

  /// The precise service address to attach once the job is created, if the
  /// requestor added one - entirely optional (see `setAddress`).
  ServiceAddress? pendingAddress;
  final List<String> photoUrls = [];

  /// The job's single optional attached video, or null. Replacing it (via
  /// [addVideo]) uploads the new one first, then best-effort deletes the old.
  String? videoUrl;

  // Three separate busy flags - rather than one shared `_busy` - so a photo
  // upload, a video upload and the overall submit are never indistinguishable
  // to the UI: the submit overlay must show only for [isSubmitting], and each
  // UploadBox's in-place spinner only for its own upload.
  bool _isSubmitting = false;
  bool _uploadingPhoto = false;
  bool _uploadingVideo = false;
  String? _errorMessage;

  /// A picked video's file size must stay under this cap. `maxDuration` on
  /// the image_picker call isn't reliably enforced on gallery picks, so this
  /// is a second guardrail, checked after picking.
  static const _maxVideoBytes = 45 * 1024 * 1024; // 45 MB

  // Assist state. Separate busy flags so a pending suggestion never blocks
  // the Post Job button, and vice versa. Failures never touch
  // [_errorMessage] - a missing suggestion is not a form error.
  bool assistingDescription = false;
  bool assistingPrice = false;

  /// The last suggested fair-price range, shown beside the budget fields.
  ({int minSen, int maxSen})? priceHint;

  /// True while the job itself is being created - drives the full-screen
  /// blocking overlay, so submit feedback is visible regardless of scroll
  /// position.
  bool get isSubmitting => _isSubmitting;

  /// True while a photo is being picked/uploaded - drives the in-place
  /// spinner on the photo UploadBox only.
  bool get uploadingPhoto => _uploadingPhoto;

  /// True while the video is being picked/uploaded - drives the in-place
  /// spinner on the video UploadBox only.
  bool get uploadingVideo => _uploadingVideo;

  /// Any of the above in flight. Used to gate actions - like the AI assists -
  /// that shouldn't run concurrently with a submit or an upload; the submit
  /// button and each UploadBox use their own specific flag above instead.
  bool get isBusy => _isSubmitting || _uploadingPhoto || _uploadingVideo;

  String? get errorMessage => _errorMessage;

  /// Set when the job was created but its service address write failed. Not a
  /// form error (the post succeeded), so it is reported after the pop rather
  /// than in the banner.
  String? _addressWarning;
  String? get addressWarning => _addressWarning;

  /// Expands [roughText] into a structured description, or null when no
  /// suggestion is available. The screen decides what to do with the result.
  Future<String?> suggestDescription(String roughText) async {
    final selectedCategory = category;
    if (selectedCategory == null) return null;
    assistingDescription = true;
    notifyListeners();
    try {
      return await _assist.suggestDescription(
          category: selectedCategory,
          roughText: roughText,
          photoUrl: photoUrls.isNotEmpty ? photoUrls.first : null);
    } finally {
      assistingDescription = false;
      notifyListeners();
    }
  }

  /// Fetches a fair-price range for [description] into [priceHint] (null on
  /// a miss).
  Future<void> suggestPrice(String description) async {
    final selectedCategory = category;
    if (selectedCategory == null) return;
    assistingPrice = true;
    notifyListeners();
    try {
      priceHint = await _assist.suggestPriceRange(
          category: selectedCategory,
          description: description,
          photoUrl: photoUrls.isNotEmpty ? photoUrls.first : null);
    } finally {
      assistingPrice = false;
      notifyListeners();
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

  /// Picks, validates and uploads one optional job video, replacing any
  /// video already attached. A 60-second gallery cap is requested, but
  /// isn't reliably enforced by the platform picker, so a 45 MB file-size
  /// cap is re-checked here - an oversized pick is rejected without ever
  /// starting the upload.
  Future<void> addVideo(String uid) async {
    final XFile? file;
    try {
      file = await _picker.pickVideo(
        source: ImageSource.gallery,
        maxDuration: const Duration(seconds: 60),
      );
    } catch (_) {
      _fail('Could not open the video picker.');
      return;
    }
    if (file == null) return;

    final size = await file.length();
    if (size > _maxVideoBytes) {
      _fail('Video must be 60 seconds or shorter and under 45 MB.');
      return;
    }

    _setUploadingVideo(true);
    try {
      final newUrl = await _storage.uploadJobVideo(uid: uid, file: file);
      final oldUrl = videoUrl;
      videoUrl = newUrl;
      if (oldUrl != null) _storage.deleteByUrl(oldUrl).catchError((_) {});
    } catch (_) {
      _errorMessage = 'Could not upload the video. Please try again.';
    } finally {
      _setUploadingVideo(false);
    }
  }

  void removeVideo() {
    final url = videoUrl;
    if (url == null) return;
    videoUrl = null;
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
    notifyListeners();
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
      notifyListeners();
    }
  }

  void _setUploadingPhoto(bool value) {
    _uploadingPhoto = value;
    notifyListeners();
  }

  void _setUploadingVideo(bool value) {
    _uploadingVideo = value;
    notifyListeners();
  }

  void _fail(String message) {
    _errorMessage = message;
    notifyListeners();
  }
}
