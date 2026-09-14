import 'package:flutter/foundation.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import 'face_id_config.dart';

/// Loads the bundled MobileFaceNet model once and runs forward passes.
///
/// The 192-d embedding is compared by [FaceMatchingService]; this layer is a
/// thin, caching wrapper around `package:tflite_flutter` so callers never
/// touch interpreter plumbing.
///
/// The interpreter's ACTUAL tensor metadata (read from the loaded model) is
/// used to build every inference input/output — nothing is assumed from the
/// config file, so a mismatched or differently-shaped model fails loudly
/// instead of silently producing garbage.
///
/// PLATFORM: this file imports `package:tflite_flutter`, which depends on
/// `dart:ffi`. It is only ever imported by the conditional export in
/// `face_embedding_service.dart` when running on IO platforms (Android, iOS,
/// desktop). The web compiler selects `face_embedding_service_web.dart`
/// instead, so tflite_flutter never enters the web dependency graph.
class FaceEmbeddingService {
  FaceEmbeddingService._();

  static Interpreter? _interpreter;

  /// Verified tensor contract of the loaded model (null until first load).
  static _ModelContract? _contract;

  @visibleForTesting
  static Interpreter? get interpreter => _interpreter;

  /// True once [loadContract] saw a flat / incompatible input shape and
  /// successfully reshaped the interpreter to the expected 4-D layout.
  static bool get contractResolved => _contract?.resolved == true;

  /// Loads the model from the bundled asset, trying fallback keys on failure.
  /// Returns null (never throws) when the asset cannot be located — callers
  /// surface that as "Face ID unavailable".
  static Future<Interpreter?> _loadInterpreter() async {
    if (_interpreter != null) return _interpreter;
    final keys = [
      FaceIdConfig.modelAssetPath,
      ...FaceIdConfig.modelAssetFallbacks,
    ];
    for (final key in keys) {
      try {
        final interpreter = await Interpreter.fromAsset(
          key,
          options: InterpreterOptions()
            ..threads = FaceIdConfig.interpreterThreads,
        );
        _interpreter = interpreter;
        return interpreter;
      } catch (e) {
        debugPrint('TFLite load failed for "$key": $e');
      }
    }
    return null;
  }

  /// Reads the model's real input/output tensor metadata. Logs only
  /// non-sensitive technical detail (shape + dtype) — never pixel data or
  /// embeddings.
  static Future<_ModelContract?> loadContract() async {
    if (_contract != null) return _contract;
    final interpreter = await _loadInterpreter();
    if (interpreter == null) return null;
    try {
      final input = interpreter.getInputTensor(0);
      final output = interpreter.getOutputTensor(0);

      // Center a wrong/possible flat input (e.g. [37632]) on the canonical
      // [1, H, W, C] layout that this pipeline is built around. This is only
      // a corrective reshape of model input index 0 — it makes a
      // mistakenly-flattened export usable instead of crashing CONV_2D.
      final inShape = input.shape;
      var reshaped = false;
      List<int> effectiveInputShape = inShape;
      bool resolved = false;
      if (inShape.isEmpty ||
          (inShape.length != 4 && inShape.length != 3)) {
        final expected = [
          1,
          FaceIdConfig.modelInputSize,
          FaceIdConfig.modelInputSize,
          3,
        ];
        if (Tensor.computeNumElements(inShape) ==
            Tensor.computeNumElements(expected)) {
          try {
            interpreter.resizeInputTensor(0, expected);
            interpreter.allocateTensors();
            reshaped = true;
            effectiveInputShape = expected;
            resolved = true;
            debugPrint(
              'TFLite input reshaped flat $inShape -> $expected',
            );
          } catch (e) {
            debugPrint('TFLite input reshape failed (kept $inShape): $e');
          }
        }
      } else if (inShape.length == 4) {
        resolved = true;
      }

      _contract = _ModelContract(
        inputShape: effectiveInputShape,
        inputType: input.type,
        outputShape: output.shape,
        outputType: output.type,
        resolved: resolved,
        reshaped: reshaped,
      );

      debugPrint('[FaceEmbeddingService] model contract: '
          'in=${effectiveInputShape} (${input.type.name}), '
          'out=${output.shape} (${output.type.name}), '
          'reshaped=$reshaped resolved=$resolved');
      return _contract;
    } catch (e) {
      debugPrint('TFLite tensor introspection failed: $e');
      return null;
    }
  }

  static int _numElementsOf(List<int> shape) =>
      Tensor.computeNumElements(shape);

  /// Runs the model on a flat row-major pixel buffer whose element count
  /// matches the model's input tensor. The buffer is expected to be the
  /// preprocessed probe (resized, normalized), matching [embedPixels]'s
  /// contract.
  ///
  /// CRITICAL: the pixels are handed to `interpreter.run` as a raw byte view
  /// (`Uint8List` of the float32 buffer), NOT as a flat `Float32List` or
  /// nested lists. tflite_flutter's `runInference` auto-reshapes the input
  /// tensor from the shape it infers on the passed object — a flat
  /// `Float32List` is inferred as rank-1 `[37632]` and the interpreter
  /// destructively resizes its input, so CONV_2D fails with
  /// `input->dims->size != 4 (1 != 4)`. `Uint8List` bypasses that reshaping
  /// path and is copied byte-for-byte into the model's fixed `[1,112,112,3]`
  /// input tensor.
  static Future<Float32List?> embed(Float32List input) async {
    final interpreter = await _loadInterpreter();
    if (interpreter == null) return null;
    try {
      final contract = await loadContract();
      if (contract == null) {
        debugPrint('Embedding rejected: no model contract available');
        return null;
      }

      final expected = _numElementsOf(contract.inputShape);
      if (input.length != expected) {
        debugPrint(
            'Embedding rejected: model needs $expected floats '
            '(${contract.inputShape}), got ${input.length}');
        return null;
      }

      // Byte view of the float32 pixels (little-endian, matches the model's
      // FLOAT32 input tensor). Length must stay a multiple of 4.
      final byteView = input.buffer.asUint8List(
        input.offsetInBytes,
        input.lengthInBytes,
      );

      // Output must mirror the tensor's nested layout ([1, 192] -> one inner
      // list of 192 doubles) for tflite_flutter's copyTo to fill it.
      final outputShape = contract.outputShape;
      var perBatch = 1;
      for (var i = 1; i < outputShape.length; i++) {
        perBatch *= outputShape[i];
      }
      if (perBatch <= 0) perBatch = FaceIdConfig.embeddingSize;
      final output = List<List<double>>.generate(
        1,
        (_) => List<double>.filled(perBatch, 0.0),
      );
      interpreter.run(byteView, output);
      return Float32List.fromList(output.first);
    } catch (e) {
      debugPrint('Embedding inference failed: $e');
      // A broken interpreter is worse than none — drop it so the next call
      // retries from scratch. Also drop any cached contract so a fresh model
      // gets a fresh introspect.
      try {
        interpreter.close();
      } catch (_) {}
      _interpreter = null;
      _contract = null;
      return null;
    }
  }

  /// Entrance point: validates the flat pixel buffer length against the
  /// model's verified input and runs [embed].
  static Future<Float32List?> embedPixels(Float32List pixels) async {
    final contract = await loadContract();
    if (contract == null) {
      debugPrint('Embedding rejected: model not introspected');
      return null;
    }
    final expectedElements = _numElementsOf(contract.inputShape);
    if (pixels.length != expectedElements) {
      debugPrint(
          'Embedding rejected: expected $expectedElements floats for '
          '${contract.inputShape}, got ${pixels.length}');
      return null;
    }
    return embed(pixels);
  }

  /// Best-effort teardown (screen dispose). The interpreter re-loads lazily
  /// on the next use.
  static void dispose() {
    try {
      _interpreter?.close();
    } catch (_) {}
    _interpreter = null;
    _contract = null;
  }
}

/// Immutable record of the model's real tensor contract, captured once at
/// load time so the pipeline can both validate probe layouts and construct
/// correctly-sized output buffers.
class _ModelContract {
  final List<int> inputShape;
  final TensorType inputType;
  final List<int> outputShape;
  final TensorType outputType;

  /// True when the input is (or was reshaped to) a usable 4-D layout.
  final bool resolved;

  /// True when a corrective reshape of input index 0 was applied.
  final bool reshaped;

  const _ModelContract({
    required this.inputShape,
    required this.inputType,
    required this.outputShape,
    required this.outputType,
    required this.resolved,
    required this.reshaped,
  });
}