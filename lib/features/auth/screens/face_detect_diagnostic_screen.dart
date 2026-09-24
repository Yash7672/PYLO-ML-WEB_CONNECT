import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;

import '../../../services/security/face_detection_service.dart';
import '../../../services/security/face_id_config.dart';
import '../../../services/security/face_id_service.dart';

/// DEBUG-ONLY diagnostic: proves whether ML Kit can detect a face using the
/// EXACT same camera → image → ML Kit pipeline as Face ID unlock.
///
///  * Camera: same selection (front preferred) + [ResolutionPreset.medium] +
///    `enableAudio: false` as [FaceIdCaptureScreen].
///  * Capture: `takePicture()` → JPEG file, `InputImage.fromFilePath` (EXIF
///    honored by the framework) → the same [FaceDetectionService.detector].
///  * No liveness, no MobileFaceNet, no matching, no 0.85 threshold.
///
/// It shows the raw ML Kit result — FACE DETECTED / NO FACE / MULTIPLE FACES
/// / ERROR — plus a live bounding-box overlay, a thumbnail of the exact baked
/// image ML Kit receives, and a per-frame `FaceDebug:` log. It never uploads
/// or persists any image. This screen is only reachable from the debug entry
/// in Settings (kDebugMode).
class FaceDetectDiagnosticScreen extends StatefulWidget {
  const FaceDetectDiagnosticScreen({super.key});

  @override
  State<FaceDetectDiagnosticScreen> createState() =>
      _FaceDetectDiagnosticScreenState();
}

class _FrameResult {
  final FaceDetectionRawResult raw;
  final int imageWidth;
  final int imageHeight;
  final int exifOrientation;
  const _FrameResult({
    required this.raw,
    required this.imageWidth,
    required this.imageHeight,
    required this.exifOrientation,
  });
}

class _FaceDetectDiagnosticScreenState extends State<FaceDetectDiagnosticScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  final FaceDetectionService _detector = FaceDetectionService();

  bool _initializing = true;
  String? _cameraError;
  String? _cameraLabel;

  _FrameResult? _last;
  Uint8List? _thumbPng;
  bool _mirror = true;

  bool _processing = false;
  bool _disposed = false;
  int _thumbEveryN = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _detector.dispose();
    _controller?.dispose();
    _controller = null;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _controller?.dispose();
      _controller = null;
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  Future<void> _initCamera() async {
    if (_disposed) return;
    if (_controller != null && _controller!.value.isInitialized) return;
    if (!FaceIdConfig.isSupportedPlatform) {
      setState(() {
        _initializing = false;
        _cameraError = 'Face detector is not supported on this platform';
      });
      return;
    }
    setState(() {
      _initializing = true;
      _cameraError = null;
    });

    // Cached descriptor (shared with Face ID): reuses the startup pick when
    // available instead of re-enumerating cameras on every run.
    final cam = await FaceIdService.pickFrontCamera();
    if (cam == null) {
      FaceIdService.invalidateCameraCache();
      if (!mounted) return;
      setState(() {
        _initializing = false;
        _cameraError = 'No camera available';
      });
      return;
    }

    // IDENTICAL to the Face ID screen: front camera, medium preset.
    final controller =
        CameraController(cam, ResolutionPreset.medium, enableAudio: false);
    try {
      await controller.initialize();
    } on CameraException catch (e) {
      if (!mounted) {
        controller.dispose();
        return;
      }
      setState(() {
        _initializing = false;
        _cameraError = 'Camera error: ${e.description ?? e.code}';
      });
      controller.dispose();
      return;
    }

    if (!mounted || _disposed) {
      controller.dispose();
      return;
    }
    _controller = controller;
    _cameraLabel = '${cam.name} lens=${cam.lensDirection} '
        'sensor=${cam.sensorOrientation}° '
        'res=${controller.value.previewSize}';
    if (kDebugMode) {
      debugPrint('FaceDebug: camera=$_cameraLabel');
    }
    setState(() => _initializing = false);
    _runLoop();
  }

  Future<void> _runLoop() async {
    while (!_disposed) {
      final controller = _controller;
      if (controller == null || !controller.value.isInitialized) {
        await Future.delayed(const Duration(milliseconds: 50));
        continue;
      }
      if (_processing || controller.value.isTakingPicture) {
        await Future.delayed(const Duration(milliseconds: 40));
        continue;
      }
      await _diagnose(controller);
      await Future.delayed(FaceIdConfig.authCaptureGap);
    }
  }

  Future<void> _diagnose(CameraController controller) async {
    _processing = true;
    try {
      final file = await controller.takePicture();

      // --- EXACT same image path as Face ID unlock ----------------------
      final bytes = await file.readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) {
        _setResult(const _FrameResult(
            raw: FaceDetectionRawResult(
                error: 'Camera returned a non-decodable JPEG'),
            imageWidth: 0,
            imageHeight: 0,
            exifOrientation: -1));
        return;
      }
      final upright = img.bakeOrientation(decoded);
      int exifOrientation = -1;
      try {
        final exif = img.decodeJpgExif(bytes);
        exifOrientation = exif?.getTag(0x0112)?.toInt() ?? -1;
      } catch (_) {}

      final inputImage = InputImage.fromFilePath(file.path);
      final rawResult = await _detector.detectFromImageRaw(inputImage);

      // --- debug payload ------------------------------------------------
      final buf = StringBuffer('\nFaceDebug: camera=ready\n');
      buf.writeln('image=${upright.width}x${upright.height}px');
      buf.writeln('exif_orientation=$exifOrientation');
      if (rawResult.threw) {
        buf.writeln('error=${rawResult.error}');
      }
      buf.writeln('faces=${rawResult.faces.length}');
      for (final f in rawResult.faces) {
        final q = FaceIdService.classifyFace(
            f, upright.width, upright.height);
        buf.writeln('bbox=${f.boundingBox} landmarks=${f.landmarks.length} '
            'leftEye=${f.leftEyeOpenProbability?.toStringAsFixed(2) ?? 'null'} '
            'rightEye=${f.rightEyeOpenProbability?.toStringAsFixed(2) ?? 'null'} '
            'yaw=${f.headEulerAngleY?.toStringAsFixed(1) ?? 'null'} '
            'pitch=${f.headEulerAngleX?.toStringAsFixed(1) ?? 'null'} '
            'roll=${f.headEulerAngleZ?.toStringAsFixed(1) ?? 'null'} '
            'quality=$q');
      }
      debugPrint(buf.toString().trimRight());

      if (_disposed) return;
      final result = _FrameResult(
        raw: rawResult,
        imageWidth: upright.width,
        imageHeight: upright.height,
        exifOrientation: exifOrientation,
      );
      setState(() => _last = result);

      // Thumbnail of the EXACT baked image ML Kit sees — throttled so the PNG
      // encode doesn't churn the UI thread.
      _thumbEveryN++;
      if (_thumbEveryN >= 8) {
        _thumbEveryN = 0;
        var preview = upright;
        if (preview.width > 320) {
          preview = img.copyResize(preview,
              width: 320, interpolation: img.Interpolation.linear);
        }
        final png = img.encodePng(preview);
        if (!_disposed && mounted) {
          setState(() => _thumbPng = png);
        }
      }
    } catch (e) {
      debugPrint('FaceDebug: capture/detect threw: $e');
      if (!_disposed && mounted) {
        setState(() {
          _last = _FrameResult(
            raw: FaceDetectionRawResult(error: e),
            imageWidth: 0,
            imageHeight: 0,
            exifOrientation: -1,
          );
        });
      }
    } finally {
      _processing = false;
    }
  }

  void _setResult(_FrameResult r) {
    if (_disposed || !mounted) return;
    setState(() => _last = r);
  }

  String get _statusText {
    if (_cameraError != null) return 'CAMERA ERROR';
    if (_initializing) return 'INITIALIZING CAMERA…';
    final r = _last;
    if (r == null) return 'WAITING FOR FRAME…';
    if (r.raw.threw) return 'ML KIT ERROR';
    if (r.raw.faces.isEmpty) return 'NO FACE';
    if (r.raw.faces.length > 1) return 'MULTIPLE FACES';
    return 'FACE DETECTED';
  }

  Color get _statusColor {
    if (_cameraError != null) return Colors.redAccent;
    if (_initializing) return Colors.white70;
    final r = _last;
    if (r == null) return Colors.white70;
    if (r.raw.threw) return Colors.redAccent;
    if (r.raw.faces.isEmpty) return Colors.redAccent;
    if (r.raw.faces.length > 1) return Colors.amber;
    return Colors.greenAccent;
  }

  String get _detailsText {
    final r = _last;
    final sb = StringBuffer();
    if (_cameraLabel != null) sb.writeln('camera: $_cameraLabel');
    if (_cameraError != null) {
      sb.writeln('cameraError: $_cameraError');
    }
    if (r != null) {
      sb.writeln('image: ${r.imageWidth}x${r.imageHeight}px '
          'exif=${r.exifOrientation}');
      if (r.raw.threw) {
        sb.writeln('mlkit_error: ${r.raw.error}');
      }
      sb.writeln('faces: ${r.raw.faces.length}');
      for (final f in r.raw.faces) {
        final q =
            FaceIdService.classifyFace(f, r.imageWidth, r.imageHeight);
        sb.writeln('  bbox=${f.boundingBox} yaw=${f.headEulerAngleY ?? 'null'} '
            'leftEye=${f.leftEyeOpenProbability ?? 'null'} '
            'rightEye=${f.rightEyeOpenProbability ?? 'null'} '
            'landmarks=${f.landmarks.length} quality=$q');
      }
    } else {
      sb.writeln('image: -');
      sb.writeln('faces: -');
    }
    return sb.toString();
  }

  @override
  Widget build(BuildContext context) {
    final camera = _controller;
    final showPreview = camera != null && !_initializing;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (showPreview)
              Positioned.fill(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        CameraPreview(camera),
                        CustomPaint(
                          painter: _FaceBoxPainter(
                              _last, _mirror, constraints.biggest),
                        ),
                      ],
                    );
                  },
                ),
              ),
            if (_initializing)
              const Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),

            // Status pill.
            Positioned(
              top: 16,
              left: 16,
              right: 88,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: _statusColor, width: 2),
                ),
                child: Text(
                  _statusText,
                  style: TextStyle(
                    color: _statusColor,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ),

            // Mirror toggle (front preview display is mirrored; ML input is not).
            Positioned(
              top: 10,
              right: 8,
              child: IconButton(
                onPressed: () => setState(() => _mirror = !_mirror),
                icon: Icon(_mirror
                    ? Icons.flip
                    : Icons.flip_outlined),
                color: Colors.white70,
                tooltip: 'Toggle mirror overlay',
              ),
            ),

            // Back.
            Positioned(
              bottom: 8,
              left: 8,
              child: IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close, color: Colors.white70),
              ),
            ),

            // Info panel + thumbnail of the exact ML Kit input image.
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                constraints: const BoxConstraints(maxHeight: 250),
                color: Colors.black87,
                padding:
                    const EdgeInsets.fromLTRB(16, 8, 16, 58),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Thumbnail(bytes: _thumbPng),
                    const SizedBox(width: 12),
                    Expanded(
                      child: SingleChildScrollView(
                        child: Text(
                          _detailsText,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                            fontFamily: 'monospace',
                            height: 1.35,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              child: Text(
                'This diagnostic uses the exact Face ID pipeline '
                '(front camera, medium, JPEG+EXIF, InputImage.fromFilePath). '
                'No image is uploaded or saved.',
                style: TextStyle(color: Colors.white38, fontSize: 10),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shows the exact baked upright image that was sent to ML Kit, proving the
/// frame actually contains the face and is not rotated/black/blown out.
class _Thumbnail extends StatelessWidget {
  final Uint8List? bytes;
  const _Thumbnail({this.bytes});

  @override
  Widget build(BuildContext context) {
    if (bytes == null) {
      return Container(
        width: 96,
        height: 128,
        color: Colors.white10,
        alignment: Alignment.center,
        child: const Text('frame\npreview',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white38, fontSize: 10)),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.memory(
        bytes!,
        width: 96,
        fit: BoxFit.cover,
        gaplessPlayback: true,
      ),
    );
  }
}

/// Draws the ML Kit bounding boxes over the live preview. Coordinates arrive
/// in the upright (EXIF-baked) image space; the preview shows that same image
/// fitted with cover-crop, so the boxes are mapped through the same fit and
/// mirrored for the front-camera viewfinder look.
class _FaceBoxPainter extends CustomPainter {
  final _FrameResult? result;
  final bool mirror;
  final Size box;

  _FaceBoxPainter(this.result, this.mirror, this.box);

  @override
  void paint(Canvas canvas, Size size) {
    final r = result;
    if (r == null || r.raw.faces.isEmpty ||
        r.imageWidth <= 0 || r.imageHeight <= 0) {
      return;
    }
    final uw = r.imageWidth.toDouble();
    final uh = r.imageHeight.toDouble();

    final boxW = box.width;
    final boxH = box.height;
    final aspect = uw / uh;

    double displayedW, displayedH, offsetX, offsetY;
    if (boxW / boxH > aspect) {
      displayedH = boxH;
      displayedW = boxH * aspect;
      offsetX = (boxW - displayedW) / 2;
      offsetY = 0;
    } else {
      displayedW = boxW;
      displayedH = boxW / aspect;
      offsetX = 0;
      offsetY = (boxH - displayedH) / 2;
    }

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..color = r.raw.faces.length == 1 ? Colors.greenAccent : Colors.amber;

    for (final f in r.raw.faces) {
      final bbox = f.boundingBox;
      var x = bbox.left / uw * displayedW;
      final y = bbox.top / uh * displayedH;
      final w = bbox.width / uw * displayedW;
      final h = bbox.height / uh * displayedH;
      if (mirror) x = displayedW - (x + w);
      canvas.drawRect(
        Rect.fromLTWH(offsetX + x, offsetY + y, w, h),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_FaceBoxPainter oldDelegate) =>
      oldDelegate.result != result ||
      oldDelegate.mirror != mirror ||
      oldDelegate.box != box;
}