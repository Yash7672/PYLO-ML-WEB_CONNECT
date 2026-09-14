import 'package:flutter/foundation.dart';

/// Web build of [FaceEmbeddingService].
///
/// Flutter Web must never compile `package:tflite_flutter` — it depends on
/// `dart:ffi`, which does not exist on the web compilers (`dart:ffi is not
/// available on this platform`). This stub is what the conditional export in
/// `face_embedding_service.dart` selects when `dart.library.html` or
/// `dart.library.js_interop` is available, so the web dependency graph
/// contains zero references to TFLite / FFI.
///
/// Behavior: Face ID ML is simply unavailable on Web. Callers are gated by
/// `FaceIdConfig.isSupportedPlatform` (false on web) before they ever reach
/// inference, so these stubs are defensive — they return null / no-op rather
/// than crash if anything calls them.
///
/// IMPORTANT: this file must never import `tflite_flutter`, `package:ffi`,
/// `dart:ffi`, `dart:io`, or the `_io` implementation.
class FaceEmbeddingService {
  FaceEmbeddingService._();

  /// Model inference is unsupported on this platform.
  static bool get contractResolved => false;

  /// No model can be loaded on Web. Returns nothing; kept `await`-compatible
  /// with the IO variant so call sites compile identically on both platforms.
  static Future<void> loadContract() async {
    if (kDebugMode) {
      debugPrint('[FaceEmbeddingService] TFLite is unavailable on Web — '
          'Face ID ML not supported on this platform');
    }
  }

  /// Embedding inference is unsupported on this platform. Returns null
  /// (same contract as the IO variant when no model can load).
  static Future<Float32List?> embed(Float32List input) async => null;

  /// Entrance point (see [embed]). Unsupported on Web → null.
  static Future<Float32List?> embedPixels(Float32List pixels) async => null;

  /// No-op teardown: there is no interpreter to release on Web.
  static void dispose() {}
}