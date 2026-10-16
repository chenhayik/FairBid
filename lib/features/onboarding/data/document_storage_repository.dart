import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';

/// What:   Storage upload API returning download URLs.
/// Input:  Firebase Storage via FirebaseDocumentStorageRepository; a fake in tests.
/// Output: URLs; verification docs are owner-only, job photos and avatars readable by signed-in users.
abstract interface class DocumentStorageRepository {
  /// Uploads a verification file; [purpose] becomes the file-name prefix (`ssm_document` and `ssm_profile` are matched by `extractSsmDocument`).
  Future<String> uploadVerificationImage({
    required String uid,
    required String purpose,
    required XFile file,
  });

  /// Uploads a profile photo under `avatars/{uid}/`, readable by signed-in users.
  Future<String> uploadAvatar({
    required String uid,
    required XFile file,
  });

  /// Uploads a job photo under `jobs/{uid}/`.
  Future<String> uploadJobPhoto({
    required String uid,
    required XFile file,
  });

  /// Uploads dispute evidence under owner+admin-only `disputes/{uid}/`.
  Future<String> uploadDisputeEvidence({
    required String uid,
    required XFile file,
  });

  /// Deletes an uploaded file by URL.
  Future<void> deleteByUrl(String url);
}

/// What:   Firebase Storage [DocumentStorageRepository].
/// Input:  XFile from the pickers.
/// Output: Upload with a 60s timeout; returns the download URL.
class FirebaseDocumentStorageRepository implements DocumentStorageRepository {
  FirebaseDocumentStorageRepository({FirebaseStorage? storage})
      : _storage = storage ?? FirebaseStorage.instance;

  final FirebaseStorage _storage;

  /// Fail instead of hanging on a stalled upload.
  static const _uploadTimeout = Duration(seconds: 60);

  @override
  Future<String> uploadVerificationImage({
    required String uid,
    required String purpose,
    required XFile file,
  }) =>
      _upload('verification/$uid/${purpose}_', file);

  @override
  Future<String> uploadAvatar({
    required String uid,
    required XFile file,
  }) {
    return _upload(
      'avatars/$uid/',
      file,
      contentType: file.mimeType ?? 'image/jpeg',
    );
  }

  @override
  Future<String> uploadJobPhoto({
    required String uid,
    required XFile file,
  }) =>
      _upload('jobs/$uid/', file);

  @override
  Future<String> uploadDisputeEvidence({
    required String uid,
    required XFile file,
  }) =>
      _upload('disputes/$uid/', file);

  @override
  Future<void> deleteByUrl(String url) => _storage.refFromURL(url).delete();

  /// What:   Uploads a file to Storage.
  /// Input:  [prefix] path; [file]; optional [contentType] override and [timeout].
  /// Output: The download URL; the file is stored at `[prefix]<timestamp><ext>`.
  Future<String> _upload(
    String prefix,
    XFile file, {
    String? contentType,
    Duration? timeout,
  }) async {
    final effectiveTimeout = timeout ?? _uploadTimeout;
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final ref = _storage.ref('$prefix$timestamp${_extensionOf(file.name)}');
    final bytes = await file.readAsBytes();
    await ref
        .putData(
          bytes,
          SettableMetadata(contentType: _contentTypeFor(contentType, file)),
        )
        .timeout(effectiveTimeout);
    return ref.getDownloadURL().timeout(effectiveTimeout);
  }

  /// What:   The mime type to upload with.
  /// Input:  [override] and the [file].
  /// Output: The override, else the file's mime type, else guessed from the extension.
  /// Notes:  file_picker gives no mime type on mobile.
  String _contentTypeFor(String? override, XFile file) {
    if (override != null) return override;
    final mime = file.mimeType;
    if (mime != null && mime.isNotEmpty) return mime;
    return switch (_extensionOf(file.name).toLowerCase()) {
      '.pdf' => 'application/pdf',
      '.png' => 'image/png',
      '.heic' || '.heif' => 'image/heic',
      _ => 'image/jpeg',
    };
  }

  String _extensionOf(String fileName) {
    final dot = fileName.lastIndexOf('.');
    return dot == -1 ? '.jpg' : fileName.substring(dot);
  }
}
