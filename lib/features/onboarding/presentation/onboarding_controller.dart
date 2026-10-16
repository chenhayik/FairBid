import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/util/document_picker.dart';
import '../../../core/util/ssm_number.dart';
import '../data/document_storage_repository.dart';
import '../data/face_checker.dart';
import '../data/onboarding_repository.dart';
import '../domain/id_extract.dart';
import '../domain/onboarding_data.dart';
import '../domain/ssm_extract.dart';

/// What:   Provider onboarding state: the draft, uploads and stage moves.
/// Input:  OnboardingRepository, DocumentStorageRepository, FaceChecker, ID/SSM extract streams.
/// Output: Notifies listeners; saveAndContinue/submitForReview persist the data.
class OnboardingController extends ChangeNotifier {
  OnboardingController(
    this._repository,
    this._storage, {
    ImagePicker? imagePicker,
    Future<XFile?> Function()? pdfPicker,
    FaceChecker? faceChecker,
  })  : _picker = imagePicker ?? ImagePicker(),
        _pdfPicker = pdfPicker ?? pickSsmPdf,
        _faceChecker = faceChecker ?? const MlKitFaceChecker();

  final OnboardingRepository _repository;
  final DocumentStorageRepository _storage;
  final ImagePicker _picker;
  final FaceChecker _faceChecker;

  /// Injectable because widget tests can't drive the system document picker.
  final Future<XFile?> Function() _pdfPicker;

  OnboardingData data = OnboardingData();
  String? _loadedUid;
  bool _busy = false;
  String? _uploadingPurpose;
  bool _checkingFace = false;
  String? _errorMessage;

  SsmExtract? _ssmExtract;
  StreamSubscription<SsmExtract?>? _extractSub;
  Timer? _extractTimeout;
  bool _ssmUploading = false;
  bool _ssmProfileUploading = false;
  bool _ssmCheckTimedOut = false;

  IdExtract? _idExtract;
  StreamSubscription<IdExtract?>? _idExtractSub;
  Timer? _idTimeout;
  bool _idCheckTimedOut = false;

  /// How long to show "checking" before admitting the verdict is late.
  static const _extractWait = Duration(seconds: 30);

  bool get isLoaded => _loadedUid != null;
  bool get isBusy => _busy;
  String? get errorMessage => _errorMessage;

  /// True while an upload whose purpose starts with [purpose] is in flight, face check included.
  bool isUploading(String purpose) =>
      _uploadingPurpose?.startsWith(purpose) ?? false;

  bool get checkingFace => _checkingFace;

  /// The server's reading of the SSM document, or null; proposals only until [applySsmExtract].
  SsmExtract? get ssmExtract => _ssmExtract;
  bool get isSsmUploading => _ssmUploading;
  bool get isSsmProfileUploading => _ssmProfileUploading;

  /// True once [_extractWait] passed with no verdict; only changes the wording.
  bool get ssmCheckTimedOut => _ssmCheckTimedOut;

  /// The server's advisory reading of the MyKad photo, or null; never gates Continue.
  IdExtract? get idExtract => _idExtract;
  bool get idCheckTimedOut => _idCheckTimedOut;

  /// What:   Loads saved progress once and starts watching the server's document checks.
  /// Input:  [uid]; OnboardingRepository.load(), watchSsmExtract(), watchIdExtract() (onboarding_repository.dart).
  /// Output: Fills [data] (a fresh draft if the load fails) and updates the SSM / ID verdicts as they arrive.
  /// Notes:  Subscribed on load, not after an upload, because the extract outlives the session.
  Future<void> loadFor(String uid) async {
    if (_loadedUid == uid) return;
    _loadedUid = uid;
    try {
      data = await _repository.load(uid);
    } catch (_) {
      data = OnboardingData(); // start fresh if the load fails
    }
    // Subscribed on load, not after an upload: the extract outlives the session.
    _extractSub ??= _repository.watchSsmExtract(uid).listen((extract) {
      _ssmExtract = extract;
      if (extract != null) {
        _extractTimeout?.cancel();
        _ssmCheckTimedOut = false;
      }
      notifyListeners();
    });
    _idExtractSub ??= _repository.watchIdExtract(uid).listen((extract) {
      _idExtract = extract;
      if (extract != null) {
        _idTimeout?.cancel();
        _idCheckTimedOut = false;
      }
      notifyListeners();
    });
    notifyListeners();
  }

  /// What:   Saves the draft, then moves to the next stage.
  /// Input:  [data]; OnboardingRepository.save().
  /// Output: Advances [data].step; a failed save rolls the step back and sets [errorMessage].
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

  /// What:   Saves the draft without moving stage.
  /// Input:  [data]; OnboardingRepository.save().
  /// Output: True on success; false with [errorMessage] set.
  Future<bool> saveDraft() => _run(() => _repository.save(_loadedUid!, data));

  /// What:   Submits the application from the payout stage.
  /// Input:  [data]; OnboardingRepository.submitForReview().
  /// Output: Saves everything and sets the status to pending review; false with [errorMessage] on failure.
  Future<bool> submitForReview() =>
      _run(() => _repository.submitForReview(_loadedUid!, data));

  /// What:   Steps back one stage.
  /// Input:  [data].step.
  /// Output: False at the first stage; otherwise true after decrementing.
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

  /// What:   Uploads the ID photo from [source] (camera or gallery).
  /// Input:  Image picker; needs PDPA consent and passes the on-device face check.
  /// Output: Sets the ID URL and face box, clears the old verdict and starts the verdict wait.
  /// Notes:  The draft is saved first because the server reads the saved type and number as the photo lands.
  Future<void> pickIdDocument(ImageSource source) => _pickAndUpload(
        purpose: 'id_document',
        source: source,
        faceKind: FaceCheckKind.idCard,
        applyBox: (box) => data.idFaceBox = box,
        apply: (url) {
          data.idDocumentUrl = url;
          _startIdWait();
        },
        // A new upload supersedes the verdict; the server reads the saved type
        // and number as the photo lands, so save first.
        beforeUpload: () async {
          _idExtract = null;
          _idCheckTimedOut = false;
          await _repository.save(_loadedUid!, data);
        },
      );

  /// What:   Bounds the wait for the ID verdict, as with SSM.
  /// Input:  [_extractWait].
  /// Output: Sets [idCheckTimedOut] if no verdict arrives in time.
  void _startIdWait() {
    _idTimeout?.cancel();
    _idTimeout = Timer(_extractWait, () {
      if (_idExtract != null) return;
      _idCheckTimedOut = true;
      notifyListeners();
    });
  }

  /// What:   Switches between MyKad and passport.
  /// Input:  [type] chosen in IdentityStep.
  /// Output: A changed type clears the uploaded ID, which was never checked under the new type.
  void setIdDocumentType(IdDocumentType type) {
    if (type != data.idDocumentType) {
      data
        ..idDocumentUrl = null
        ..idFaceBox = null;
    }
    data.idDocumentType = type;
    notifyListeners();
  }

  /// What:   Stores the typed IC number.
  /// Input:  [value] from the IC field.
  /// Output: A change in the digits clears the uploaded ID.
  void setIcNumber(String value) {
    final changed = _digits(value) != _digits(data.icNumber);
    data.icNumber = value.trim();
    if (changed) {
      data
        ..idDocumentUrl = null
        ..idFaceBox = null;
    }
  }

  /// Records (or withdraws) the PDPA consent to ID/face processing.
  void setIdConsent(bool agreed) {
    data.idConsentAt = agreed ? DateTime.now() : null;
    notifyListeners();
  }

  static String _digits(String s) => s.replaceAll(RegExp(r'\D'), '');

  /// Uploads the selfie from [source].
  Future<void> pickSelfie(ImageSource source) => _pickAndUpload(
        purpose: 'selfie',
        source: source,
        faceKind: FaceCheckKind.selfie,
        applyBox: (box) => data.selfieFaceBox = box,
        apply: (url) => data.selfieUrl = url,
      );

  /// What:   Picks an SSM PDF.
  /// Input:  The injected document picker (pickSsmPdf by default).
  /// Output: The file, or null when cancelled or unusable (the error message is set).
  Future<XFile?> _pickPdf() async {
    try {
      return await _pdfPicker();
    } on DocumentPickException catch (e) {
      _errorMessage = e.message;
      notifyListeners();
      return null;
    }
  }

  /// What:   Uploads the SSM document untouched, then waits for the server's reading.
  /// Input:  PDF picker; DocumentStorageRepository.uploadVerificationImage().
  /// Output: Sets the document URL and a timeout for the verdict; sets an error on failure.
  /// Notes:  The typed number is saved first because the server trigger reads it the instant the bytes land.
  Future<void> pickSsmDocument() async {
    final file = await _pickPdf();
    if (file == null) return;

    _ssmUploading = true;
    _errorMessage = null;
    _ssmExtract = null; // a fresh upload supersedes any previous verdict
    _ssmCheckTimedOut = false;
    notifyListeners();
    try {
      // Save the typed number first: the server trigger reads it from
      // Firestore the instant the bytes land. A failure only skips the cross-check.
      try {
        await _repository.save(_loadedUid!, data);
      } catch (_) {}
      data.ssmDocumentUrl = await _storage.uploadVerificationImage(
        uid: _loadedUid!,
        purpose: 'ssm_document',
        file: file,
      );
      // The verdict arrives on the loadFor watch; bound the wait so a failed
      // function shows a message instead of an endless spinner.
      _extractTimeout?.cancel();
      _extractTimeout = Timer(_extractWait, () {
        if (_ssmExtract != null) return;
        _ssmCheckTimedOut = true;
        notifyListeners();
      });
    } catch (_) {
      _errorMessage = 'Could not upload the document. Please try again.';
    } finally {
      _ssmUploading = false;
      notifyListeners();
    }
  }

  /// What:   Uploads the optional SSM Business Profile.
  /// Input:  PDF picker; DocumentStorageRepository.uploadVerificationImage().
  /// Output: Server reads it, then deletes it; only the owner-name result reaches the client via the extract watch.
  Future<void> pickSsmProfile() async {
    final file = await _pickPdf();
    if (file == null) return;

    _ssmProfileUploading = true;
    _errorMessage = null;
    notifyListeners();
    try {
      await _storage.uploadVerificationImage(
        uid: _loadedUid!,
        purpose: 'ssm_profile',
        file: file,
      );
    } catch (_) {
      _errorMessage = 'Could not upload the profile. Please try again.';
    } finally {
      _ssmProfileUploading = false;
      notifyListeners();
    }
  }

  /// What:   Copies the server's SSM proposals into the form.
  /// Input:  [ssmExtract] business name and registration number.
  /// Output: Updates [data]; runs only on "Use these details".
  void applySsmExtract() {
    final extract = _ssmExtract;
    if (extract == null) return;
    final name = extract.businessName;
    if (name != null && name.isNotEmpty) data.businessName = name;
    final number = extract.registrationNumber;
    if (number != null && number.isNotEmpty) setSsmNumber(number);
    notifyListeners();
  }

  /// What:   Stores the typed SSM number with its canonical form.
  /// Input:  [value] from the SSM field; SsmNumber.parse() (ssm_number.dart).
  /// Output: Sets ssmNumber and ssmNumberNormalized together.
  void setSsmNumber(String value) {
    data
      ..ssmNumber = value.trim()
      ..ssmNumberNormalized = SsmNumber.parse(value)?.normalized ?? '';
  }

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

  /// Removes the image locally and best-effort deletes it from Storage.
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

  /// What:   Picks an image, uploads it and hands the URL to [apply].
  /// Input:  [purpose] storage name; [source]; optional [faceKind], [beforeUpload] and [applyBox].
  /// Output: Sets busy and error state; one upload at a time.
  /// How:    With a [faceKind] consent must exist and the on-device face check must pass; the face goes to [applyBox].
  Future<void> _pickAndUpload({
    required String purpose,
    required void Function(String url) apply,
    required ImageSource source,
    Future<void> Function()? beforeUpload,
    FaceCheckKind? faceKind,
    void Function(FaceBox? box)? applyBox,
  }) async {
    if (faceKind != null && data.idConsentAt == null) return;
    if (_uploadingPurpose != null) return; // one upload at a time
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
    _uploadingPurpose = purpose;
    _errorMessage = null;
    notifyListeners();
    try {
      FaceBox? box;
      if (faceKind != null) {
        _checkingFace = true;
        notifyListeners();
        final result = await _faceChecker.check(file.path, faceKind);
        _checkingFace = false;
        notifyListeners();
        if (result.problem != null) {
          _errorMessage = result.problem;
          return;
        }
        box = result.box;
      }
      await beforeUpload?.call();
      final url = await _storage.uploadVerificationImage(
        uid: _loadedUid!,
        purpose: purpose,
        file: file,
      );
      apply(url);
      applyBox?.call(box);
    } catch (_) {
      _errorMessage = 'Could not upload the file. Please try again.';
    } finally {
      _busy = false;
      _checkingFace = false;
      _uploadingPurpose = null;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _extractTimeout?.cancel();
    _extractSub?.cancel();
    _idTimeout?.cancel();
    _idExtractSub?.cancel();
    super.dispose();
  }

  /// What:   Wrapper that runs one save action with busy and error state.
  /// Input:  [action], a repository call.
  /// Output: True on success; false with [errorMessage] set.
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
