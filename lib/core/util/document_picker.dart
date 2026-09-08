import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';

/// Largest SSM document we accept. Kept equal to the Storage rule's cap so an
/// oversized file is refused here, with a message the user can act on, rather
/// than by the server with an opaque permission error.
const ssmDocumentMaxBytes = 10 * 1024 * 1024;

/// Thrown when a pick is unusable. [message] is safe to show verbatim.
class DocumentPickException implements Exception {
  const DocumentPickException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Opens the system document picker for a PDF. Returns null if cancelled.
///
/// The bytes are never re-encoded. An SSM Digitally Certified True Copy carries
/// a digital signature that any re-save destroys, and `image_picker` - which
/// every other upload in this app uses - always re-encodes: on Android
/// whenever `maxWidth`/`imageQuality` is set, and on iOS unconditionally.
///
/// The [XFile] is built by hand rather than taken from `PlatformFile.xFile`,
/// because on Android and iOS `cross_file`'s dart:io constructor ignores its
/// `name` argument and never infers a mime type. `PlatformFile.xFile` passes no
/// mime type at all, so the result would have `mimeType == null` and the
/// uploader would fall back to tagging an SSM PDF as `image/jpeg`.
Future<XFile?> pickSsmPdf() async {
  final PlatformFile? picked;
  try {
    picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
    );
  } catch (_) {
    throw const DocumentPickException('Could not open the file picker.');
  }
  if (picked == null) return null; // cancelled

  // Cloud providers (Drive, some OEM pickers) report a missing or wrong mime
  // type, so the picker's own filter is not something to rely on.
  if (picked.extension?.toLowerCase() != 'pdf') {
    throw const DocumentPickException('Please choose a PDF file.');
  }
  // Checked before any read: the uploader calls readAsBytes() unconditionally,
  // so an oversized file would exhaust memory before Storage ever saw it.
  if (await picked.length() > ssmDocumentMaxBytes) {
    throw const DocumentPickException(
        'That file is larger than 10 MB. Please upload a smaller PDF.');
  }
  final path = picked.path;
  if (path == null) {
    throw const DocumentPickException('Could not read that file.');
  }
  return XFile(path, mimeType: 'application/pdf', name: picked.name);
}
