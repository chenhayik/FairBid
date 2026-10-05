import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import '../domain/face_box.dart';

export '../domain/face_box.dart';

enum FaceCheckKind { idCard, selfie }

/// [problem] is a message for the applicant, or null when the photo is fine.
/// [box] is the largest face, when one was found.
class FaceCheckResult {
  const FaceCheckResult({this.problem, this.box});

  final String? problem;
  final FaceBox? box;
}

/// On-device capture quality gate for ID and selfie photos.
abstract interface class FaceChecker {
  Future<FaceCheckResult> check(String filePath, FaceCheckKind kind);
}

/// ML Kit implementation. Never blocks the applicant if ML Kit itself fails.
class MlKitFaceChecker implements FaceChecker {
  const MlKitFaceChecker();

  static const _noCardFace = "We couldn't find the photo on your card. Retake "
      'it flat, in good light, with the whole card in frame.';
  static const _eyes = 'Keep your eyes open and look at the camera.';
  static const _straight = 'Face the camera straight on.';

  @override
  Future<FaceCheckResult> check(String filePath, FaceCheckKind kind) async {
    final detector = FaceDetector(
      options: FaceDetectorOptions(
        enableClassification: true,
        performanceMode: FaceDetectorMode.accurate,
      ),
    );
    try {
      final faces =
          await detector.processImage(InputImage.fromFilePath(filePath));
      if (faces.isEmpty) {
        return FaceCheckResult(
            problem: kind == FaceCheckKind.idCard
                ? _noCardFace
                : 'We could not see your face. Retake it in good light.');
      }
      // The card also carries a small ghost photo, and a selfie shows the
      // card, so several faces are normal: judge the largest.
      final face = faces.reduce((a, b) => _area(a) >= _area(b) ? a : b);
      if (kind == FaceCheckKind.selfie) {
        final eyes = [face.leftEyeOpenProbability, face.rightEyeOpenProbability]
            .whereType<double>();
        if (eyes.any((p) => p < 0.4)) return const FaceCheckResult(problem: _eyes);
        if ((face.headEulerAngleY ?? 0).abs() > 30) {
          return const FaceCheckResult(problem: _straight);
        }
      }
      return FaceCheckResult(box: await _box(filePath, face));
    } catch (e) {
      debugPrint('Face check failed, not blocking: $e');
      return const FaceCheckResult();
    } finally {
      await detector.close();
    }
  }

  static double _area(Face f) => f.boundingBox.width * f.boundingBox.height;

  /// ML Kit reports pixels of the EXIF-upright image; Flutter's decoder also
  /// applies EXIF, so dividing by the decoded size gives fractions.
  static Future<FaceBox> _box(String path, Face face) async {
    final codec = await ui.instantiateImageCodec(await File(path).readAsBytes());
    final image = (await codec.getNextFrame()).image;
    final w = image.width.toDouble(), h = image.height.toDouble();
    image.dispose();
    codec.dispose();
    final r = face.boundingBox;
    final left = (r.left / w).clamp(0.0, 1.0);
    final top = (r.top / h).clamp(0.0, 1.0);
    return FaceBox(
      left: left,
      top: top,
      width: math.min(r.width / w, 1 - left),
      height: math.min(r.height / h, 1 - top),
      aspect: w / h,
    );
  }
}
