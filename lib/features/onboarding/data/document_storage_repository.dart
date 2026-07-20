import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';

/// Uploads images and returns their public download URLs. Verification docs go
/// under owner-only `verification/{uid}/...`; job photos go under
/// `jobs/{uid}/...` (readable by any signed-in user) — see `storage.rules`.
abstract interface class DocumentStorageRepository {
  /// Uploads a verification image (ID, selfie, certificate, portfolio).
  /// [purpose] becomes part of the file name.
  Future<String> uploadVerificationImage({
    required String uid,
    required String purpose,
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

  /// Fail (rather than spin forever) if an upload stalls. Uploads that hang
  /// happen on flaky networks and, notably, on Android emulators whose network
  /// stack stalls Storage's resumable-upload protocol.
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

  /// Uploads [file] at [pathWithoutExt] (the extension is taken from the file)
  /// and returns its download URL.
  Future<String> _upload(String pathWithoutExt, XFile file) async {
    final ref = _storage.ref('$pathWithoutExt${_extensionOf(file.name)}');
    final bytes = await file.readAsBytes();
    await ref
        .putData(
          bytes,
          SettableMetadata(contentType: file.mimeType ?? 'image/jpeg'),
        )
        .timeout(_uploadTimeout);
    return ref.getDownloadURL().timeout(_uploadTimeout);
  }

  String _extensionOf(String fileName) {
    final dot = fileName.lastIndexOf('.');
    return dot == -1 ? '.jpg' : fileName.substring(dot);
  }
}
