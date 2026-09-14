// Platform-selected entry point for [FaceEmbeddingService].
//
// `package:tflite_flutter` depends on `dart:ffi`, which the web compilers do
// not provide. This file must therefore NEVER import TFLite directly —
// instead the compiler picks one of two implementations:
//
// - IO platforms (Android, iOS, desktop): `face_embedding_service_io.dart`
//   — the real MobileFaceNet interpreter wrapper.
// - Web (JS + Wasm): `face_embedding_service_web.dart` — a tflite-free stub
//   that reports Face ID ML as unsupported.
//
// Keeping the selection in a conditional EXPORT means the web dependency
// graph never reaches `tflite_flutter` or `dart:ffi`, while the Android
// build imports the exact same implementation as before.
export 'face_embedding_service_io.dart'
    if (dart.library.html) 'face_embedding_service_web.dart'
    if (dart.library.js_interop) 'face_embedding_service_web.dart';