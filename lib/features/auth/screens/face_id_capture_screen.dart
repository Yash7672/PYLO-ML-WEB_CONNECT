import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../../../services/security/face_detection_service.dart';
import '../../../services/security/face_embedding_service.dart';
import '../../../services/security/face_id_config.dart';
import '../../../services/security/face_id_service.dart';
import '../../../services/security/face_liveness_checker.dart';
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
  final FaceLivenessTracker _livenessTracker = FaceLivenessTracker();
  final List<Float32List> _enrollSamples = [];

  // Camera state (kept separate from processing state so the preview stays
  // stable while ML runs).
  bool _initializing = true;
  String? _cameraError;

  // ML / processing state.
  bool _processingFrame = false;
  bool _finished = false;
  String _statusMessage = 'Initializing camera...';

  int _failStreak = 0;
  DateTime? _cooldownUntil;
  Timer? _cooldownTicker;

  // Session timing + single-flight bookkeeping.
  final Stopwatch _screenSw = Stopwatch()..start();
  bool _firstFrameLogged = false;
  bool _loopRunning = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _warmMl();
    _initCamera();
  }

  /// Preloads the ML runtime off the critical path while the camera spins
  /// up, so the first capture doesn't pay the interpreter-load cost.
  Future<void> _warmMl() async {
    if (!FaceIdConfig.isSupportedPlatform) return;
    _detector.detector; // construct the detector once
    await FaceEmbeddingService.loadContract();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _finished = true;
    _cooldownTicker?.cancel();
    _detector.dispose();
    _controller?.dispose();
    _controller = null;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      // Release the camera + detector while backgrounded. Frames stop with
      // the controller so nothing is processed in the background.
      _controller?.dispose();
      _controller = null;
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  // -----------------------------------------------------------------------
  // Camera init
  // -----------------------------------------------------------------------

  Future<void> _initCamera() async {
    if (_finished) return;
    // Don't double-init while already trying.
    if (_controller != null && _controller!.value.isInitialized) return;
    setState(() {
      _initializing = true;
      _cameraError = null;
    });

    CameraDescription? cam;
    try {
      final cameras = await availableCameras();
      cam = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _initializing = false;
        _cameraError = 'No camera available';
        _statusMessage = 'Could not access a camera';
      });
      return;
    }

    // Low resolution is plenty: the face fills the oval, ML Kit detects at
    // this size, and the 112×112 probe doesn't need 4K. The smaller frames
    // make capture + decode + inference much faster with no accuracy loss.
    final controller =
        CameraController(cam, ResolutionPreset.low, enableAudio: false);

    try {
      await controller.initialize();
    } on CameraException catch (e) {
      if (!mounted) {
        controller.dispose();
        return;
      }
      final denied = e.description?.toLowerCase().contains('denied') == true;
      setState(() {
        _initializing = false;
        _cameraError =
            denied ? 'Camera permission denied' : 'Could not start the camera';
        _statusMessage = denied
            ? 'Allow camera access in your phone\'s settings, then come back'
            : 'Camera error';
      });
      controller.dispose();
      return;
    }

    if (!mounted || _finished) {
      controller.dispose();
      return;
    }
    _controller = controller;
    debugPrint('PyloFaceTiming camera_ready=${_screenSw.elapsedMilliseconds}ms');
    setState(() {
      _initializing = false;
      _statusMessage = widget.mode == FaceIdCaptureMode.enroll
          ? 'Hold still and look at the camera'
          : 'Look at the camera to unlock';
    });
    _startAutoCapture();
  }

  // -----------------------------------------------------------------------
  // Auto-capture loop — one frame at a time, drop frames while busy
  // -----------------------------------------------------------------------

  Future<void> _startAutoCapture() async {
    if (_loopRunning) return;
    _loopRunning = true;
    try {
      while (!_finished) {
        if (_controller == null || !_controller!.value.isInitialized) {
          await Future.delayed(const Duration(milliseconds: 50));
          continue;
        }
        if (widget.mode == FaceIdCaptureMode.authenticate &&
            _cooldownUntil != null) {
          await Future.delayed(const Duration(milliseconds: 250));
          continue;
        }
        // Single-flight: never queue a second capture while one is in
        // flight. Skip == drop stale frames; the latest frame wins.
        if (_processingFrame || _controller!.value.isTakingPicture) {
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
      final processing = await _runCapturePipeline(controller);
      if (_finished || !mounted || processing == null) return;

      if (widget.mode == FaceIdCaptureMode.enroll) {
        await _handleEnrollResult(processing);
      } else {
        _handleAuthResult(processing);
      }
    } finally {
      _processingFrame = false;
    }
  }

  /// Runs the full ML pipeline on a single capture and returns both the
  /// processing result (for alignment/embedding) and the optional liveness
  /// face object. Returns null on transient camera/pipeline failure — the
  /// loop simply retries on the next tick.
  Future<_CaptureAndLiveness?> _runCapturePipeline(
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
      return _CaptureAndLiveness(result);
    } catch (e) {
      debugPrint('Face capture pipeline failed: $e');
      return null;
    }
  }

  // -----------------------------------------------------------------------
  // Enrollment
  // -----------------------------------------------------------------------

  Future<void> _handleEnrollResult(_CaptureAndLiveness data) async {
    if (!mounted) return;
    final result = data.result;
    if (!result.success || result.embedding == null) {
      setState(() => _statusMessage = result.failReason ?? 'Try again');
      return;
    }

    final embedding = result.embedding!;
    if (result.face != null) _livenessTracker.feed(result.face!);

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

  // -----------------------------------------------------------------------
  // Authentication
  // -----------------------------------------------------------------------

  void _handleAuthResult(_CaptureAndLiveness data) {
    if (!mounted) return;
    final result = data.result;
    if (!result.success || result.embedding == null) {
      _failStreak++;
      _scheduleCooldown();
      setState(
          () => _statusMessage = result.failReason ?? 'No match — try again');
      return;
    }

    // Feed liveness tracker.
    if (result.face != null) _livenessTracker.feed(result.face!);

    _scoreAndRoute(result.embedding!);
  }

  Future<void> _scoreAndRoute(Float32List embedding) async {
    final sw = Stopwatch()..start();
    final match = await FaceIdService.matchAgainstStoredTemplate(embedding);
    debugPrint('PyloFaceTiming match=${sw.elapsedMilliseconds}ms');
    if (_finished || !mounted) return;

    if (match.matched) {
      if (FaceIdConfig.requireLivenessForUnlock && !_livenessTracker.verified) {
        final hint = _livenessTracker.sawBlink
            ? 'Blink again to prove you are live'
            : 'Turn your head slightly to prove liveness';
        setState(() => _statusMessage = hint);
        return;
      }
      _finish(true);
      return;
    }

    _failStreak++;
    _scheduleCooldown();
    setState(() => _statusMessage = 'No match — try again');
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
          setState(() => _statusMessage = 'Look at the camera to unlock');
        }
      } else if (mounted) {
        final sec = _cooldownUntil!.difference(DateTime.now()).inSeconds + 1;
        setState(() => _statusMessage = 'Try again in $sec s');
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

            // Enrollment progress dots.
            if (widget.mode == FaceIdCaptureMode.enroll && showPreview)
              Positioned(
                top: 16,
                left: 0,
                right: 0,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(
                    FaceIdConfig.minEnrollSamples,
                    (i) {
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
                    },
                  ),
                ),
              ),

            // Fallback button (auth only).
            if (widget.mode == FaceIdCaptureMode.authenticate && showPreview)
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

// ---------------------------------------------------------------------------
// Small value class to keep pipeline result + liveness together.
// ---------------------------------------------------------------------------

class _CaptureAndLiveness {
  final FaceProcessingResult result;
  const _CaptureAndLiveness(this.result);
}