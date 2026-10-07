import 'package:audio_service/audio_service.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarx/api.dart';
import 'package:jarx/db.dart';
import 'package:jarx/playback.dart';
import 'package:jarx/player.dart';
import 'package:just_audio/just_audio.dart';

import 'fakes.dart';

const _stored = 'https://cdn.example/stored.mp3';
Uri _fresh(String id) => Uri.parse('https://fresh.example/audius/$id.mp3');

/// The backend: a fresh stream URL for any track, and history accepted.
ResponseBody _backend(RequestOptions o) {
  final stream = RegExp(r'^/tracks/audius/(.+)/stream$').firstMatch(o.uri.path);
  if (stream != null) return json({'url': '${_fresh(stream[1]!)}'});
  if (o.method == 'POST' && o.uri.path == '/recently-played') return json({}, 201);
  return apiError(404, 'not_found', 'Route not found');
}

/// Records what the player asks of its resolver and answers with [answer].
class _FakeResolver implements SourceResolver {
  final resolved = <String>[];
  final invalidated = <String>[];
  final prefetched = <String>[];
  PlayableSource Function(Track) answer = (t) => PlayableSource(Uri.parse('https://cdn.example/${t.sourceId}.mp3'));

  @override
  Future<PlayableSource> resolve(Track t) async {
    resolved.add(t.sourceId);
    return answer(t);
  }

  @override
  void invalidate(Track t) => invalidated.add(t.sourceId);

  @override
  void prefetch(Track t) => prefetched.add(t.sourceId);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

PlayerException _broken() => PlayerException(0, 'Source error', null);

void main() {
  late Cache cache;
  late FakeServer server;
  late FakeAudio audio;
  late Player player;
  late List<String> errors;

  Player newPlayer() => Player(Api(cache, adapter: server), cache, audio: audio);

  setUp(() {
    cache = Cache(NativeDatabase.memory());
    server = FakeServer(_backend);
    audio = FakeAudio();
    player = newPlayer();
    errors = [];
    player.errors.listen(errors.add);
  });
  tearDown(() => cache.close());

  group('characterization: behavior the playback contract must keep', () {
    test('loads and plays the tapped track, then records it in history', () async {
      await player.playTracks([song('a', streamUrl: _stored)], 0);
      await settle();

      expect(audio.loaded, [Uri.parse(_stored)]);
      expect(audio.playing, isTrue);
      expect(player.mediaItem.value?.id, 'audius:a');
      expect(server.calls, ['POST /recently-played']);
    });

    test('leaves non-playable tracks out of the queue and plays the one tapped', () async {
      await player.playTracks([
        song('v', source: 'youtube', playable: false),
        song('a', streamUrl: 'https://cdn.example/a.mp3'),
        song('b', streamUrl: 'https://cdn.example/b.mp3'),
      ], 2);

      expect(player.queue.value.map((m) => m.id), ['audius:a', 'audius:b']);
      expect(audio.loaded, [Uri.parse('https://cdn.example/b.mp3')]);
    });

    test('does nothing when no track in the list is playable', () async {
      await player.playTracks([song('v', source: 'youtube', playable: false)], 0);
      expect(audio.loaded, isEmpty);
      expect(player.queue.value, isEmpty);
    });

    test('asks the server for a stream when the track carries none', () async {
      await player.playTracks([song('a')], 0);
      expect(server.calls.first, 'GET /tracks/audius/a/stream');
      expect(audio.loaded, [_fresh('a')]);
      expect(audio.playing, isTrue);
    });

    test('reports a failed stream lookup and plays nothing', () async {
      server.handler = (_) => apiError(502, 'upstream_error', 'Could not resolve a stream from audius');
      await player.playTracks([song('a')], 0);
      await settle();

      expect(errors, ['Could not resolve a stream from audius']);
      expect(audio.loaded, isEmpty);
      expect(audio.playing, isFalse);
      expect(server.calls, isNot(contains('POST /recently-played')));
    });

    test('when a stream fails to load, gets a fresh one from the server and retries once', () async {
      audio.failures.add(PlayerException(0, 'Source error', null));
      await player.playTracks([song('a', streamUrl: _stored)], 0);

      expect(audio.loaded, [Uri.parse(_stored), _fresh('a')]);
      expect(server.calls.first, 'GET /tracks/audius/a/stream');
      expect(audio.playing, isTrue);
    });

    test('moves on when a track ends, and stops at the end of the queue', () async {
      await player.playTracks([song('a'), song('b')], 0);
      audio.complete();
      await settle();
      expect(audio.loaded.last, _fresh('b'));
      expect(player.playbackState.value.queueIndex, 1);

      audio.complete();
      await settle();
      expect(audio.loaded, hasLength(2)); // nothing after b
      expect(audio.playing, isFalse);
      expect(audio.seeks.last, Duration.zero);
    });

    test('previous goes back a track near its start, and queue taps jump', () async {
      await player.playTracks([song('a'), song('b'), song('c')], 1);
      await player.skipToPrevious();
      expect(audio.loaded.last, _fresh('a'));

      await player.skipToQueueItem(2);
      expect(audio.loaded.last, _fresh('c'));
      expect(player.playbackState.value.queueIndex, 2);
    });

    test('publishes what the notification and lock screen need', () async {
      await player.playTracks([song('a')], 0);
      await settle();

      final state = player.playbackState.value;
      expect(state.controls, [MediaControl.skipToPrevious, MediaControl.pause, MediaControl.skipToNext]);
      expect(state.androidCompactActionIndices, [0, 1, 2]);
      expect(state.playing, isTrue);
      expect(state.queueIndex, 0);
      expect(player.mediaItem.value?.title, 'Song a');
    });

    test('restores the saved queue paused, then resumes it on play', () async {
      await player.playTracks([song('a'), song('b')], 1);
      await settle();
      final loads = audio.loaded.length;

      final restored = newPlayer();
      await restored.restore();
      expect(restored.queue.value.map((m) => m.id), ['audius:a', 'audius:b']);
      expect(restored.mediaItem.value?.id, 'audius:b');
      expect(audio.loaded, hasLength(loads)); // restoring loads nothing

      await restored.play();
      expect(audio.loaded.last, _fresh('b'));
      expect(audio.startPositions.last, Duration.zero);
    });
  });

  group('playback contract', () {
    late _FakeResolver resolver;

    setUp(() {
      resolver = _FakeResolver();
      player = Player(Api(cache, adapter: server), cache, resolver: resolver, audio: audio);
      player.errors.listen(errors.add);
    });

    test('plays exactly the PlayableSource it is given, content URIs and headers included', () async {
      resolver.answer = (_) => PlayableSource(Uri.parse('content://media/external/audio/media/42'));
      await player.playTracks([song('a')], 0);
      expect(audio.loaded, [Uri.parse('content://media/external/audio/media/42')]);
      expect(audio.loadedHeaders, [null]);

      resolver.answer = (_) => PlayableSource(Uri.parse('https://cdn.example/b.mp3'), headers: {'Referer': 'https://x'});
      await player.playTracks([song('b')], 0);
      expect(audio.loadedHeaders.last, {'Referer': 'https://x'});
    });

    test('after a load fails, invalidates, resolves once more and plays', () async {
      audio.failures.add(_broken());
      await player.playTracks([song('a')], 0);

      expect(resolver.resolved, ['a', 'a']);
      expect(resolver.invalidated, ['a']);
      expect(audio.playing, isTrue);
      expect(errors, isEmpty);
    });

    test('after a second failure, reports it and moves to the next track', () async {
      audio.failures.addAll([_broken(), _broken()]);
      await player.playTracks([song('a'), song('b')], 0);
      await settle();

      expect(resolver.resolved, ['a', 'a', 'b']);
      expect(errors, ["Couldn't play this track"]);
      expect(player.playbackState.value.queueIndex, 1);
      expect(audio.playing, isTrue);
    });

    test('retries each track at most once, even when every track fails', () async {
      audio.failures.addAll(List.generate(10, (_) => _broken()));
      await player.playTracks([song('a'), song('b')], 0);

      expect(resolver.resolved, ['a', 'a', 'b', 'b']); // two tries each, then the queue ends
      expect(audio.failures, hasLength(6));
      expect(audio.playing, isFalse);
    });

    test("keeps a track it can't resolve, showing why, instead of skipping", () async {
      resolver.answer = (_) => throw const PlaybackException('unavailable', "Can't reach the JARX server");
      await player.playTracks([song('a'), song('b')], 0);
      await settle(); // errors is a broadcast stream

      expect(errors, ["Can't reach the JARX server"]);
      expect(player.playbackState.value.queueIndex, 0);
      expect(resolver.invalidated, isEmpty);
      expect(audio.loaded, isEmpty);
    });

    test('prefetches the next track once the current one is set up, never past the end', () async {
      await player.playTracks([song('a'), song('b'), song('c')], 0);
      expect(resolver.prefetched, ['b']);

      await player.skipToQueueItem(2);
      expect(resolver.prefetched, ['b']); // c is last
    });

    test('never asks the resolver about non-playable tracks', () async {
      await player.playTracks([song('v', source: 'youtube', playable: false), song('a')], 1);
      expect(resolver.resolved, ['a']);
    });
  });
}
