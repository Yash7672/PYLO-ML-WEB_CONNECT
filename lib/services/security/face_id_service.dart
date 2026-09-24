import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
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
  final Face? face; // detected face for liveness tracking
  final Float32List? embedding; // model output, 192-d

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

  const FaceProcessingResult.ok(this.face, this.embedding)
      : success = true,
        failReason = null;
}

/// Verdict of the shared capture quality gates. Anything other than
/// [FaceQuality.ok] explains why the frame must not progress.
///
/// Both the cheap unlock-loop detection ([FaceIdService.detectStill]) and the
/// full pipeline ([FaceIdService.processCapture]) apply these via
/// [FaceIdService.classifyFace], so enrollment and authentication treat the
/// exact same photo identically.
enum FaceQuality {
  ok,
  noFace,
  multipleFaces,
  tooSmall,
  badPose,
  offCenter,
  noEyes,
  error,
}

/// Result of one cheap per-frame detection (the liveness loop). Carries the
/// ML Kit [Face] for the liveness machine plus the upright image dimensions
/// that [FaceIdService.classifyFace] used to gate it.
class FaceDetectOutcome {
  final FaceQuality quality;

  /// The single detected face — present only when [quality] == [FaceQuality.ok].
  final Face? face;

  /// Upright (EXIF-baked) capture dimensions, used by the quality gates.
  final int uprightWidth;
  final int uprightHeight;

  /// Human-readable hint shown when a frame fails a gate (null otherwise).
  final String? message;

  const FaceDetectOutcome({
    required this.quality,
    this.face,
    this.uprightWidth = 0,
    this.uprightHeight = 0,
    this.message,
  });

  bool get ok => quality == FaceQuality.ok;
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
    const sidePx = FaceIdConfig.modelInputSize;
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
      final raw = await detectorService.detectFromImageRaw(inputImage);
      debugPrint('PyloFaceTiming detect=${sw.elapsedMilliseconds}ms');

      // An ML Kit exception must NEVER look like "nobody in frame" — it is a
      // hard camera/analyzer failure the caller can treat as fatal.
      if (raw.threw) {
        return const FaceProcessingResult
            .failure('Camera error — use fingerprint or PIN');
      }
      final faces = raw.faces;

      if (faces.isEmpty) {
        return const FaceProcessingResult.noFace();
      }
      if (faces.length > 1) {
        return const FaceProcessingResult.multipleFaces();
      }
      final face = faces.first;

      // Shared gate — identical to what the unlock loop's cheap detection
      // applies, so enrollment, unlock gating and final verification all use
      // the same acceptance criteria.
      final quality = classifyFace(face, upright.width, upright.height);
      const failReasons = {
        FaceQuality.tooSmall: 'Move closer to the camera',
        FaceQuality.badPose: 'Look at the camera',
        FaceQuality.offCenter: 'Position your face inside the frame',
        FaceQuality.noEyes: 'Keep your face straight',
      };
      if (quality != FaceQuality.ok) {
        return FaceProcessingResult.failure(
            failReasons[quality] ?? 'Try again');
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
  // Shared quality gates
  // -------------------------------------------------------------------------

  /// Applies the capture quality gates used by BOTH enrollment samples and the
  /// final unlock verification, so the two pipelines treat the same photo
  /// identically. Coordinates are in ML Kit's upright space (the JPEG's EXIF
  /// orientation, which [processCapture] and [detectStill] both bake first).
  static FaceQuality classifyFace(
      Face face, int uprightWidth, int uprightHeight) {
    final shortestSide =
        math.min(uprightWidth, uprightHeight).toDouble();
    final faceShort =
        math.min(face.boundingBox.width, face.boundingBox.height);
    if (faceShort < shortestSide * FaceIdConfig.faceMinSizeFraction) {
      return FaceQuality.tooSmall;
    }

    final pitch = face.headEulerAngleX ?? 0.0;
    final yaw   = face.headEulerAngleY ?? 0.0;
    final roll  = face.headEulerAngleZ ?? 0.0;
    if (pitch.abs() > FaceIdConfig.maxHeadPitchDegrees ||
        yaw.abs() > FaceIdConfig.maxHeadYawDegrees ||
        roll.abs() > FaceIdConfig.maxHeadRollDegrees) {
      return FaceQuality.badPose;
    }

    final w = uprightWidth.toDouble();
    final h = uprightHeight.toDouble();
    final cx = face.boundingBox.center.dx / (w / 2) - 1;
    final cy = face.boundingBox.center.dy / (h / 2) - 1;
    if (cx.abs() > FaceIdConfig.offCenterToleranceFraction ||
        cy.abs() > FaceIdConfig.offCenterToleranceFraction) {
      return FaceQuality.offCenter;
    }

    final leftEye  = face.landmarks[FaceLandmarkType.leftEye]?.position;
    final rightEye = face.landmarks[FaceLandmarkType.rightEye]?.position;
    if (leftEye == null || rightEye == null) {
      return FaceQuality.noEyes;
    }

    return FaceQuality.ok;
  }

  /// Cheap per-frame detection used by the unlock loop to feed the liveness
  /// machine WITHOUT paying the alignment/embedding cost. Reads the JPEG,
  /// runs ML Kit detection (EXIF already honored by the framework), and
  /// applies [classifyFace] — the same gates as [processCapture].
  ///
  /// The temp capture file is deleted before returning.
  static Future<FaceDetectOutcome> detectStill({
    required String jpegPath,
    required FaceDetectionService detectorService,
  }) async {
    try {
      final bytes = await File(jpegPath).readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) {
        return const FaceDetectOutcome(
            quality: FaceQuality.error, message: 'Could not read the image');
      }
      final upright = img.bakeOrientation(decoded);
      final exifOrientation = _readExifOrientation(bytes);
      final inputImage = InputImage.fromFilePath(jpegPath);
      final raw = await detectorService.detectFromImageRaw(inputImage);
      final faces = raw.faces;
      if (raw.threw) {
        // Never silently turn an ML Kit exception into "no face" — surfacing
        // it as an error lets the unlock loop stop retrying and fall back to
        // PIN/fingerprint instead of looping forever.
        if (kDebugMode) {
          debugPrint('FaceDebug: detector threw: ${raw.error}');
        }
        return const FaceDetectOutcome(
          quality: FaceQuality.error,
          message: 'Camera error — use fingerprint or PIN',
        );
      }
      if (faces.isEmpty) {
        if (kDebugMode) {
          debugPrint('FaceDebug: camera_image=${upright.width}x${upright.height} '
              'exif=$exifOrientation faces=0');
        }
        return const FaceDetectOutcome(quality: FaceQuality.noFace);
      }
      if (faces.length > 1) {
        if (kDebugMode) {
          debugPrint('FaceDebug: camera_image=${upright.width}x${upright.height} '
              'exif=$exifOrientation faces=${faces.length} quality=multiple');
        }
        return const FaceDetectOutcome(quality: FaceQuality.multipleFaces);
      }
      final face = faces.first;
      final quality = classifyFace(face, upright.width, upright.height);
      if (kDebugMode) {
        debugPrint('FaceDebug: camera_image=${upright.width}x${upright.height} '
            'exif=$exifOrientation faces=1 bbox=${face.boundingBox} '
            'yaw=${face.headEulerAngleY ?? 'null'} '
            'leftEye=${face.leftEyeOpenProbability?.toStringAsFixed(2) ?? 'null'} '
            'rightEye=${face.rightEyeOpenProbability?.toStringAsFixed(2) ?? 'null'} '
            'landmarks=${face.landmarks.length} quality=$quality');
      }
      return FaceDetectOutcome(
        quality: quality,
        face: face,
        uprightWidth: upright.width,
        uprightHeight: upright.height,
        message: switch (quality) {
          FaceQuality.tooSmall => 'Move closer to the camera',
          FaceQuality.badPose => 'Look at the camera',
          FaceQuality.offCenter => 'Move your face inside the oval',
          FaceQuality.noEyes => 'Keep your face straight',
          _ => null,
        },
      );
    } catch (e) {
      debugPrint('Per-frame detection failed: $e');
      return const FaceDetectOutcome(
          quality: FaceQuality.error, message: 'Internal error');
    } finally {
      // Privacy: best-effort clean up the temp capture file.
      try { await File(jpegPath).delete(); } catch (_) {}
    }
  }

  /// Reads the JPEG EXIF orientation tag (1..8) used by the debug logs to
  /// confirm ML Kit's image orientation matches the decoded pixels. Returns
  /// -1 when no EXIF is present or unparseable.
  static int _readExifOrientation(Uint8List bytes) {
    try {
      final exif = img.decodeJpgExif(bytes);
      if (exif == null) return -1;
      return exif.getTag(0x0112)?.toInt() ?? -1; // Orientation
    } catch (_) {
      return -1;
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

  /// Process-wide cache of the front camera descriptor. Startup availability
  /// checks populate it, so pressing Face ID starts the camera WITHOUT
  /// re-enumerating the device (a real cost on Android) — keeping the
  /// press→first-face path on camera setup as small as possible.
  static CameraDescription? _cachedCamera;

  /// Resolves the front camera (falling back to the first available camera).
  /// Uses the cached descriptor when present; pass `refresh: true` to force a
  /// re-enumeration. Never throws.
  static Future<CameraDescription?> pickFrontCamera(
      {bool refresh = false}) async {
    if (!FaceIdConfig.isSupportedPlatform) return null;
    if (!refresh && _cachedCamera != null) return _cachedCamera;
    try {
      final cameras = await availableCameras();
      _cachedCamera = cameras.isEmpty
          ? null
          : cameras.firstWhere(
              (c) => c.lensDirection == CameraLensDirection.front,
              orElse: () => cameras.first,
            );
      return _cachedCamera;
    } catch (e) {
      debugPrint('Camera enumeration failed: $e');
      _cachedCamera = null;
      return null;
    }
  }

  /// Drops the cached descriptor (e.g. after a failed init) so the next
  /// attempt re-enumerates instead of retrying a known-bad device entry.
  static void invalidateCameraCache() {
    _cachedCamera = null;
  }

  /// Returns true when the device has a camera the app can plausibly use
  /// for Face ID (without prompting the user for permission yet).
  static Future<bool> isCameraAvailable() async {
    return (await pickFrontCamera()) != null;
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
      return await matchAgainstStoredTemplate(result.embedding!);
    } catch (e) {
      debugPrint('Capture-and-score failed: $e');
      return null;
    }
  }
}