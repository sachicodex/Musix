import 'package:path/path.dart' as p;

import 'models.dart';

class PlaybackStreamCandidate {
  const PlaybackStreamCandidate({
    required this.transport,
    required this.url,
    required this.bitrateBitsPerSecond,
    this.source,
    this.streamTag,
    this.videoHeight,
    this.qualityLabel,
    this.containerName,
    this.codecDescription,
    this.audioCodec,
    this.videoCodec,
  });

  final PlaybackStreamTransport transport;
  final String url;
  final int bitrateBitsPerSecond;
  final Object? source;
  final int? streamTag;
  final int? videoHeight;
  final String? qualityLabel;
  final String? containerName;
  final String? codecDescription;
  final String? audioCodec;
  final String? videoCodec;
}

class PlaybackStreamResolution {
  const PlaybackStreamResolution({required this.url, required this.info});

  final String url;
  final PlaybackStreamInfo info;
}

List<PlaybackStreamCandidate> rankPlaybackStreamCandidates(
  List<PlaybackStreamCandidate> candidates,
) {
  final List<PlaybackStreamCandidate> ranked = <PlaybackStreamCandidate>[];
  for (final PlaybackStreamTransport transport in _preferredTransportOrder) {
    final List<PlaybackStreamCandidate> matches =
        candidates
            .where(
              (PlaybackStreamCandidate item) => item.transport == transport,
            )
            .toList()
          ..sort(_comparePlaybackStreamCandidates);
    ranked.addAll(matches);
  }
  return ranked;
}

int? nextPlaybackFallbackIndex(
  List<PlaybackStreamCandidate> rankedCandidates,
  int currentIndex,
) {
  if (currentIndex < 0 || currentIndex >= rankedCandidates.length) {
    return null;
  }
  final PlaybackStreamTransport currentTransport =
      rankedCandidates[currentIndex].transport;
  for (
    int index = currentIndex + 1;
    index < rankedCandidates.length;
    index += 1
  ) {
    if (rankedCandidates[index].transport != currentTransport) {
      return index;
    }
  }
  return null;
}

int preferredPlaybackCandidateIndex({
  required List<PlaybackStreamCandidate> rankedCandidates,
  required int currentIndex,
  bool preferMuxedStability = false,
}) {
  if (rankedCandidates.isEmpty) {
    return 0;
  }
  final int safeCurrentIndex = currentIndex.clamp(
    0,
    rankedCandidates.length - 1,
  );
  if (!preferMuxedStability || safeCurrentIndex != 0) {
    return safeCurrentIndex;
  }
  final PlaybackStreamTransport transport =
      rankedCandidates[safeCurrentIndex].transport;
  if (transport != PlaybackStreamTransport.audioOnly &&
      transport != PlaybackStreamTransport.hlsAudioOnly) {
    return safeCurrentIndex;
  }
  final int muxedIndex = rankedCandidates.indexWhere((
    PlaybackStreamCandidate candidate,
  ) {
    return candidate.transport == PlaybackStreamTransport.muxed ||
        candidate.transport == PlaybackStreamTransport.hlsMuxed;
  });
  return muxedIndex >= 0 ? muxedIndex : safeCurrentIndex;
}

PlaybackStreamResolution resolvePreferredPlaybackStream({
  required String songId,
  required String sourceLabel,
  required String originalUrl,
  String? externalUrl,
  required List<PlaybackStreamCandidate> candidates,
}) {
  final List<PlaybackStreamCandidate> rankedCandidates =
      rankPlaybackStreamCandidates(candidates);
  return resolvePlaybackStreamAtIndex(
    songId: songId,
    sourceLabel: sourceLabel,
    originalUrl: originalUrl,
    externalUrl: externalUrl,
    candidates: candidates,
    rankedCandidates: rankedCandidates,
    selectedIndex: 0,
    selectionPolicy: 'muxed-first-streaming',
  );
}

PlaybackStreamResolution resolvePlaybackStreamAtIndex({
  required String songId,
  required String sourceLabel,
  required String originalUrl,
  String? externalUrl,
  required List<PlaybackStreamCandidate> candidates,
  required List<PlaybackStreamCandidate> rankedCandidates,
  required int selectedIndex,
  required String selectionPolicy,
}) {
  final int audioOnlyCount = candidates.where((PlaybackStreamCandidate item) {
    return item.transport == PlaybackStreamTransport.audioOnly;
  }).length;
  final int hlsAudioOnlyCount = candidates.where((
    PlaybackStreamCandidate item,
  ) {
    return item.transport == PlaybackStreamTransport.hlsAudioOnly;
  }).length;
  final int muxedCount = candidates.where((PlaybackStreamCandidate item) {
    return item.transport == PlaybackStreamTransport.muxed;
  }).length;
  final int hlsMuxedCount = candidates.where((PlaybackStreamCandidate item) {
    return item.transport == PlaybackStreamTransport.hlsMuxed;
  }).length;
  final int hlsVideoOnlyCount = candidates.where((
    PlaybackStreamCandidate item,
  ) {
    return item.transport == PlaybackStreamTransport.hlsVideoOnly;
  }).length;

  if (rankedCandidates.isEmpty) {
    throw const FormatException('No playable YouTube stream found.');
  }
  final int safeSelectedIndex = selectedIndex.clamp(
    0,
    rankedCandidates.length - 1,
  );
  final PlaybackStreamCandidate selected = rankedCandidates[safeSelectedIndex];

  return PlaybackStreamResolution(
    url: selected.url,
    info: PlaybackStreamInfo(
      songId: songId,
      sourceLabel: sourceLabel,
      transport: selected.transport,
      selectionPolicy: selectionPolicy,
      originalUrl: originalUrl,
      resolvedUrl: selected.url,
      externalUrl: externalUrl,
      streamTag: selected.streamTag,
      bitrateBitsPerSecond: selected.bitrateBitsPerSecond,
      qualityLabel: selected.qualityLabel,
      containerName: selected.containerName,
      codecDescription: selected.codecDescription,
      audioCodec: selected.audioCodec,
      videoCodec: selected.videoCodec,
      availableAudioOnlyCount: audioOnlyCount,
      availableHlsAudioOnlyCount: hlsAudioOnlyCount,
      availableMuxedCount: muxedCount,
      availableHlsMuxedCount: hlsMuxedCount,
      availableHlsVideoOnlyCount: hlsVideoOnlyCount,
    ),
  );
}

PlaybackStreamInfo buildLocalPlaybackStreamInfo(LibrarySong song) {
  return PlaybackStreamInfo(
    songId: song.id,
    sourceLabel: song.sourceLabel,
    transport: PlaybackStreamTransport.localFile,
    selectionPolicy: 'local-file',
    originalUrl: song.path,
    resolvedUrl: song.path,
    externalUrl: song.externalUrl,
    containerName: _containerNameForPath(song.path),
  );
}

PlaybackStreamInfo buildDirectPlaybackStreamInfo(LibrarySong song) {
  return PlaybackStreamInfo(
    songId: song.id,
    sourceLabel: song.sourceLabel,
    transport: PlaybackStreamTransport.directUrl,
    selectionPolicy: 'direct-url',
    originalUrl: song.path,
    resolvedUrl: song.path,
    externalUrl: song.externalUrl,
    containerName: _containerNameForPath(song.path),
  );
}

PlaybackStreamInfo buildCachedPlaybackStreamInfo({
  required LibrarySong song,
  required String cachedPath,
  PlaybackStreamInfo? previousInfo,
}) {
  return PlaybackStreamInfo(
    songId: song.id,
    sourceLabel: song.sourceLabel,
    transport: PlaybackStreamTransport.cachedFile,
    selectionPolicy: 'cache-hit',
    originalUrl: previousInfo?.originalUrl ?? song.path,
    resolvedUrl: cachedPath,
    externalUrl: song.externalUrl ?? previousInfo?.externalUrl,
    upstreamTransport: previousInfo?.transport,
    streamTag: previousInfo?.streamTag,
    bitrateBitsPerSecond: previousInfo?.bitrateBitsPerSecond,
    qualityLabel: previousInfo?.qualityLabel,
    containerName:
        _containerNameForPath(cachedPath) ?? previousInfo?.containerName,
    codecDescription: previousInfo?.codecDescription,
    audioCodec: previousInfo?.audioCodec,
    videoCodec: previousInfo?.videoCodec,
    availableAudioOnlyCount: previousInfo?.availableAudioOnlyCount ?? 0,
    availableHlsAudioOnlyCount: previousInfo?.availableHlsAudioOnlyCount ?? 0,
    availableMuxedCount: previousInfo?.availableMuxedCount ?? 0,
    availableHlsMuxedCount: previousInfo?.availableHlsMuxedCount ?? 0,
    availableHlsVideoOnlyCount: previousInfo?.availableHlsVideoOnlyCount ?? 0,
  );
}

bool looksLikeYouTubePlaybackSource(String value) {
  return value.contains('youtube.com/') ||
      value.contains('youtu.be/') ||
      value.startsWith('yt:');
}

bool songNeedsResolvedPlaybackUrl(LibrarySong song) {
  return song.isRemote && looksLikeYouTubePlaybackSource(song.path);
}

List<int> queueReopenPreparationIndexes({
  required List<LibrarySong> queue,
  required int targetIndex,
}) {
  if (targetIndex < 0 || targetIndex >= queue.length) {
    return const <int>[];
  }
  final List<int> result = <int>[targetIndex];
  for (int index = targetIndex + 1; index < queue.length; index += 1) {
    if (songNeedsResolvedPlaybackUrl(queue[index])) {
      result.add(index);
    }
  }
  return result;
}

int _comparePlaybackStreamCandidates(
  PlaybackStreamCandidate a,
  PlaybackStreamCandidate b,
) {
  if (_isVideoTransport(a.transport) && _isVideoTransport(b.transport)) {
    final int? aHeight = _candidateVideoHeight(a);
    final int? bHeight = _candidateVideoHeight(b);
    if (aHeight != null || bHeight != null) {
      final int heightCompare = (aHeight ?? 1 << 30).compareTo(
        bHeight ?? 1 << 30,
      );
      if (heightCompare != 0) {
        return heightCompare;
      }
    }
  }
  final int bitrateCompare = a.bitrateBitsPerSecond.compareTo(
    b.bitrateBitsPerSecond,
  );
  if (bitrateCompare != 0) {
    return bitrateCompare;
  }
  return (a.streamTag ?? 0).compareTo(b.streamTag ?? 0);
}

const List<PlaybackStreamTransport> _preferredTransportOrder =
    <PlaybackStreamTransport>[
      PlaybackStreamTransport.muxed,
      PlaybackStreamTransport.audioOnly,
      PlaybackStreamTransport.hlsMuxed,
      PlaybackStreamTransport.hlsAudioOnly,
      PlaybackStreamTransport.hlsVideoOnly,
    ];

int? _candidateVideoHeight(PlaybackStreamCandidate candidate) {
  return candidate.videoHeight ?? _parseVideoHeight(candidate.qualityLabel);
}

bool _isVideoTransport(PlaybackStreamTransport transport) {
  switch (transport) {
    case PlaybackStreamTransport.muxed:
    case PlaybackStreamTransport.hlsMuxed:
    case PlaybackStreamTransport.hlsVideoOnly:
      return true;
    case PlaybackStreamTransport.audioOnly:
    case PlaybackStreamTransport.hlsAudioOnly:
    case PlaybackStreamTransport.localFile:
    case PlaybackStreamTransport.cachedFile:
    case PlaybackStreamTransport.directUrl:
      return false;
  }
}

int? _parseVideoHeight(String? qualityLabel) {
  if (qualityLabel == null || qualityLabel.trim().isEmpty) {
    return null;
  }
  final RegExpMatch? match = RegExp(
    r'(\d{3,4})\s*p',
    caseSensitive: false,
  ).firstMatch(qualityLabel);
  if (match == null) {
    return null;
  }
  return int.tryParse(match.group(1)!);
}

String? _containerNameForPath(String value) {
  final Uri? uri = Uri.tryParse(value);
  final String path = uri?.path ?? value;
  final String extension = p.extension(path).replaceFirst('.', '').trim();
  return extension.isEmpty ? null : extension.toLowerCase();
}
