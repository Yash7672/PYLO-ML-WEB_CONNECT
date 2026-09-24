import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

/// Raw result of one ML Kit detection call: the faces that were found (which
/// is legitimately empty when nobody is in frame) plus any exception the
/// detector threw.
///
/// The production pipeline treats a thrown exception as "no face" (fail
/// closed), but the debug diagnostic surfaces [error] so a silent "0 faces"
/// caused by an ML Kit failure is never mistaken for "nobody in frame".
class FaceDetectionRawResult {
  final List<Face> faces;
  final Object? error;

  const FaceDetectionRawResult({this.faces = const [], this.error});

  bool get threw => error != null;
}

/// Thin wrapper around the ML Kit face detector.
///
/// IMPORTANT: ML Kit only finds faces — a detection is NEVER treated as a
/// successful unlock. Identity comes from the MobileFaceNet embedding +
/// cosine threshold in [FaceMatchingService], and liveness from
/// [FaceIdLivenessFlow].
class FaceDetectionService {
  FaceDetector? _detector;

  /// The detector instance for this service (created lazily).
  ///
  /// Tuned for speed:
  ///  * [FaceDetectorMode.fast] — skips the expensive accurate-mode face
  ///    alignment/contour pipeline.
  ///  * [enableLandmarks] stays ON because eye landmarks drive face
  ///    alignment for the MobileFaceNet probe, head-pose gating, and the
  ///    head-motion liveness fallback.
  ///  * [enableClassification] is ON because the blink-based liveness signal
  ///    (eye-open probabilities) is a PRIMARY liveness step in
  ///    [FaceIdLivenessFlow] during unlock. Disabling it silently deletes
  ///    that signal and leaves head-turns as the only path, blocking every
  ///    unlock for a user who keeps their head still.
  FaceDetector get detector =>
      _detector ??= FaceDetector(
        options: FaceDetectorOptions(
          performanceMode: FaceDetectorMode.fast,
          enableLandmarks: true,
          enableClassification: true,
        ),
      );

  Future<List<Face>> detectFromImage(InputImage image) async {
    final raw = await detectFromImageRaw(image);
    return raw.faces;
  }

  /// Like [detectFromImage] but never hides what ML Kit actually did — the
  /// caller gets both the returned faces and any thrown exception. Used by the
  /// debug-only face-detection diagnostic and the production loop (which
  /// reads only [FaceDetectionRawResult.faces]).
  Future<FaceDetectionRawResult> detectFromImageRaw(InputImage image) async {
    try {
      return FaceDetectionRawResult(faces: await detector.processImage(image));
    } catch (e) {
      // Fail closed (don't crash the unlock loop) but never swallow the real
      // error silently: an exception that becomes "no face" misleads the
      // camera → image → ML Kit diagnosis.
      debugPrint('FaceDebug: ML Kit processImage threw: $e');
      return FaceDetectionRawResult(error: e);
    }
  }

  /// Releases the native detector. Call from the screen's dispose.
  Future<void> dispose() async {
    try {
      await _detector?.close();
    } catch (e) {
      debugPrint('Face detector close failed: $e');
    }
    _detector = null;
  }
}