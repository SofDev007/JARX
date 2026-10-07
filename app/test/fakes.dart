import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:just_audio/just_audio.dart';
import 'package:jarx/api.dart';

/// Answers every request with [handler], recording what was sent.
class FakeServer implements HttpClientAdapter {
  FakeServer(this.handler);
  ResponseBody Function(RequestOptions) handler;
  final requests = <RequestOptions>[];

  /// Paths of the requests made so far, e.g. `GET /tracks/audius/a/stream`.
  List<String> get calls => [for (final r in requests) '${r.method} ${r.uri.path}'];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? body, Future<void>? cancel) async {
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody json(Object body, [int status = 200]) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

/// The backend's error body.
ResponseBody apiError(int status, String code, String message) => json({
  'error': {'code': code, 'message': message},
}, status);

Track song(String id, {String? streamUrl, bool playable = true, String source = 'audius'}) => Track(
  source: source,
  sourceId: id,
  title: 'Song $id',
  artist: 'Artist',
  playable: playable,
  streamUrl: streamUrl,
);

/// Stands in for just_audio: records what it was asked to load and play, and fails a load
/// when [failures] holds an error for it. Anything else the player touches is unsupported.
class FakeAudio implements AudioPlayer {
  final loaded = <Uri>[];
  final loadedHeaders = <Map<String, String>?>[];
  final startPositions = <Duration?>[];
  final seeks = <Duration?>[];

  /// Errors to throw from the next loads, in order.
  final failures = <Object>[];

  final _playing = StreamController<bool>.broadcast();
  final _processing = StreamController<ProcessingState>.broadcast();
  bool _isPlaying = false;

  Future<Duration?> _load(Uri uri, Map<String, String>? headers, Duration? initialPosition) async {
    loaded.add(uri);
    loadedHeaders.add(headers);
    startPositions.add(initialPosition);
    if (failures.isNotEmpty) throw failures.removeAt(0);
    return null;
  }

  /// Simulates the current track playing to its end.
  void complete() => _processing.add(ProcessingState.completed);

  @override
  Future<Duration?> setUrl(
    String url, {
    Map<String, String>? headers,
    Duration? initialPosition,
    bool preload = true,
    dynamic tag,
  }) => _load(Uri.parse(url), headers, initialPosition);

  @override
  Future<Duration?> setAudioSource(
    AudioSource audioSource, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
  }) {
    final source = audioSource as UriAudioSource;
    return _load(source.uri, source.headers, initialPosition);
  }

  @override
  Future<void> play() async {
    _isPlaying = true;
    _playing.add(true);
  }

  @override
  Future<void> pause() async {
    _isPlaying = false;
    _playing.add(false);
  }

  @override
  Future<void> stop() async => pause();

  @override
  Future<void> seek(Duration? position, {int? index}) async => seeks.add(position);

  @override
  bool get playing => _isPlaying;
  @override
  ProcessingState get processingState => ProcessingState.ready;
  @override
  Duration get position => Duration.zero;
  @override
  Duration get bufferedPosition => Duration.zero;
  @override
  double get speed => 1;
  @override
  Stream<bool> get playingStream => _playing.stream;
  @override
  Stream<ProcessingState> get processingStateStream => _processing.stream;
  @override
  Stream<PlaybackEvent> get playbackEventStream => const Stream.empty();
  @override
  Stream<Duration?> get durationStream => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Lets queued async work (listeners, history posts, cache writes) run.
Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
