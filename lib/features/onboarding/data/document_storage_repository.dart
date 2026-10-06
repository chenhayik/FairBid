import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';

/// Uploads images and returns their download URLs. Verification docs are
/// owner-only; job photos and avatars are readable by signed-in users.
abstract interface class DocumentStorageRepository {
  /// Uploads a verification image (ID, selfie, certificate, portfolio).
  /// [purpose] becomes part of the file name.
  Future<String> uploadVerificationImage({
    required String uid,
    required String purpose,
    required XFile file,
  });

  /// Uploads an SSM document exactly as picked (re-encoding breaks its seal).
  /// Keep the `ssm_document_` prefix; `extractSsmDocument` matches on it.
  Future<String> uploadSsmDocument({
    required String uid,
    required XFile file,
  });

  /// Uploads the optional SSM Business Profile. The server reads it once, then
  /// deletes it because it holds an NRIC, birth date and home address.
  Future<String> uploadSsmProfile({
    required String uid,
    required XFile file,
  });

  /// Uploads a profile photo under `avatars/{uid}/`. Signed-in users can read
  /// (see `storage.rules`) because it shows on bids, jobs, chats and reviews.
  Future<String> uploadAvatar({
    required String uid,
    required XFile file,
  });

  /// Uploads a job photo under `jobs/{uid}/`.
  Future<String> uploadJobPhoto({
    required String uid,
    required XFile file,
  });

  /// Uploads dispute photo evidence under owner+admin-only `disputes/{uid}/`.
  Future<String> uploadDisputeEvidence({
    required String uid,
    required XFile file,
  });

  /// Best-effort delete of a previously uploaded file (failures are non-fatal).
  Future<void> deleteByUrl(String url);
}

/// Firebase Storage implementation.
class FirebaseDocumentStorageRepository implements DocumentStorageRepository {
  FirebaseDocumentStorageRepository({FirebaseStorage? storage})
      : _storage = storage ?? FirebaseStorage.instance;

  final FirebaseStorage _storage;

  /// Fail instead of waiting forever if an upload stalls (flaky networks,
  /// Android emulators).
  static const _uploadTimeout = Duration(seconds: 60);

  @override
  Future<String> uploadVerificationImage({
    required String uid,
    required String purpose,
    required XFile file,
  }) {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    return _upload('verification/$uid/${purpose}_$timestamp', file);
  }

  @override
  Future<String> uploadSsmDocument({
    required String uid,
    required XFile file,
  }) {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    return _upload('verification/$uid/ssm_document_$timestamp', file);
  }

  @override
  Future<String> uploadSsmProfile({
    required String uid,
    required XFile file,
  }) {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    return _upload('verification/$uid/ssm_profile_$timestamp', file);
  }

  @override
  Future<String> uploadAvatar({
    required String uid,
    required XFile file,
  }) {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    return _upload(
      'avatars/$uid/$timestamp',
      file,
      contentType: file.mimeType ?? 'image/jpeg',
    );
  }

  @override
  Future<String> uploadJobPhoto({
    required String uid,
    required XFile file,
  }) {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    return _upload('jobs/$uid/$timestamp', file);
  }

  @override
  Future<String> uploadDisputeEvidence({
    required String uid,
    required XFile file,
  }) {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    return _upload('disputes/$uid/$timestamp', file);
  }

  @override
  Future<void> deleteByUrl(String url) => _storage.refFromURL(url).delete();

  /// Uploads [file] at [pathWithoutExt] and returns its download URL.
  /// [contentType] overrides the mime type; [timeout] the default time limit.
  Future<String> _upload(
    String pathWithoutExt,
    XFile file, {
    String? contentType,
    Duration? timeout,
  }) async {
    final effectiveTimeout = timeout ?? _uploadTimeout;
    final ref = _storage.ref('$pathWithoutExt${_extensionOf(file.name)}');
    final bytes = await file.readAsBytes();
    await ref
        .putData(
          bytes,
          SettableMetadata(contentType: _contentTypeFor(contentType, file)),
        )
        .timeout(effectiveTimeout);
    return ref.getDownloadURL().timeout(effectiveTimeout);
  }

  /// Content type: the override, else the file's mime type, else its extension.
  /// file_picker gives no mimeType on Android/iOS, so the extension matters.
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
