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
  String? _errorMessage;

  bool get isLoaded => _loadedUid != null;
  bool get isBusy => _busy;
  String? get errorMessage => _errorMessage;

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

  Future<void> pickProfilePhoto() => _pickAndUpload(
        purpose: 'requestor_photo',
        apply: (url) => data.profilePhotoUrl = url,
      );

  Future<void> pickVerificationDocument() => _pickAndUpload(
        purpose: 'client_document',
        apply: (url) => data.clientDocumentUrl = url,
      );

  Future<void> _pickAndUpload({
    required String purpose,
    required void Function(String url) apply,
  }) async {
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
