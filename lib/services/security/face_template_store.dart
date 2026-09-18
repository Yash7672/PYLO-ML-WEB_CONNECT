import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'face_id_config.dart';

/// Version marker for the stored template blob. Bump when the serialization
/// format changes so old blobs are rejected instead of misinterpreted.
const int _templateVersion = 1;

/// A face template captured on this device. Holds one embedding per enrolled
/// pose; matching takes the best cosine similarity across all of them.
@immutable
class FaceTemplate {
  final int version;
  final DateTime enrolledAt;

  /// 192-d float embeddings, one per enrolled pose.
  final List<Float32List> embeddings;

  const FaceTemplate({
    required this.version,
    required this.enrolledAt,
    required this.embeddings,
  });

  /// Serializes to a compact JSON string: version, timestamp and base64-
  /// encoded float32 payloads. Safe to persist (no raw image data — only
  /// the numeric model output, which is useless for reconstruction).
  String toEncoded() {
    final payload = <String, dynamic>{
      'v': version,
      'at': enrolledAt.millisecondsSinceEpoch,
      'e': [
        for (final e in embeddings)
          base64Encode(e.buffer.asUint8List(e.offsetInBytes, e.lengthInBytes)),
      ],
    };
    return jsonEncode(payload);
  }

  /// Inverse of [toEncoded]. Returns null when the blob is missing, corrupt
  /// or from a newer format — callers treat that as "no usable template".
  static FaceTemplate? tryDecode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final version = decoded['v'];
      if (version is! int || version != _templateVersion) return null;
      final at = decoded['at'];
      if (at is! int) return null;
      final list = decoded['e'];
      if (list is! List) return null;
      final embeddings = <Float32List>[];
      for (final item in list) {
        if (item is! String) return null;
        final bytes = base64Decode(item);
        if (bytes.length != FaceIdConfig.embeddingSize * 4) return null;
        embeddings.add(
          Float32List.sublistView(ByteData.sublistView(bytes)),
        );
      }
      if (embeddings.isEmpty) return null;
      return FaceTemplate(
        version: version,
        enrolledAt: DateTime.fromMillisecondsSinceEpoch(at),
        embeddings: embeddings,
      );
    } catch (e) {
      debugPrint('Face template decode failed (treated as absent): $e');
      return null;
    }
  }
}

/// Persists the face template in the OS secure enclave-backed storage
/// (same vault as the app-lock PIN). Templates are never written to
/// SharedPreferences and never included in backups.
class FaceTemplateStore {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(),
  );
  static const _templateKey = 'pylo_face_template_v1';

  static Future<FaceTemplate?> load() async {
    try {
      final raw = await _storage.read(key: _templateKey);
      return FaceTemplate.tryDecode(raw);
    } catch (e) {
      debugPrint('Face template load failed: $e');
      return null;
    }
  }

  static Future<bool> exists() async {
    try {
      final raw = await _storage.read(key: _templateKey);
      return FaceTemplate.tryDecode(raw) != null;
    } catch (e) {
      debugPrint('Face template existence check failed: $e');
      return false;
    }
  }

  static Future<void> save(FaceTemplate template) async {
    try {
      await _storage.write(key: _templateKey, value: template.toEncoded());
    } catch (e) {
      debugPrint('Face template write failed: $e');
      rethrow;
    }
  }

  static Future<void> delete() async {
    try {
      await _storage.delete(key: _templateKey);
    } catch (e) {
      debugPrint('Face template delete failed: $e');
    }
  }
}