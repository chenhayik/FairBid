import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';

/// Largest SSM document accepted; equals the Storage rule's cap so the user gets a clear message.
const ssmDocumentMaxBytes = 10 * 1024 * 1024;

/// What:   Thrown when a picked file is unusable.
/// Input:  Raised by [pickSsmPdf].
/// Output: [message] is safe to show verbatim.
class DocumentPickException implements Exception {
  const DocumentPickException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// What:   Opens the system picker for an SSM PDF.
/// Input:  User's choice; throws [DocumentPickException] on a non-PDF, oversize or unreadable file.
/// Output: An XFile with the bytes untouched, or null if cancelled.
/// Notes:  Never re-encoded (it would break the digital signature). The XFile is built by hand
///         because `PlatformFile.xFile` carries no mime type and the upload would tag it image/jpeg.
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

  // Cloud pickers (Drive) report wrong mime types, so don't trust the filter.
  if (picked.extension?.toLowerCase() != 'pdf') {
    throw const DocumentPickException('Please choose a PDF file.');
  }
  // Before any read: the uploader reads all bytes, so a huge file would exhaust memory.
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
