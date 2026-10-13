import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

import '../data/document_storage_repository.dart';
import '../data/requestor_onboarding_repository.dart';
import '../domain/requestor_onboarding_data.dart';

/// What:   Requestor onboarding state: the draft, optional uploads and stage moves.
/// Input:  RequestorOnboardingRepository, DocumentStorageRepository.
/// Output: Notifies listeners; saveAndContinue/finish persist the data.
class RequestorOnboardingController extends ChangeNotifier {
  RequestorOnboardingController(
    this._repository,
    this._storage, {
    ImagePicker? imagePicker,
  }) : _picker = imagePicker ?? ImagePicker();

  final RequestorOnboardingRepository _repository;
  final DocumentStorageRepository _storage;
  final ImagePicker _picker;

  RequestorOnboardingData data = RequestorOnboardingData();
  String? _loadedUid;
  bool _busy = false;
  String? _uploadingPurpose;
  String? _errorMessage;

  bool get isLoaded => _loadedUid != null;
  bool get isBusy => _busy;
  String? get errorMessage => _errorMessage;

  /// True while the upload named [purpose] ('avatar' or 'client_document') runs.
  bool isUploading(String purpose) => _uploadingPurpose == purpose;

  /// Loads saved progress for [uid] once; seeds the name from [fallbackName] if none is saved.
  Future<void> loadFor(String uid, {String? fallbackName}) async {
    if (_loadedUid == uid) return;
    _loadedUid = uid;
    try {
      data = await _repository.load(uid);
    } catch (_) {
      data = RequestorOnboardingData();
    }
    if (data.fullName.isEmpty && fallbackName != null) {
      data.fullName = fallbackName;
    }
    notifyListeners();
  }

  void selectType(RequestorType type) {
    data.type = type;
    notifyListeners();
  }

  /// Saves, then advances a stage; a failed save rolls the step back.
  Future<void> saveAndContinue() => _run(() async {
        final previous = data.step;
        if (data.step < RequestorOnboardingData.lastStep) data.step++;
        try {
          await _repository.save(_loadedUid!, data);
        } catch (_) {
          data.step = previous;
          rethrow;
        }
      });

  /// Final submission; marks onboarding complete.
  Future<bool> finish() => _run(() => _repository.complete(_loadedUid!, data));

  /// Steps back one stage; false at the first stage.
  bool goBack() {
    if (data.step <= RequestorOnboardingData.firstStep) return false;
    data.step--;
    notifyListeners();
    return true;
  }

  // Goes to `avatars/` (signed-in readable) so counterparties can see it.
  Future<void> pickProfilePhoto() => _pickAndUpload(
        purpose: 'avatar',
        upload: (file) => _storage.uploadAvatar(uid: _loadedUid!, file: file),
        apply: (url) => data.profilePhotoUrl = url,
      );

  Future<void> pickVerificationDocument() => _pickAndUpload(
        purpose: 'client_document',
        upload: (file) => _storage.uploadVerificationImage(
          uid: _loadedUid!,
          purpose: 'client_document',
          file: file,
        ),
        apply: (url) => data.clientDocumentUrl = url,
      );

  Future<void> _pickAndUpload({
    required String purpose,
    required Future<String> Function(XFile file) upload,
    required void Function(String url) apply,
  }) async {
    if (_uploadingPurpose != null) return; // one upload at a time
    final XFile? file;
    try {
      file = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        imageQuality: 85,
      );
    } catch (_) {
      _errorMessage = 'Could not open the photo picker.';
      notifyListeners();
      return;
    }
    if (file == null) return; // cancelled

    _busy = true;
    _uploadingPurpose = purpose;
    _errorMessage = null;
    notifyListeners();
    try {
      apply(await upload(file));
    } catch (_) {
      _errorMessage = 'Could not upload the file. Please try again.';
    } finally {
      _busy = false;
      _uploadingPurpose = null;
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
