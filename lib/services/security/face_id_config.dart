import 'package:flutter/foundation.dart';

/// Central tuning surface for on-device Face ID. Every security-sensitive
/// constant lives here so behavior stays consistent across the enrollment and
/// authentication pipelines and entry points (settings, lock screen).
///
/// The similarity threshold is intentionally NOT exposed in the UI — it is a
/// safety/error-rate knob, not a user preference.
abstract final class FaceIdConfig {
  // -------------------------------------------------------------------------
  // Model
  // -------------------------------------------------------------------------

  /// Primary asset key for the bundled MobileFaceNet TFLite model.
  static const String modelAssetPath = 'assets/models/mobilefacenet.tflite';

  /// Fallback keys tried if the primary path fails to load (older tflite
  /// plugin / asset bundling edge cases).
  static const List<String> modelAssetFallbacks = [
    'models/mobilefacenet.tflite',
    'mobilefacenet.tflite',
  ];

  /// Model expects square RGB input of this side length.
  static const int modelInputSize = 112;

  /// Output embedding dimensionality (verified against the bundled .tflite).
  static const int embeddingSize = 192;

  /// Worker threads hint for the TFLite interpreter.
  static const int interpreterThreads = 2;

  // -------------------------------------------------------------------------
  // Matching
  // -------------------------------------------------------------------------

  /// Minimum cosine similarity required to treat a probe embedding as a match.
  ///
  /// HARDENED FROM 0.75. [FaceMatchingService.bestMatch] takes the MAX score
  /// across every enrolled pose, and a max over 6-8 comparisons is far more
  /// permissive than a single 1:1 comparison — 0.75 with max-over-poses left a
  /// meaningful false-accept window for a look-alike. 0.85 is a conservative
  /// 1:1 operating point for eye-aligned 112x112 MobileFaceNet embeddings:
  /// genuine probes sit well above it, impostors well below.
  ///
  /// Requires re-enrollment to take effect (the template is unchanged, but
  /// every existing probe is now scored against the stricter gate).
  static const double similarityThreshold = 0.85;

  // -------------------------------------------------------------------------
  // Enrollment
  // -------------------------------------------------------------------------

  /// Samples to collect before enrollment is considered complete.
  static const int minEnrollSamples = 6;

  /// Upper bound on samples kept in the stored template.
  static const int maxStoredSamples = 8;

  /// Two consecutive enrollment samples this similar (cosine) are treated as
  /// the same pose — the user is asked to change head position instead.
  static const double duplicatePoseThreshold = 0.99;

  /// Pause between auto-captured enrollment samples.
  static const Duration enrollSampleGap = Duration(milliseconds: 1300);

  /// Away-from-camera guidance for collecting varied poses.
  static const List<String> enrollTipRotation = [
    'Hold still',
    'Turn slightly to the left',
    'Turn slightly to the right',
    'Tilt your head a little up',
    'Tilt your head a little down',
  ];

  // -------------------------------------------------------------------------
  // Authentication
  // -------------------------------------------------------------------------

  /// Pause between attempted captures during unlock. Intentionally short —
  /// the single-flight loop drops stale frames, so this only paces how
  /// quickly the next attempt starts after the previous one finishes.
  static const Duration authCaptureGap = Duration(milliseconds: 200);

  /// After this many consecutive failed unlock attempts the camera locks out.
  static const int maxAuthAttempts = 5;

  /// Cooldown shown after [maxAuthAttempts] failures. The user can fall back
  /// to fingerprint or PIN while the cooldown runs.
  ///
  /// HARDENED FROM 6 s. A camera-based gate that reopens every 6 seconds allows
  /// an unattended phone to be probed roughly ten times a minute; 30 s cuts
  /// that to two while leaving the PIN/fingerprint fallback instant, so a
  /// legitimate user is never locked out.
  static const Duration authCooldown = Duration(seconds: 30);

  // -------------------------------------------------------------------------
  // Capture quality gates (reject junk before it reaches the model)
  // -------------------------------------------------------------------------

  /// A face must occupy at least this fraction of the image's shortest side,
  /// otherwise the probe is too blurry/far to embed reliably.
  static const double faceMinSizeFraction = 0.22;

  /// ML Kit head pose limits (degrees). Faces beyond these are rejected as
  /// turned away / off-axis.
  static const double maxHeadPitchDegrees = 20; // headEulerAngleX
  static const double maxHeadYawDegrees = 25; // headEulerAngleY
  static const double maxHeadRollDegrees = 20; // headEulerAngleZ

  /// Face center must stay within this fraction of image width/height from
  /// the center (keeps the subject in the oval guide).
  static const double offCenterToleranceFraction = 0.45;

  // -------------------------------------------------------------------------
  // Alignment (before embedding)
  // -------------------------------------------------------------------------

  static const double eyeDistanceMultiplier = 2.6;

  // -------------------------------------------------------------------------
  // Liveness (lightweight, NOT bank-grade)
  // -------------------------------------------------------------------------

  /// Blink detected when the mean eye-open probability drops across this
  /// threshold (0..1 from ML Kit).
  static const double blinkOpenBoundary = 0.5;
  static const double blinkClosedBoundary = 0.25;

  /// Fallback liveness: this much head-yaw variation (degrees) across
  /// consecutive frames counts as movement when eye probabilities are absent.
  static const double fallbackMovementDegrees = 4.0;
  static const int fallbackMovementFrames = 3;

  /// Liveness is required to UNLOCK, never during enrollment.
  static const bool requireLivenessForUnlock = true;

  // -------------------------------------------------------------------------
  // Platform
  // -------------------------------------------------------------------------

  /// Face ID needs camera + ML + FFI runtimes — mobile only.
  static bool get isSupportedPlatform {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }
}