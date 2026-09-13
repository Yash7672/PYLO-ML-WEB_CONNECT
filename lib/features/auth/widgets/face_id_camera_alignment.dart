import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

/// Owns the ONLY authoritative geometry for the Face ID camera area: the
/// outer alignment oval (thin gray stroke) and the vertical-oval camera
/// preview that sits inside it.
///
/// All sizing/positioning is computed here from the available screen space
/// so the two shapes always share the same reference geometry and stay
/// aligned on any device. Nothing else in the capture screen may compute
/// oval geometry.
class FaceIdCameraAlignment extends StatelessWidget {
  const FaceIdCameraAlignment({super.key, required this.camera});

  final CameraController camera;

  /// Outer alignment oval: tall portrait oval in the upper-middle band.
  static double guideWidthOf(double w) => w * 0.68;

  static double guideHeightOf(double guideW) => guideW * 1.25;

  static double guideCenterYOf(double h) => h * 0.38;

  /// Camera preview: 80% of the outer oval, concentric inside it so it is
  /// surrounded by a consistent black gap and never touches the border.
  static double previewScale() => 0.8;

  @override
  Widget build(BuildContext context) {
    if (!camera.value.isInitialized) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxW = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.of(context).size.width;
        final maxH = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : MediaQuery.of(context).size.height;

        final guideW = guideWidthOf(maxW);
        final guideH = guideHeightOf(guideW);
        final guideCenter = Offset(maxW / 2, guideCenterYOf(maxH));
        final guideRect = Rect.fromCenter(
          center: guideCenter,
          width: guideW,
          height: guideH,
        );

        final preview = previewScale();
        final prevW = guideW * preview;
        final prevH = guideH * preview;
        final prevLeft = guideCenter.dx - prevW / 2;
        final prevTop = guideCenter.dy - prevH / 2;

        // The camera package reports preview dims in the sensor's native
        // (landscape-ish) frame; the rendered orientation is portrait, so
        // the texture is likewise landscape.
        final previewSize = camera.value.previewSize;
        final camW = previewSize?.height.toDouble() ?? 1.0;
        final camH = previewSize?.width.toDouble() ?? 1.0;

        return Stack(
          fit: StackFit.expand,
          children: [
            Positioned(
              left: prevLeft,
              top: prevTop,
              width: prevW,
              height: prevH,
              child: ClipOval(
                clipBehavior: Clip.hardEdge,
                child: FittedBox(
                  fit: BoxFit.cover,
                  clipBehavior: Clip.hardEdge,
                  child: SizedBox(
                    width: camW,
                    height: camH,
                    child: CameraPreview(camera),
                  ),
                ),
              ),
            ),
            CustomPaint(painter: _OuterOvalPainter(guideRect)),
          ],
        );
      },
    );
  }
}

class _OuterOvalPainter extends CustomPainter {
  const _OuterOvalPainter(this.ovalRect);

  final Rect ovalRect;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawOval(
      ovalRect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = Colors.white38,
    );
  }

  @override
  bool shouldRepaint(covariant _OuterOvalPainter oldDelegate) =>
      oldDelegate.ovalRect != ovalRect;
}