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
  /// requestor added one — entirely optional (see `setAddress`).
  ServiceAddress? pendingAddress;
  final List<String> photoUrls = [];
  bool _busy = false;
  String? _errorMessage;

  // Assist state. Separate busy flags so a pending suggestion never blocks
  // the Post Job button, and vice versa. Failures never touch
  // [_errorMessage] — a missing suggestion is not a form error.
  bool assistingDescription = false;
  bool assistingPrice = false;

  /// The last suggested fair-price range, shown beside the budget fields.
  ({int minSen, int maxSen})? priceHint;

  bool get isBusy => _busy;
  String? get errorMessage => _errorMessage;

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

    _setBusy(true);
    try {
      photoUrls.add(await _storage.uploadJobPhoto(uid: uid, file: file));
    } catch (_) {
      _errorMessage = 'Could not upload the photo. Please try again.';
    } finally {
      _setBusy(false);
    }
  }

  void removePhoto(String url) {
    photoUrls.remove(url);
    notifyListeners();
    _storage.deleteByUrl(url).catchError((_) {});
  }

  /// Creates the job and returns its new id, or null on failure. When an
  /// optional [pendingAddress] was set, best-effort attaches it after the
  /// job is created — a failed address write never loses the created job.
  Future<String?> submit(Job job) async {
    _setBusy(true);
    _errorMessage = null;
    try {
      final id = await _jobs.create(job);
      final address = pendingAddress;
      if (address != null) {
        try {
          await _jobs.setJobAddress(id, address);
        } catch (_) {
          // Best-effort only — the job itself was created successfully.
        }
      }
      return id;
    } catch (_) {
      _errorMessage = 'Could not post the job. Please try again.';
      return null;
    } finally {
      _setBusy(false);
    }
  }

  void _setBusy(bool value) {
    _busy = value;
    notifyListeners();
  }

  void _fail(String message) {
    _errorMessage = message;
    notifyListeners();
  }
}
