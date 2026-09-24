import 'dart:async';
import 'dart:convert';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import 'api.dart';
import 'db.dart';

final playerProvider = Provider<Player>((ref) => throw UnimplementedError('overridden in main()'));

/// Plays tracks with just_audio. audio_service owns the foreground service, the media
/// notification and the lock-screen and headset controls, and routes them back here.
class Player extends BaseAudioHandler with SeekHandler {
  Player(this._api, this._cache) {
    _audio.playbackEventStream.listen((_) => _broadcast(), onError: (Object e, StackTrace _) => _fail(e));
    _audio.playingStream.listen((_) => _broadcast());
    _audio.processingStateStream.listen((s) {
      if (s == ProcessingState.completed) skipToNext();
    });
    // Archive rows often come without a duration; take the real one once it is known.
    _audio.durationStream.listen((d) {
      final item = mediaItem.value;
      if (d != null && item != null && item.duration != d) mediaItem.add(item.copyWith(duration: d));
    });
    // ponytail: saves every 15s while playing, so a killed process resumes up to 15s early.
    Timer.periodic(const Duration(seconds: 15), (_) {
      if (_audio.playing) _save();
    });
  }

  final Api _api;
  final Cache _cache;
  final _audio = AudioPlayer();
  final _errors = StreamController<String>.broadcast();
  List<Track> _tracks = [];
  int _index = 0;
  int _loads = 0; // bumped per load, so a slow load can't clobber a newer one
  bool _loaded = false;
  Duration? _resumeAt; // from restore(): nothing loads until the first play()

  /// One-line messages for the UI to show when a track can't be played.
  Stream<String> get errors => _errors.stream;

  Track? get current => _tracks.isEmpty ? null : _tracks[_index];

  /// Plays [list] from [start]. Non-playable (YouTube) rows are left out of the queue.
  Future<void> playTracks(List<Track> list, int start) async {
    _tracks = [for (final t in list) if (t.playable) t];
    if (_tracks.isEmpty) return;
    _index = list.take(start).where((t) => t.playable).length.clamp(0, _tracks.length - 1);
    queue.add([for (final t in _tracks) _item(t)]);
    await _load(play: true);
  }

  Future<void> _load({required bool play, Duration position = Duration.zero}) async {
    final load = ++_loads;
    final t = _tracks[_index];
    _resumeAt = null;
    _loaded = false;
    mediaItem.add(_item(t));
    _broadcast();
    try {
      // The URL we already have usually works: Jamendo's never expire and Archive's are
      // stable. Only ask the server for a fresh one when it fails (Audius URLs are signed
      // and do expire). This also keeps playback off Jamendo's flaky lookup behind /stream.
      final known = t.streamUrl;
      try {
        final url = known ?? await _api.streamUrl(t);
        if (load != _loads) return;
        await _audio.setUrl(url, initialPosition: position);
      } on PlayerException {
        if (known == null) rethrow;
        final url = await _api.streamUrl(t);
        if (load != _loads) return;
        await _audio.setUrl(url, initialPosition: position);
      }
    } on PlayerInterruptedException {
      return; // a newer load replaced this one
    } catch (e) {
      if (load == _loads) _fail(e);
      return;
    }
    if (load != _loads) return;
    _loaded = true;
    _save();
    if (play) {
      unawaited(_audio.play());
      _api.played(t).ignore(); // history is best-effort
    }
  }

  @override
  Future<void> play() async {
    if (_tracks.isEmpty) return;
    if (!_loaded) return _load(play: true, position: _resumeAt ?? Duration.zero);
    await _audio.play();
  }

  @override
  Future<void> pause() async {
    await _audio.pause();
    _save();
  }

  @override
  Future<void> seek(Duration position) => _audio.seek(position);

  @override
  Future<void> skipToNext() async {
    if (_index + 1 < _tracks.length) {
      _index++;
      return _load(play: true);
    }
    await _audio.pause(); // end of the queue
    await _audio.seek(Duration.zero);
  }

  @override
  Future<void> skipToPrevious() async {
    // Like most players: restart the track unless it has only just started.
    if (_index == 0 || _audio.position > const Duration(seconds: 3)) return _audio.seek(Duration.zero);
    _index--;
    await _load(play: true);
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    if (index < 0 || index >= _tracks.length) return;
    _index = index;
    await _load(play: true);
  }

  @override
  Future<void> stop() async {
    _save();
    await _audio.stop();
    _loaded = false;
    await super.stop();
  }

  /// Puts the last session's queue back, paused where it was.
  Future<void> restore() async {
    final saved = await _cache.getJson('player');
    if (saved == null) return;
    final s = jsonDecode(saved) as Map<String, dynamic>;
    _tracks = [for (final t in s['tracks'] as List) Track.fromJson(t as Map<String, dynamic>)];
    if (_tracks.isEmpty) return;
    _index = (s['index'] as int).clamp(0, _tracks.length - 1);
    _resumeAt = Duration(milliseconds: s['positionMs'] as int);
    queue.add([for (final t in _tracks) _item(t)]);
    mediaItem.add(_item(_tracks[_index]));
    _broadcast();
  }

  void _save() {
    if (_tracks.isEmpty) return;
    final position = _resumeAt ?? _audio.position;
    _cache
        .putJson(
          'player',
          jsonEncode({
            'tracks': [for (final t in _tracks) t.toJson()],
            'index': _index,
            'positionMs': position.inMilliseconds,
          }),
        )
        .ignore();
  }

  void _fail(Object e) => _errors.add(e is ApiException ? e.message : "Couldn't play this track");

  void _broadcast() {
    final playing = _audio.playing;
    playbackState.add(
      playbackState.value.copyWith(
        controls: [MediaControl.skipToPrevious, playing ? MediaControl.pause : MediaControl.play, MediaControl.skipToNext],
        systemActions: const {MediaAction.seek, MediaAction.seekForward, MediaAction.seekBackward},
        // Android 12L and below (API 29-32) build the collapsed notification from these
        // indices; 13+ ignores them. audio_service only applies them when SDK_INT < 33.
        androidCompactActionIndices: const [0, 1, 2],
        processingState: const {
          ProcessingState.idle: AudioProcessingState.idle,
          ProcessingState.loading: AudioProcessingState.loading,
          ProcessingState.buffering: AudioProcessingState.buffering,
          ProcessingState.ready: AudioProcessingState.ready,
          ProcessingState.completed: AudioProcessingState.completed,
        }[_audio.processingState]!,
        playing: playing,
        updatePosition: _resumeAt ?? _audio.position,
        bufferedPosition: _audio.bufferedPosition,
        speed: _audio.speed,
        queueIndex: _tracks.isEmpty ? null : _index,
      ),
    );
  }

  static MediaItem _item(Track t) => MediaItem(
    id: t.id,
    title: t.title,
    artist: t.artist,
    album: t.album,
    artUri: t.artworkUrl == null ? null : Uri.tryParse(t.artworkUrl!),
    duration: t.durationMs == null ? null : Duration(milliseconds: t.durationMs!),
  );
}
