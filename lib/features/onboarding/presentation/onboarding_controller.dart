import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/util/document_picker.dart';
import '../../../core/util/ssm_number.dart';
import '../data/document_storage_repository.dart';
import '../data/onboarding_repository.dart';
import '../domain/onboarding_data.dart';
import '../domain/ssm_extract.dart';

/// ViewModel of the onboarding flow: owns the [OnboardingData] being filled in,
/// loads/saves it per user, uploads picked images to Storage, and moves
/// between stages.
class OnboardingController extends ChangeNotifier {
  OnboardingController(
    this._repository,
    this._storage, {
    ImagePicker? imagePicker,
    Future<XFile?> Function()? pdfPicker,
  })  : _picker = imagePicker ?? ImagePicker(),
        _pdfPicker = pdfPicker ?? pickSsmPdf;

  final OnboardingRepository _repository;
  final DocumentStorageRepository _storage;
  final ImagePicker _picker;

  /// Injectable so tests can exercise the upload path; the real one opens the
  /// system document picker, which no widget test can drive.
  final Future<XFile?> Function() _pdfPicker;

  OnboardingData data = OnboardingData();
  String? _loadedUid;
  bool _busy = false;
  String? _errorMessage;

  SsmExtract? _ssmExtract;
  StreamSubscription<SsmExtract?>? _extractSub;
  Timer? _extractTimeout;
  bool _ssmUploading = false;
  bool _ssmProfileUploading = false;
  bool _ssmCheckTimedOut = false;

  /// How long to show "checking" before admitting the verdict is not coming
  /// promptly. A cold-started Cloud Function can take a few seconds; anything
  /// beyond this is a failure the applicant should not sit and watch.
  static const _extractWait = Duration(seconds: 30);

  bool get isLoaded => _loadedUid != null;
  bool get isBusy => _busy;
  String? get errorMessage => _errorMessage;

  /// The server's reading of the uploaded SSM document, or null while none has
  /// arrived. Proposals only - [applySsmExtract] is what commits them.
  SsmExtract? get ssmExtract => _ssmExtract;
  bool get isSsmUploading => _ssmUploading;
  bool get isSsmProfileUploading => _ssmProfileUploading;

  /// True once [_extractWait] has passed with no verdict. The applicant is
  /// never blocked on it, so this only changes the wording.
  bool get ssmCheckTimedOut => _ssmCheckTimedOut;

  /// Loads saved progress for [uid] once; subsequent calls are no-ops.
  Future<void> loadFor(String uid) async {
    if (_loadedUid == uid) return;
    _loadedUid = uid;
    try {
      data = await _repository.load(uid);
    } catch (_) {
      data = OnboardingData(); // start fresh if the load fails
    }
    // Subscribed here rather than after an upload: the extract doc outlives the
    // session that produced it, so an applicant who uploads, closes the app and
    // comes back must still see the verdict.
    _extractSub ??= _repository.watchSsmExtract(uid).listen((extract) {
      _ssmExtract = extract;
      if (extract != null) {
        _extractTimeout?.cancel();
        _ssmCheckTimedOut = false;
      }
      notifyListeners();
    });
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

  /// [source] is chosen by the caller - a selfie is usually taken live, but an
  /// existing photo from the gallery is allowed too.
  Future<void> pickSelfie(ImageSource source) => _pickAndUpload(
        purpose: 'selfie',
        source: source,
        apply: (url) => data.selfieUrl = url,
      );

  /// Picks and uploads the SSM document, then watches for the server's reading
  /// of it. The bytes go up untouched - see [pickSsmPdf].
  Future<void> pickSsmDocument() async {
    final XFile? file;
    try {
      file = await _pdfPicker();
    } on DocumentPickException catch (e) {
      _errorMessage = e.message;
      notifyListeners();
      return;
    }
    if (file == null) return; // cancelled

    _ssmUploading = true;
    _errorMessage = null;
    _ssmExtract = null; // a fresh upload supersedes any previous verdict
    _ssmCheckTimedOut = false;
    notifyListeners();
    try {
      // Persist the typed number BEFORE the bytes land. The extract trigger
      // fires the instant they do and reads the number from Firestore, so
      // without this the server compares the document against an empty string
      // and the mismatch check silently never fires. Non-fatal on failure:
      // the upload still proceeds, the server just cannot cross-check.
      try {
        await _repository.save(_loadedUid!, data);
      } catch (_) {
        // Deliberately swallowed - see above.
      }
      data.ssmDocumentUrl =
          await _storage.uploadSsmDocument(uid: _loadedUid!, file: file);
      // The verdict arrives on the watch opened in loadFor. Give it a bounded
      // wait so a failed or cold-started function degrades to a message rather
      // than to a spinner that never stops.
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

  /// Uploads the optional Business Profile.
  ///
  /// Unlike the Certificate this file is never kept: the server reads it,
  /// records whether the registered owner matches the account holder, takes the
  /// business facts a Certificate cannot supply, and deletes it. The owner's
  /// name never reaches this client - only the comparison result, which arrives
  /// on the same watch as the rest of the verdict.
  Future<void> pickSsmProfile() async {
    final XFile? file;
    try {
      file = await _pdfPicker();
    } on DocumentPickException catch (e) {
      _errorMessage = e.message;
      notifyListeners();
      return;
    }
    if (file == null) return; // cancelled

    _ssmProfileUploading = true;
    _errorMessage = null;
    notifyListeners();
    try {
      await _storage.uploadSsmProfile(uid: _loadedUid!, file: file);
    } catch (_) {
      _errorMessage = 'Could not upload the profile. Please try again.';
    } finally {
      _ssmProfileUploading = false;
      notifyListeners();
    }
  }

  /// Copies the server's proposals into the form. Called only when the
  /// applicant taps "Use these details" - autofill is always their action,
  /// never something that happens to them.
  void applySsmExtract() {
    final extract = _ssmExtract;
    if (extract == null) return;
    final name = extract.businessName;
    if (name != null && name.isNotEmpty) data.businessName = name;
    final number = extract.registrationNumber;
    if (number != null && number.isNotEmpty) setSsmNumber(number);
    notifyListeners();
  }

  /// Keeps [OnboardingData.ssmNumberNormalized] in step with the typed number,
  /// so the canonical form is never stale.
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

  /// Removes the image from local state and best-effort deletes it from
  /// Storage (failures are ignored - the file may already be gone).
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

  @override
  void dispose() {
    _extractTimeout?.cancel();
    _extractSub?.cancel();
    super.dispose();
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
