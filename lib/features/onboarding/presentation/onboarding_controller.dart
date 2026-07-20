import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

import '../data/document_storage_repository.dart';
import '../data/onboarding_repository.dart';
import '../domain/onboarding_data.dart';

/// ViewModel of the onboarding flow: owns the [OnboardingData] being filled in,
/// loads/saves it per user, uploads picked images to Storage, and moves
/// between stages.
class OnboardingController extends ChangeNotifier {
  OnboardingController(
    this._repository,
    this._storage, {
    ImagePicker? imagePicker,
  }) : _picker = imagePicker ?? ImagePicker();

  final OnboardingRepository _repository;
  final DocumentStorageRepository _storage;
  final ImagePicker _picker;

  OnboardingData data = OnboardingData();
  String? _loadedUid;
  bool _busy = false;
  String? _errorMessage;

  bool get isLoaded => _loadedUid != null;
  bool get isBusy => _busy;
  String? get errorMessage => _errorMessage;

  /// Loads saved progress for [uid] once; subsequent calls are no-ops.
  Future<void> loadFor(String uid) async {
    if (_loadedUid == uid) return;
    _loadedUid = uid;
    try {
      data = await _repository.load(uid);
    } catch (_) {
      data = OnboardingData(); // start fresh if the load fails
    }
    notifyListeners();
  }

  /// Saves the current stage and advances to the next one. If the save fails
  /// the step is rolled back, so the UI doesn't jump ahead of persisted state.
  Future<void> saveAndContinue() => _run(() async {
        final previous = data.step;
        if (data.step < OnboardingData.lastStep) data.step++;
        try {
          await _repository.save(_loadedUid!, data);
        } catch (_) {
          data.step = previous;
          rethrow;
        }
      });

  /// Saves without advancing ("Save for Later").
  Future<bool> saveDraft() => _run(() => _repository.save(_loadedUid!, data));

  /// Final submission from the payout stage; flips status to pending review.
  Future<bool> submitForReview() =>
      _run(() => _repository.submitForReview(_loadedUid!, data));

  /// Step back one stage (back arrow). Returns false when already at the
  /// first stage (caller may sign out instead).
  bool goBack() {
    if (data.step <= OnboardingData.firstStep) return false;
    data.step--;
    notifyListeners();
    return true;
  }

  void selectProviderType(ProviderType type) {
    data.providerType = type;
    notifyListeners();
  }

  /// [source] is chosen by the caller (see `showImageSourceSheet`) so the user
  /// can photograph their ID or pick an existing scan.
  Future<void> pickIdDocument(ImageSource source) => _pickAndUpload(
        purpose: 'id_document',
        source: source,
        apply: (url) => data.idDocumentUrl = url,
      );

  /// [source] is chosen by the caller — a selfie is usually taken live, but an
  /// existing photo from the gallery is allowed too.
  Future<void> pickSelfie(ImageSource source) => _pickAndUpload(
        purpose: 'selfie',
        source: source,
        apply: (url) => data.selfieUrl = url,
      );

  Future<void> pickCertificate() => _pickAndUpload(
        purpose: 'certificate_${DateTime.now().millisecondsSinceEpoch}',
        source: ImageSource.gallery,
        apply: (url) => data.certificateUrls.add(url),
      );

  Future<void> pickPortfolioImage() => _pickAndUpload(
        purpose: 'portfolio_${DateTime.now().millisecondsSinceEpoch}',
        source: ImageSource.gallery,
        apply: (url) => data.portfolioImageUrls.add(url),
      );

  /// Removes the image from local state and best-effort deletes it from
  /// Storage (failures are ignored — the file may already be gone).
  void removePortfolioImage(String url) {
    data.portfolioImageUrls.remove(url);
    notifyListeners();
    _storage.deleteByUrl(url).catchError((_) {});
  }

  void addSkill(String skill) {
    final trimmed = skill.trim();
    if (trimmed.isEmpty || data.skills.contains(trimmed)) return;
    data.skills.add(trimmed);
    notifyListeners();
  }

  void removeSkill(String skill) {
    data.skills.remove(skill);
    notifyListeners();
  }

  /// Picks an image from [source], uploads it to Storage under the current
  /// user's folder, and applies the resulting download URL to [data] via
  /// [apply].
  Future<void> _pickAndUpload({
    required String purpose,
    required void Function(String url) apply,
    required ImageSource source,
  }) async {
    final XFile? file;
    try {
      file = await _picker.pickImage(
        source: source,
        maxWidth: 1600,
        imageQuality: 85,
      );
    } catch (_) {
      _errorMessage = source == ImageSource.camera
          ? 'Could not open the camera.'
          : 'Could not open the photo picker.';
      notifyListeners();
      return;
    }
    if (file == null) return; // user cancelled

    _busy = true;
    _errorMessage = null;
    notifyListeners();
    try {
      final url = await _storage.uploadVerificationImage(
        uid: _loadedUid!,
        purpose: purpose,
        file: file,
      );
      apply(url);
    } catch (_) {
      _errorMessage = 'Could not upload the file. Please try again.';
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<bool> _run(Future<void> Function() action) async {
    _busy = true;
    _errorMessage = null;
    notifyListeners();
    try {
      await action();
      return true;
    } catch (_) {
      _errorMessage = 'Could not save your progress. Please try again.';
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }
}
