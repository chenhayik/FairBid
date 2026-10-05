import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

import '../data/document_storage_repository.dart';
import '../data/requestor_onboarding_repository.dart';
import '../domain/requestor_onboarding_data.dart';

/// ViewModel of the requestor onboarding flow: owns the data being filled in,
/// loads/saves it per user, uploads the optional photo/document, and moves
/// between the three stages. Mirrors [OnboardingController] but lighter.
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

  /// True while the upload named [purpose] ('avatar' or 'client_document') is
  /// in flight.
  bool isUploading(String purpose) => _uploadingPurpose == purpose;

  /// Loads saved progress for [uid] once; subsequent calls are no-ops. Seeds
  /// the full name from the account's [fallbackName] when none is saved yet.
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

  /// Saves the current stage and advances to the next one. If the save fails
  /// the step is rolled back, so the UI doesn't jump ahead of persisted state.
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

  /// Final submission from the last stage; marks onboarding complete.
  Future<bool> finish() => _run(() => _repository.complete(_loadedUid!, data));

  /// Step back one stage (back arrow). Returns false when already at the first
  /// stage (caller may sign out instead).
  bool goBack() {
    if (data.step <= RequestorOnboardingData.firstStep) return false;
    data.step--;
    notifyListeners();
    return true;
  }

  // The profile photo goes to `avatars/{uid}/...` (world-readable to any
  // signed-in user, see storage.rules) rather than `verification/{uid}/...`,
  // so it can be shown to counterparties on bids/jobs/chats. Photos from
  // before this change are still stored under `verification/` - they keep
  // resolving fine via their tokened download URLs, they just aren't
  // re-uploaded on re-save.
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
