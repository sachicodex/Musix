import 'dart:convert';

import 'package:flutter/foundation.dart';

Future<Map<String, dynamic>?> decodeSnapshotJson(String raw) {
  return compute(_decodeSnapshotJsonOnWorker, raw);
}

Future<String> encodeSnapshotJson(Map<String, dynamic> payload) {
  return compute(_encodeSnapshotJsonOnWorker, payload);
}

Map<String, dynamic>? _decodeSnapshotJsonOnWorker(String raw) {
  if (raw.trim().isEmpty) {
    return null;
  }
  final Object? decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Snapshot root is not a JSON object.');
  }
  return decoded;
}

String _encodeSnapshotJsonOnWorker(Map<String, dynamic> payload) {
  return const JsonEncoder.withIndent('  ').convert(payload);
}
