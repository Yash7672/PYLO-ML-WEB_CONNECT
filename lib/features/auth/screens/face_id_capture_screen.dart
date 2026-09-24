import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../services/security/face_detection_service.dart';
import '../../../services/security/face_embedding_service.dart';
import '../../../services/security/face_id_config.dart';
import '../../../services/security/face_id_service.dart';
import '../../../services/security/face_matching_service.dart';
import '../../../services/security/face_template_store.dart';
import '../../../theme/app_theme.dart';
import '../widgets/face_id_camera_alignment.dart';

enum FaceIdCaptureMode { enroll, authenticate }

class FaceIdCaptureScreen extends StatefulWidget {
  final FaceIdCaptureMode mode;

  const FaceIdCaptureScreen({super.key, required this.mode});

  @override
  State<FaceIdCaptureScreen> createState() => _FaceIdCaptureScreenState();
}

class _FaceIdCaptureScreenState extends State<FaceIdCaptureScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  final FaceDetectionService _detector = FaceDetectionService();
  final List<Float32List> _enrollSamples = [];

  // Camera state (kept separate from processing state so the preview stays
  // stable while ML runs).
  bool _initializing = true;
  String? _cameraError;
  bool _cameraPermissionDenied = false;

  // ML / processing state.
  bool _processingFrame = false;
  bool _finished = false;
  bool _disposed = false;

  // Auth/enroll status text, shown in the badge. Updated directly (no streak
  // debounce) because auth feedback changes slowly: Detecting → Try again.
  String _statusMessage = 'Preparing Face ID...';

  int _failStreak = 0;
  DateTime? _cooldownUntil;
  Timer? _cooldownTicker;

  /// Single-flight guard for [_initCamera]: initState starts the camera and a
  /// lifecycle-resume (or a "Try again" tap) can land while the first init is
  /// still awaiting `availableCameras()`/`initialize()`. Without this guard two
  /// controllers would be created (duplicate camera init) and the survivor
  /// race is unpredictable.
  bool _cameraInitInFlight = false;

  /// Auth-only: when this timestamp passes, the screen gives up and pops back
  /// to the lock screen (PIN/fingerprint fallback) instead of hanging on the
  /// "Verifying face..." retries. Re-armed on resume so background time never
  /// counts against the user.
  DateTime? _authDeadline;

  /// Consecutive ML/pipeline errors (ML Kit throws, inference/storage
  /// failures). Crosses [FaceIdConfig.maxConsecutiveMlErrors] → the retry loop
  /// stops and auth shows the hard fallback message. Reset to 0 on any
  /// genuinely processed frame.
  int _mlErrorStreak = 0;
  bool _fatalError = false;

  // Session timing + single-flight bookkeeping.
  final Stopwatch _screenSw = Stopwatch()..start();
  bool _firstFrameLogged = false;
  bool _firstGoodFaceLogged = false;
  bool _loopRunning = false;

  /// Auth-only: brief pause after a failed detection/match before scanning
  /// resumes (~2 s). Distinct from the post-lockout [_cooldownUntil].
  DateTime? _retryUntil;
  Timer? _retryTicker;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Constructs the ML Kit detector synchronously (first line of [_warmMl])
    // and warms the interpreter in the background. The detection loop does NOT
    // wait on this future — the interpreter is only needed for the final
    // embedding, and it lazy-loads (sharing the startup pre-warm) inside the
    // verified phase if necessary.
    unawaited(_warmMl());
    _initCamera();
    if (widget.mode == FaceIdCaptureMode.authenticate) {
      _authDeadline = DateTime.now().add(FaceIdConfig.authTimeout);
    }
  }

  /// Preloads the ML runtime off the critical path while the camera spins
  /// up, so the first capture doesn't pay the interpreter-load cost. Never
  /// throws: a failure only means the first attempts retry as usual.
  Future<void> _warmMl() async {
    if (!FaceIdConfig.isSupportedPlatform) return;
    try {
      _detector.detector; // construct the detector once
      await FaceEmbeddingService.loadContract();
    } catch (e) {
      debugPrint('Face ID ML warm-up failed (will retry): $e');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _finished = true;
    WidgetsBinding.instance.removeObserver(this);
    _cooldownTicker?.cancel();
    _cooldownTicker = null;
    _retryTicker?.cancel();
    _retryTicker = null;
    // Idempotent teardown: every controller/detector is released exactly once.
    final camera = _controller;
    _controller = null;
    try {
      camera?.dispose();
    } catch (_) {}
    try {
      _detector.dispose();
    } catch (_) {}
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _releaseCamera();
    } else if (state == AppLifecycleState.resumed) {
      // Time spent backgrounded must not eat the user's auth window.
      if (widget.mode == FaceIdCaptureMode.authenticate) {
        _authDeadline = DateTime.now().add(FaceIdConfig.authTimeout);
      }
      _initCamera();
    }
  }

  /// Drops the camera controller immediately (lifecycle pause). The ML Kit
  /// detector is intentionally kept alive so a resume re-inits only the
  /// camera, not the whole ML stack.
  void _releaseCamera() {
    final camera = _controller;
    _controller = null;
    if (camera == null) return;
    try {
      camera.dispose();
    } catch (_) {}
  }

  // -----------------------------------------------------------------------
  // Camera init
  // -----------------------------------------------------------------------

  Future<void> _initCamera() async {
    if (_disposed || _finished) return;
    // Don't double-init while already trying.
    final existing = _controller;
    if (existing != null && existing.value.isInitialized) return;
    // Single-flight: a lifecycle-resume or a "Try again" tap arriving while
    // this init is still awaiting must not create a SECOND controller.
    if (_cameraInitInFlight) return;
    _cameraInitInFlight = true;
    try {
      if (!mounted) return;
      setState(() {
        _initializing = true;
        _cameraError = null;
        _cameraPermissionDenied = false;
      });

      // Cached descriptor: the startup availability check already enumerated
      // the cameras and cached the front one, so this is instant on the
      // press→first-face path. Only a failed/recovered attempt re-enumerates.
      final cam = await FaceIdService.pickFrontCamera();
      if (cam == null) {
        // Don't keep a stale descriptor around — the next attempt (manual
        // "Try again") must re-enumerate rather than spin on a bad device.
        FaceIdService.invalidateCameraCache();
        if (!mounted) return;
        setState(() {
          _initializing = false;
          _cameraError = 'No camera available';
          _statusMessage = 'Could not access a camera';
        });
        return;
      }

      // Medium resolution: the previous low preset (~320×240) was too small for
      // reliable ML Kit face detection with landmarks + classification, which
      // made unlock report "no face" on many devices. Medium still keeps the
      // capture/decode/inference cycle fast for a 112×112 probe.
      final controller =
          CameraController(cam, ResolutionPreset.medium, enableAudio: false);

      try {
        await controller.initialize();
      } on CameraException catch (e) {
        if (!mounted || _disposed) {
          controller.dispose();
          return;
        }
        final denied = e.description?.toLowerCase().contains('denied') == true;
        setState(() {
          _initializing = false;
          _cameraPermissionDenied = denied;
          _cameraError = denied
              ? 'Camera permission is required for Face ID.'
              : 'Could not start the camera';
          _statusMessage = denied
              ? 'Allow camera access in your phone\'s settings, then come back'
              : 'Camera error';
        });
        if (!denied) FaceIdService.invalidateCameraCache();
        controller.dispose();
        return;
      }

      if (!mounted || _finished || _disposed) {
        controller.dispose();
        return;
      }
      _controller = controller;
      if (kDebugMode) {
        debugPrint('FaceDebug: camera=${cam.name} lens=${cam.lensDirection} '
            'sensorOrientation=${cam.sensorOrientation} '
            'res=${controller.value.previewSize}');
      }
      debugPrint(
          'FaceID: camera init = ${_screenSw.elapsedMilliseconds}ms');
      // The auth window starts once the camera is usable, not while the
      // camera was still spinning up (or waiting on a permission screen).
      if (widget.mode == FaceIdCaptureMode.authenticate) {
        _authDeadline = DateTime.now().add(FaceIdConfig.authTimeout);
      }
      setState(() {
        _initializing = false;
        if (widget.mode == FaceIdCaptureMode.enroll) {
          _statusMessage = 'Hold still and look at the camera';
        } else {
          _statusMessage = 'Detecting face...';
        }
      });
      _startAutoCapture();
    } finally {
      _cameraInitInFlight = false;
    }
  }

  // -----------------------------------------------------------------------
  // Auto-capture loop — one frame at a time, drop frames while busy
  // -----------------------------------------------------------------------

  Future<void> _startAutoCapture() async {
    if (_loopRunning) return;
    if (_disposed || _finished) return;
    _loopRunning = true;
    try {
      // Deliberately NOT awaiting the TFLite model warm-up: detection only
      // needs the ML Kit detector (already constructed synchronously in
      // initState), and only the verified pipeline touches the model — which
      // lazy-loads/shared-loads the warmed interpreter. The camera preview
      // and continuous detection start the moment the camera is ready.
      while (!_finished && !_disposed) {
        if (_fatalError) break;

        // Auth timeout: give up and return to the lock screen (PIN/fingerprint
        // fallback) rather than hang on a stuck verify/cooldown cycle.
        if (widget.mode == FaceIdCaptureMode.authenticate &&
            _authDeadline != null &&
            DateTime.now().isAfter(_authDeadline!)) {
          if (kDebugMode) {
            debugPrint(
                'PyloFaceTiming unlock_timeout total=${_screenSw.elapsedMilliseconds}ms');
          }
          _finish(false);
          return;
        }

        final controller = _controller;
        if (controller == null || !controller.value.isInitialized) {
          await Future.delayed(const Duration(milliseconds: 50));
          continue;
        }
        if (widget.mode == FaceIdCaptureMode.authenticate &&
            (_retryUntil != null || _cooldownUntil != null)) {
          await Future.delayed(const Duration(milliseconds: 250));
          continue;
        }
        // Single-flight: never queue a second capture while one is in
        // flight. Skip == drop stale frames; the latest frame wins.
        if (_processingFrame || controller.value.isTakingPicture) {
          await Future.delayed(const Duration(milliseconds: 40));
          continue;
        }
        // Capture immediately, then pace the next attempt between cycles.
        await _attemptCapture();
        await Future.delayed(
          widget.mode == FaceIdCaptureMode.enroll
              ? FaceIdConfig.enrollSampleGap
              : FaceIdConfig.authCaptureGap,
        );
      }
    } finally {
      _loopRunning = false;
    }
  }

  Future<void> _attemptCapture() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.isTakingPicture) return;
    if (_processingFrame) return;

    _processingFrame = true;
    try {
      if (widget.mode == FaceIdCaptureMode.enroll) {
        final processing = await _runCapturePipeline(controller);
        if (_finished || !mounted || processing == null) return;
        await _handleEnrollResult(processing);
      } else {
        await _attemptCaptureAuth(controller);
      }
    } finally {
      _processingFrame = false;
    }
  }

  /// Runs the full ML pipeline on a single capture. Used by enrollment, which
  /// collects varied-pose samples; auth reuses the same gates + alignment +
  /// embedding via [_attemptCaptureAuth].
  Future<FaceProcessingResult?> _runCapturePipeline(
      CameraController controller) async {
    final sw = Stopwatch()..start();
    try {
      final file = await controller.takePicture();
      if (!_firstFrameLogged) {
        _firstFrameLogged = true;
        debugPrint(
            'PyloFaceTiming first_frame=${_screenSw.elapsedMilliseconds}ms');
      }
      final result = await FaceIdService.processCapture(
        jpegPath: file.path,
        detectorService: _detector,
      );
      debugPrint('PyloFaceTiming cycle=${sw.elapsedMilliseconds}ms');
      return result;
    } catch (e) {
      debugPrint('Face capture pipeline failed: $e');
      return null;
    }
  }

  // -----------------------------------------------------------------------
  // Authentication
  // -----------------------------------------------------------------------

  /// Unlock loop, one capture per tick: run the FULL pipeline (same quality
  /// gates + alignment + embedding as enrollment) on every frame. As soon as
  /// an acceptable face is present, the probe is embedded and scored against
  /// the stored template — unlock on a match. No blink/head-turn state
  /// machine: continuous detection → verify → unlock (or "Try again").
  Future<void> _attemptCaptureAuth(CameraController controller) async {
    final sw = Stopwatch()..start();
    try {
      final file = await controller.takePicture();
      if (_disposed || _finished || !mounted) return;
      if (!_firstFrameLogged) {
        _firstFrameLogged = true;
        debugPrint(
            'PyloFaceTiming first_frame=${_screenSw.elapsedMilliseconds}ms');
      }

      final result = await FaceIdService.processCapture(
        jpegPath: file.path,
        detectorService: _detector,
      );
      debugPrint('PyloFaceTiming pipeline=${sw.elapsedMilliseconds}ms');
      if (_disposed || _finished || !mounted) return;

      if (!result.success || result.embedding == null) {
        if (_isPipelineFailure(result.failReason)) {
          // ML Kit threw or inference failed: this is NOT "no face". After a
          // few consecutive errors stop retrying and fall back.
          _bumpMlError();
          if (_fatalError) return;
          _scheduleRetry('Camera error — use fingerprint or PIN');
          return;
        }
        // Face absent or the quality gates rejected it: pause ~2 s, then the
        // loop automatically resumes scanning.
        _mlErrorStreak = 0;
        _scheduleRetry('Try again');
        return;
      }

      // A usable face is on screen — log first face once, then embed + match.
      if (!_firstGoodFaceLogged && kDebugMode) {
        _firstGoodFaceLogged = true;
        debugPrint('FaceID: first face = ${_screenSw.elapsedMilliseconds}ms');
      }
      debugPrint('FaceID: embedding = ${_screenSw.elapsedMilliseconds}ms');
      _mlErrorStreak = 0;

      final match = await FaceIdService.matchAgainstStoredTemplate(
          result.embedding!);
      debugPrint('PyloFaceTiming match=${sw.elapsedMilliseconds}ms');
      // Score on every failed unlock (debug builds) so a "Face ID keeps
      // saying no match" report can be diagnosed from a log line.
      if (!match.matched && kDebugMode) {
        debugPrint(
            'PyloFaceTiming auth score=${match.score.toStringAsFixed(3)} '
            '(threshold ${FaceIdConfig.similarityThreshold})');
      }
      if (_disposed || _finished || !mounted) return;

      if (match.matched) {
        if (kDebugMode) {
          debugPrint('FaceID: total = ${_screenSw.elapsedMilliseconds}ms');
        }
        _finish(true);
        return;
      }

      // Only a genuine identity mismatch counts as a failed attempt.
      _failStreak++;
      _scheduleCooldown();
      if (_cooldownUntil == null) {
        _scheduleRetry('Face not recognized. Try again.');
      }
    } catch (e) {
      debugPrint('Face auth capture failed: $e');
      _bumpMlError();
      if (_fatalError) return;
      _scheduleRetry('Camera error — use fingerprint or PIN');
    }
  }

  /// True when a full-pipeline [FaceProcessingResult.failReason] reflects an
  /// ML/storage failure (retrying is futile) rather than a transient quality
  /// gate (retrying is the intended behavior).
  bool _isPipelineFailure(String? reason) {
    if (reason == null) return false;
    return reason == 'Model inference failed' ||
        reason == 'Internal error' ||
        reason.contains('Camera error');
  }

  /// Registers one ML/pipeline error; once the consecutive-error ceiling is
  /// hit the retry loop stops and the fallback message is shown.
  void _bumpMlError() {
    _mlErrorStreak++;
    if (_mlErrorStreak >= FaceIdConfig.maxConsecutiveMlErrors) {
      if (kDebugMode) {
        debugPrint(
            'PyloFaceTiming fatal_ml_error streak=$_mlErrorStreak '
            'total=${_screenSw.elapsedMilliseconds}ms');
      }
      _fatalError = true;
      if (mounted) {
        setState(
            () => _statusMessage = 'Camera error — use fingerprint or PIN');
      }
    }
  }

  // -----------------------------------------------------------------------
  // Enrollment
  // -----------------------------------------------------------------------

  Future<void> _handleEnrollResult(FaceProcessingResult result) async {
    if (!mounted) return;
    if (!result.success || result.embedding == null) {
      setState(() => _statusMessage = result.failReason ?? 'Try again');
      return;
    }

    final embedding = result.embedding!;

    final existingScores = <double>[
      for (final s in _enrollSamples)
        FaceMatchingService.cosineSimilarity(embedding, s),
    ];
    final nearDupe =
        existingScores.any((s) => s >= FaceIdConfig.duplicatePoseThreshold);

    if (nearDupe) {
      setState(() => _statusMessage = 'Too similar — turn your head slightly');
      return;
    }

    _enrollSamples.add(embedding);
    final count = _enrollSamples.length;
    final tip =
        FaceIdConfig.enrollTipRotation[count % FaceIdConfig.enrollTipRotation.length];

    setState(() {
      _statusMessage = 'Captured $count/${FaceIdConfig.minEnrollSamples} — $tip';
    });

    if (count >= FaceIdConfig.minEnrollSamples) {
      final capped =
          _enrollSamples.sublist(0, count.clamp(0, FaceIdConfig.maxStoredSamples));
      try {
        await FaceTemplateStore.save(
          FaceTemplate(
            version: 1,
            enrolledAt: DateTime.now(),
            embeddings: capped,
          ),
        );
      } catch (e) {
        if (!mounted) return;
        debugPrint('Face template save failed: $e');
        setState(() => _statusMessage = 'Could not save — try again');
        return;
      }
      _finish(true);
    }
  }

  void _scheduleCooldown() {
    if (!mounted) return;
    if (_failStreak < FaceIdConfig.maxAuthAttempts) return;
    if (_cooldownUntil != null) return;
    _cooldownUntil = DateTime.now().add(FaceIdConfig.authCooldown);
    setState(() => _statusMessage = 'Too many attempts — use fingerprint or PIN');
    _cooldownTicker?.cancel();
    _cooldownTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_cooldownUntil == null || DateTime.now().isAfter(_cooldownUntil!)) {
        _cooldownTicker?.cancel();
        _cooldownTicker = null;
        _cooldownUntil = null;
        _failStreak = 0;
        if (mounted) {
          setState(() => _statusMessage = 'Detecting face...');
        }
      } else if (mounted) {
        final sec = _cooldownUntil!.difference(DateTime.now()).inSeconds + 1;
        setState(() => _statusMessage = 'Try again in $sec s');
      }
    });
  }

  /// Pauses the auth scan for ~2 s, shows [message] ("Try again"), then
  /// automatically resumes detecting. Retrying continues until a match, the
  /// auth timeout, a fatal ML error, or the user picking fingerprint/PIN.
  void _scheduleRetry(String message) {
    if (_fatalError || !mounted || _finished || _disposed) return;
    if (_retryUntil != null) return;
    _retryUntil = DateTime.now().add(FaceIdConfig.authRetryInterval);
    setState(() => _statusMessage = message);
    _retryTicker?.cancel();
    _retryTicker = Timer(FaceIdConfig.authRetryInterval, () {
      _retryUntil = null;
      _retryTicker = null;
      if (!_finished && !_disposed && mounted && _cooldownUntil == null) {
        setState(() => _statusMessage = 'Detecting face...');
      }
    });
  }

  // -----------------------------------------------------------------------
  // Finish
  // -----------------------------------------------------------------------

  void _finish(bool success) {
    if (_finished) return;
    _finished = true;
    _cooldownTicker?.cancel();
    _cooldownTicker = null;
    if (!mounted) return;
    Navigator.of(context).pop(success);
  }

  // -----------------------------------------------------------------------
  // Build
  // -----------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final camera = _controller;
    final showPreview = camera != null && !_initializing;
    final isEnroll = widget.mode == FaceIdCaptureMode.enroll;
    // Liveness dots are gone from unlock — auth is continuous detection →
    // verify → unlock. Enrollment keeps its sample-progress dots.
    final dotCount = isEnroll ? FaceIdConfig.minEnrollSamples : 0;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Camera area — outer alignment oval + oval camera preview. The
            // geometry is owned entirely by [FaceIdCameraAlignment].
            if (showPreview)
              Positioned.fill(
                child: FaceIdCameraAlignment(camera: camera),
              ),

            // Loading spinner while the camera initializes.
            if (_initializing)
              const Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),

            // Camera permission recovery (all modes, but mainly unlock).
            if (_cameraPermissionDenied)
              Positioned.fill(
                child: Container(
                  color: Colors.black,
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
const Icon(Icons.no_photography_outlined,
                          color: Colors.white54, size: 48),
                      const SizedBox(height: 16),
                      const Text(
                        'Camera permission is required for Face ID.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: Colors.white, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'If the prompt did not appear, enable it manually:\n'
                        'Settings → Apps → PYLO → Permissions → Camera → Allow',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: Colors.white60,
                            fontSize: 13,
                            height: 1.4),
                      ),
                      const SizedBox(height: 20),
                      TextButton(
                        onPressed: () => _initCamera(),
                        child: const Text('Try again'),
                      ),
                    ],
                  ),
                ),
              ),

            // Status badge.
            Positioned(
              left: 24,
              right: 24,
              bottom: MediaQuery.of(context).size.height * 0.18,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  _cameraError ?? _statusMessage,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    fontFamily: theme.textTheme.bodyMedium?.fontFamily,
                  ),
                ),
              ),
            ),

            // Progress dots — enrollment only now (top, 6 dots, one per captured
            // sample). Auth is continuous detection → verify → unlock and
            // shows no liveness dots.
            Positioned(
              top: isEnroll ? 16 : null,
              bottom: isEnroll ? null : MediaQuery.of(context).size.height * 0.18 + 54,
              left: 0,
              right: 0,
              child: showPreview
                  ? Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(dotCount, (i) {
                        final filled = i < _enrollSamples.length;
                        return AnimatedContainer(
                          duration: const Duration(milliseconds: 250),
                          margin: const EdgeInsets.symmetric(horizontal: 5),
                          width: filled ? 12 : 8,
                          height: filled ? 12 : 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: filled
                                ? (PyloGlass.isActive(context)
                                    ? GlassColors.accent
                                    : theme.colorScheme.primary)
                                : Colors.white24,
                          ),
                        );
                      }),
                    )
                  : const SizedBox.shrink(),
            ),

            // Fallback button (auth only). Always visible during auth — even
            // when the camera failed to start — so the user can always drop
            // back to PIN / fingerprint instead of being stuck on a black
            // screen with no exit besides the back arrow.
            if (!isEnroll)
              Positioned(
                left: 24,
                right: 24,
                bottom: MediaQuery.of(context).size.height * 0.06,
                child: Center(
                  child: TextButton.icon(
                    onPressed: () => _finish(false),
                    icon:
                        const Icon(Icons.fingerprint, color: Colors.white70),
                    label: const Text(
                      'Use fingerprint or PIN instead',
                      style: TextStyle(color: Colors.white70),
                    ),
                  ),
                ),
              ),

            // Back / cancel.
            Positioned(
              top: 8,
              left: 8,
              child: IconButton(
                onPressed: () => _finish(false),
                icon: const Icon(Icons.arrow_back_ios_new,
                    color: Colors.white70),
              ),
            ),
          ],
        ),
      ),
    );
  }
}