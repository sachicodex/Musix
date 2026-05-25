import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

class LibraryScanRequest {
  const LibraryScanRequest({
    required this.sources,
    required this.supportedExtensions,
  });

  final List<String> sources;
  final List<String> supportedExtensions;
}

Future<List<String>> expandAudioSourceFiles({
  required List<String> sources,
  required List<String> supportedExtensions,
}) {
  return compute(
    _expandAudioSourceFilesOnWorker,
    LibraryScanRequest(
      sources: sources,
      supportedExtensions: supportedExtensions,
    ),
  );
}

const List<String> _excludedLocalAudioPathTokens = <String>[
  'whatsapp',
  'com.whatsapp',
  'whatsapp media',
  'telegram',
  'com.telegram',
];

List<String> _expandAudioSourceFilesOnWorker(LibraryScanRequest request) {
  final Set<String> supported = request.supportedExtensions
      .map((String item) => item.toLowerCase())
      .toSet();
  final Set<String> results = <String>{};

  for (final String source in request.sources) {
    if (_isExcludedLocalAudioPath(source)) {
      continue;
    }

    final FileSystemEntityType type = FileSystemEntity.typeSync(source);
    if (type == FileSystemEntityType.file) {
      if (_isAudioFile(source, supported)) {
        results.add(source);
      }
      continue;
    }

    if (type == FileSystemEntityType.directory) {
      final Iterable<FileSystemEntity> entities = Directory(
        source,
      ).listSync(recursive: true, followLinks: false);
      for (final FileSystemEntity entity in entities) {
        if (entity is! File) {
          continue;
        }
        if (_isExcludedLocalAudioPath(entity.path)) {
          continue;
        }
        if (_isAudioFile(entity.path, supported)) {
          results.add(entity.path);
        }
      }
    }
  }

  return results.toList()..sort();
}

bool isExcludedLocalAudioPath(String path) {
  return _isExcludedLocalAudioPath(path);
}

bool _isExcludedLocalAudioPath(String path) {
  final String normalized = p
      .normalize(path)
      .replaceAll('/', '\\')
      .toLowerCase();
  for (final String token in _excludedLocalAudioPathTokens) {
    if (normalized.contains(token)) {
      return true;
    }
  }
  final String fileName = p.basename(normalized);
  if (fileName.startsWith('ptt-')) {
    return true;
  }
  if (fileName.startsWith('aud-') && fileName.contains('-wa')) {
    return true;
  }
  if (fileName.startsWith('whatsapp')) {
    return true;
  }
  return false;
}

bool _isAudioFile(String path, Set<String> supportedExtensions) {
  final String extension = p
      .extension(path)
      .replaceFirst('.', '')
      .toLowerCase();
  return supportedExtensions.contains(extension);
}
