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

  /// Maximum time the user is allowed to spend unlocking before the screen
  /// gives up and returns to the lock screen (which then shows
  /// PIN/fingerprint). Prevents the detect/retry loop from hanging forever.
  static const Duration authTimeout = Duration(seconds: 15);

  /// Pause after any failed detection/match before the auth scan resumes
  /// (~2 s). Gives the user a beat to re-center, keeps the loop from hammering
  /// the camera, and visibly reads as "Try again" — then re-detection starts
  /// automatically.
  static const Duration authRetryInterval = Duration(seconds: 2);

  /// After this many CONSECUTIVE ML/pipeline errors (ML Kit throwing, model
  /// inference failing, storage errors), auth stops retrying and surfaces a
  /// hard "camera error — use PIN/fingerprint" state. A single transient
  /// stumble should never end the session; a genuine ML failure should never
  /// spin the loop forever. Reset to 0 on every truly processed frame.
  static const int maxConsecutiveMlErrors = 3;

  /// After this many consecutive failed unlock attempts the camera locks out.
  static const int maxAuthAttempts = 5;

  /// Brief pause after [maxAuthAttempts] failures before the camera resumes
  /// scanning. The user can fall back to fingerprint or PIN while it runs.
  /// Kept short (~2 s) so retry after a bad scan feels immediate; the
  /// PIN/fingerprint fallback remains instant, so a legitimate user is never
  /// locked out.
  static const Duration authCooldown = Duration(seconds: 2);

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
  // 5-step liveness (lightweight, NOT bank-grade)
  // -------------------------------------------------------------------------

  /// Liveness is required to UNLOCK, never during enrollment.
  static const bool requireLivenessForUnlock = true;

  /// Blink is counted when the mean eye-open probability (0..1 from ML Kit)
  /// transitions open → closed → open again across accepted faces.
  static const double blinkOpenBoundary = 0.5;
  static const double blinkClosedBoundary = 0.25;

  /// After a blink is counted, this long must elapse before another blink
  /// can be counted, so a single blink can never satisfy two liveness steps.
  static const Duration blinkCooldown = Duration(milliseconds: 700);

  /// Head-turn steps: yaw must deviate at least this far from center...
  static const double headTurnDegrees = 8.0;

  /// ...and hold there for this many consecutive accepted faces before the
  /// step advances. Sustaining the pose kills single-frame noise and rules
  /// out a face that disappears and reappears between sightings.
  static const int headTurnStableFrames = 3;

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