import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_commons/google_mlkit_commons.dart'
    show InputImage;
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;

import 'face_detection_service.dart';
import 'face_embedding_service.dart';
import 'face_id_config.dart';
import 'face_matching_service.dart';
import 'face_template_store.dart';

/// Outcome returned by the lock-screen or settings-screen flow after one
/// capture attempt is fully processed (quality checks, alignment, inference).
class FaceProcessingResult {
  final bool success;
  final String? failReason;
  final Face? face; // for liveness tracking
  final Float32List? embedding; // model output, 192-d

  const FaceProcessingResult._({
    required this.success,
    this.failReason,
    this.face,
    this.embedding,
  });

  const FaceProcessingResult.noFace()
      : success = false,
        failReason = 'No face detected',
        face = null,
        embedding = null;

  const FaceProcessingResult.multipleFaces()
      : success = false,
        failReason = 'Only one face should be visible',
        face = null,
        embedding = null;

  const FaceProcessingResult.failure(String reason)
      : success = false,
        failReason = reason,
        face = null,
        embedding = null;

  const FaceProcessingResult.ok(Face face, Float32List embedding)
      : success = true,
        failReason = null,
        face = face,
        embedding = embedding;
}

// ---------------------------------------------------------------------------
// Isolate work (top-level so compute() can reach it)
// ---------------------------------------------------------------------------

/// Message passed into the isolate for face alignment. The image travels as
/// raw RGB bytes (no PNG encode/decode round-trip) plus its dimensions.
class _AlignFaceRequest {
  final Uint8List rgbBytes; // upright RGB row-major bytes
  final int leftEyeX, leftEyeY;
  final int rightEyeX, rightEyeY;
  final int imageWidth, imageHeight;

  const _AlignFaceRequest({
    required this.rgbBytes,
    required this.leftEyeX,
    required this.leftEyeY,
    required this.rightEyeX,
    required this.rightEyeY,
    required this.imageWidth,
    required this.imageHeight,
  });
}

/// Runs in a background isolate: builds the upright image from raw RGB
/// bytes, rotates, crops, resizes and normalizes a face probe into the
/// [112×112×3] pixel array the model expects.  Returns null on any failure.
Float32List? _alignAndNormalize(_AlignFaceRequest req) {
  try {
    final decoded = img.Image.fromBytes(
      width: req.imageWidth,
      height: req.imageHeight,
      bytes: req.rgbBytes.buffer,
      numChannels: 3,
    );

    final eyeDist = math.max(
      1,
      math.sqrt(
        math.pow(req.leftEyeX - req.rightEyeX, 2) +
            math.pow(req.leftEyeY - req.rightEyeY, 2),
      ).round(),
    );

    // Direction from one eye to the other, normalized to point toward the
    // image right (+x).  Without this, a mirrored camera feed flips the
    // sign and `atan2` yields an angle offset by ~180°.
    var ex = req.leftEyeX - req.rightEyeX;
    var ey = req.leftEyeY - req.rightEyeY;
    if (ex < 0) {
      ex = -ex;
      ey = -ey;
    }
    final angle = math.atan2(ey, ex);

    // Rotate so the eye baseline becomes horizontal.
    final rotated = img.copyRotate(decoded, angle: -angle * 180 / math.pi);

    // Transform the eye midpoint under the same rotation. The image package
    // rotates with dest = R(-angle)·src, R(θ) = [cosθ, -sinθ; sinθ, cosθ]
    // around the center, so the midpoint must use θ = -angle:
    //   rx = cx + dx·cos(angle) + dy·sin(angle)
    //   ry = cy - dx·sin(angle) + dy·cos(angle)
    final cx = req.imageWidth / 2.0;
    final cy = req.imageHeight / 2.0;
    final mx = (req.leftEyeX + req.rightEyeX) / 2.0;
    final my = (req.leftEyeY + req.rightEyeY) / 2.0;
    final dx = mx - cx;
    final dy = my - cy;
    final cosA = math.cos(angle);
    final sinA = math.sin(angle);
    final rx = cx + dx * cosA + dy * sinA;
    final ry = cy - dx * sinA + dy * cosA;

    final side = (eyeDist * FaceIdConfig.eyeDistanceMultiplier).round();
    final rW = rotated.width;
    final rH = rotated.height;

    // Square crop rectangle, clamped to image bounds, then padded with black.
    final cropL = rx - side / 2;
    final cropT = ry - side / 2;
    final ix = math.max(0, cropL.round());
    final iy = math.max(0, cropT.round());
    final ix2 = math.min(rW, (cropL + side).round());
    final iy2 = math.min(rH, (cropT + side).round());
    final iw = ix2 - ix;
    final ih = iy2 - iy;
    if (iw <= 0 || ih <= 0) return null;

    final out = img.Image(width: side, height: side);
    img.fill(out, color: img.ColorRgb8(0, 0, 0));
    final src = img.copyCrop(rotated, x: ix, y: iy, width: iw, height: ih);
    img.compositeImage(
      out,
      src,
      dstX: (ix - cropL).round(),
      dstY: (iy - cropT).round(),
    );

    final resized = img.copyResize(
      out,
      width: FaceIdConfig.modelInputSize,
      height: FaceIdConfig.modelInputSize,
      interpolation: img.Interpolation.linear,
    );

    // Extract RGB bytes and normalize to [-1, 1].
    final sidePx = FaceIdConfig.modelInputSize;
    final outPixels = Float32List(sidePx * sidePx * 3);
    for (var y = 0; y < sidePx; y++) {
      for (var x = 0; x < sidePx; x++) {
        final px = resized.getPixel(x, y);
        final i = (y * sidePx + x) * 3;
        outPixels[i] = (px.r.toDouble() - 128.0) / 128.0;
        outPixels[i + 1] = (px.g.toDouble() - 128.0) / 128.0;
        outPixels[i + 2] = (px.b.toDouble() - 128.0) / 128.0;
      }
    }
    return outPixels;
  } catch (e) {
    debugPrint('Align isolate failed: $e');
    return null;
  }
}

// ---------------------------------------------------------------------------
// FaceIdService — static facade
// ---------------------------------------------------------------------------

class FaceIdService {
  FaceIdService._();

  // -------------------------------------------------------------------------
  // Single-frame pipeline (one capture → one possible result)
  // -------------------------------------------------------------------------

  /// Processes one JPEG captured by the camera controller:
  ///  quality gate  →  alignment isolate  →  embedding inference.
  ///
  /// Returns a [FaceProcessingResult] the caller inspects for:
  ///  - `failReason` (status text + liveness feed)
  ///  - `embedding` (to match or enroll)
  ///  - `face` (for liveness tracker)
  static Future<FaceProcessingResult> processCapture({
    required String jpegPath,
    required FaceDetectionService detectorService,
  }) async {
    final sw = Stopwatch()..start();
    try {
      final bytes = await File(jpegPath).readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) {
        return const FaceProcessingResult
            .failure('Could not read the image');
      }

      // ML Kit (InputImage.fromFilePath) honors EXIF and reports face
      // coordinates in the upright space. Bake the EXIF orientation into the
      // pixels so our decoded image is in that same space (safe no-op when
      // the decoder already applied it).
      final upright = img.bakeOrientation(decoded);

      final inputImage = InputImage.fromFilePath(jpegPath);
      final faces = await detectorService.detectFromImage(inputImage);
      debugPrint('PyloFaceTiming detect=${sw.elapsedMilliseconds}ms');

      if (faces.isEmpty) {
        return const FaceProcessingResult.noFace();
      }
      if (faces.length > 1) {
        return const FaceProcessingResult.multipleFaces();
      }
      final face = faces.first;

      final shortestSide =
          math.min(upright.width, upright.height).toDouble();
      final faceShort =
          math.min(face.boundingBox.width, face.boundingBox.height);
      if (faceShort < shortestSide * FaceIdConfig.faceMinSizeFraction) {
        return const FaceProcessingResult
            .failure('Move closer to the camera');
      }

      final pitch = face.headEulerAngleX ?? 0.0;
      final yaw   = face.headEulerAngleY ?? 0.0;
      final roll  = face.headEulerAngleZ ?? 0.0;
      if (pitch.abs() > FaceIdConfig.maxHeadPitchDegrees ||
          yaw.abs() > FaceIdConfig.maxHeadYawDegrees ||
          roll.abs() > FaceIdConfig.maxHeadRollDegrees) {
        return const FaceProcessingResult
            .failure('Look at the camera');
      }

      final w = upright.width.toDouble();
      final h = upright.height.toDouble();
      final cx = face.boundingBox.center.dx / (w / 2) - 1;
      final cy = face.boundingBox.center.dy / (h / 2) - 1;
      if (cx.abs() > FaceIdConfig.offCenterToleranceFraction ||
          cy.abs() > FaceIdConfig.offCenterToleranceFraction) {
        return const FaceProcessingResult
            .failure('Position your face inside the frame');
      }

      final leftEye  = face.landmarks[FaceLandmarkType.leftEye]?.position;
      final rightEye = face.landmarks[FaceLandmarkType.rightEye]?.position;
      if (leftEye == null || rightEye == null) {
        return const FaceProcessingResult
            .failure('Keep your face straight');
      }

      // Send raw RGB bytes to the isolate — avoids encoding+decoding PNG.
      final aligned = await compute(
        _alignAndNormalize,
        _AlignFaceRequest(
          rgbBytes: upright.getBytes(order: img.ChannelOrder.rgb),
          leftEyeX: leftEye.x,
          leftEyeY: leftEye.y,
          rightEyeX: rightEye.x,
          rightEyeY: rightEye.y,
          imageWidth: upright.width,
          imageHeight: upright.height,
        ),
      );
      debugPrint('PyloFaceTiming align=${sw.elapsedMilliseconds}ms');
      if (aligned == null) {
        return const FaceProcessingResult.failure('Could not align face');
      }

      final embedding = await FaceEmbeddingService.embedPixels(aligned);
      debugPrint('PyloFaceTiming embed=${sw.elapsedMilliseconds}ms');
      if (embedding == null) {
        return const FaceProcessingResult
            .failure('Model inference failed');
      }

      return FaceProcessingResult.ok(face, embedding);
    } catch (e) {
      debugPrint('Capture processing failed unexpectedly: $e');
      return const FaceProcessingResult.failure('Internal error');
    } finally {
      // Privacy: best-effort clean up the temp capture file.
      try { await File(jpegPath).delete(); } catch (_) {}
      debugPrint('PyloFaceTiming pipeline_total=${sw.elapsedMilliseconds}ms');
    }
  }

  // -------------------------------------------------------------------------
  // Enrollment helpers
  // -------------------------------------------------------------------------

  /// Adds a single enrollment sample to a growing list and persists when
  /// the sample count reaches [FaceIdConfig.minEnrollSamples].  Returns a
  /// status string the screen should display (e.g. "3/6 captured").
  static Future<String> addEnrollmentSample({
    required Float32List embedding,
    required List<Float32List> samples,
  }) async {
    // Reject near-duplicate poses.
    for (final existing in samples) {
      if (FaceMatchingService.cosineSimilarity(embedding, existing) >=
          FaceIdConfig.duplicatePoseThreshold) {
        return 'Too similar — move your head slightly';
      }
    }
    samples.add(embedding);
    final count = samples.length;
    if (count >= FaceIdConfig.minEnrollSamples) {
      final capped =
          samples.sublist(0, math.min(count, FaceIdConfig.maxStoredSamples));
      await FaceTemplateStore.save(
        FaceTemplate(
          version: 1,
          enrolledAt: DateTime.now(),
          embeddings: capped,
        ),
      );
      return 'Enrolled $count samples';
    }
    final remaining = FaceIdConfig.minEnrollSamples - count;
    return '$count/${FaceIdConfig.minEnrollSamples} captured '
        '— turn your head $remaining more';
  }

  // -------------------------------------------------------------------------
  // Authentication helpers
  // -------------------------------------------------------------------------

  /// Scores a single probe against the stored template.  Returns a result
  /// the screen can compare to [FaceIdConfig.similarityThreshold] and route.
  static Future<FaceMatchResult> matchAgainstStoredTemplate(
      Float32List probe) async {
    final template = await FaceTemplateStore.load();
    if (template == null) {
      return const FaceMatchResult.noMatch();
    }
    return FaceMatchingService.bestMatch(probe, template);
  }

  // -------------------------------------------------------------------------
  // Camera availability
  // -------------------------------------------------------------------------

  /// Returns true when the device has a camera the app can plausibly use
  /// for Face ID (without prompting the user for permission yet).
  static Future<bool> isCameraAvailable() async {
    if (!FaceIdConfig.isSupportedPlatform) return false;
    try {
      final cameras = await availableCameras();
      return cameras.isNotEmpty;
    } catch (e) {
      debugPrint('Camera availability check failed: $e');
      return false;
    }
  }

  // -------------------------------------------------------------------------
  // Convenience: end-to-end verify (used by lock screen)
  // -------------------------------------------------------------------------

  /// Captures, processes and scores in one call.
  /// Returns `null` on transient failure, or a [FaceMatchResult] on success.
  static Future<FaceMatchResult?> captureAndScore({
    required CameraController controller,
    required FaceDetectionService detectorService,
  }) async {
    if (!controller.value.isInitialized) return null;
    if (controller.value.isTakingPicture) return null;
    try {
      final file = await controller.takePicture();
      final result = await processCapture(
        jpegPath: file.path,
        detectorService: detectorService,
      );
      if (!result.success || result.embedding == null) {
        return null;
      }
      return matchAgainstStoredTemplate(result.embedding!);
    } catch (e) {
      debugPrint('Capture-and-score failed: $e');
      return null;
    }
  }
}