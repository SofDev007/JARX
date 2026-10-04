import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarx/api.dart';
import 'package:jarx/db.dart';

/// Answers every request with [handler], recording what was sent.
class _FakeServer implements HttpClientAdapter {
  _FakeServer(this.handler);
  ResponseBody Function(RequestOptions) handler;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? body, Future<void>? cancel) async {
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object body, [int status = 200]) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

Never _offline(RequestOptions o) => throw DioException.connectionError(requestOptions: o, reason: 'no network');

const _track = {
  'id': 'archive:item/My Song #1.mp3',
  'source': 'archive',
  'sourceId': 'item/My Song #1.mp3',
  'title': 'My Song',
  'artist': 'Someone',
  'album': null,
  'artworkUrl': null,
  'durationMs': 1000,
  'streamUrl': 'https://archive.org/download/item/My%20Song%20%231.mp3',
  'mbid': null,
  'playable': true,
  'deepLink': null,
};

void main() {
  late Cache cache;
  setUp(() => cache = Cache(NativeDatabase.memory()));
  tearDown(() => cache.close());

  test('Track round-trips the backend model, including mbid and playable', () {
    final t = Track.fromJson(_track);
    expect(t.id, 'archive:item/My Song #1.mp3');
    expect(t.toJson(), {..._track}..remove('id')); // the backend derives id itself
  });

  test('reads stored import placeholders as-is and ignores fields it does not know yet', () {
    final t = Track.fromJson({
      'id': 'youtube:search:Blinding Lights The Weeknd',
      'source': 'youtube',
      'sourceId': 'search:Blinding Lights The Weeknd',
      'title': 'Blinding Lights',
      'artist': 'The Weeknd',
      'album': 'After Hours',
      'artworkUrl': null,
      'durationMs': 200040,
      'streamUrl': null,
      'mbid': null,
      'playable': false,
      'deepLink': 'https://www.youtube.com/results?search_query=Blinding%20Lights%20The%20Weeknd',
      'sources': [{'provider': 'youtube', 'playback': 'embed'}], // the kind of field a later backend may add
    });
    expect(t.id, 'youtube:search:Blinding Lights The Weeknd');
    expect(t.playable, isFalse);
    expect(t.deepLink, startsWith('https://www.youtube.com/results?'));
  });

  test('sends the bearer token to the deployed backend', () async {
    final server = _FakeServer(
      (_) => _json({'query': 'x', 'music': [_track], 'videos': [], 'videoError': null, 'results': [_track], 'cached': false}),
    );
    final results = await Api(cache, adapter: server).search('lofi');

    expect(results.music.single.title, 'My Song');
    final sent = server.requests.single;
    expect(sent.uri.toString(), startsWith('https://jarx-backend.jarx-backend.workers.dev/search?'));
    expect(sent.headers['Authorization'], startsWith('Bearer '));
  });

  test('search keeps music and YouTube videos apart, and passes on why videos are missing', () async {
    const video = {
      'source': 'youtube',
      'sourceId': '4NRXx6U8ABQ',
      'title': 'Blinding Lights',
      'artist': 'TheWeekndVEVO',
      'playable': false,
      'deepLink': 'https://www.youtube.com/watch?v=4NRXx6U8ABQ',
    };
    final server = _FakeServer(
      (_) => _json({'music': [_track], 'videos': [video], 'videoError': null, 'results': [_track, video]}),
    );
    final r = await Api(cache, adapter: server).search('x');
    expect(r.music.map((t) => t.id), ['archive:item/My Song #1.mp3']); // not the merged `results`
    expect(r.videos.single, isA<Track>().having((t) => t.id, 'id', 'youtube:4NRXx6U8ABQ').having((t) => t.playable, 'playable', false));
    expect(r.videoError, isNull);

    server.handler = (_) => _json({'music': [_track], 'videos': [], 'videoError': 'quota_exceeded', 'results': [_track]});
    expect((await Api(cache, adapter: server).search('x')).videoError, 'quota_exceeded');
  });

  test("turns the backend's error body into its message", () async {
    final server = _FakeServer((_) => _json({'error': {'code': 'not_found', 'message': 'Track not found'}}, 404));
    await expectLater(
      Api(cache, adapter: server).streamUrl(Track.fromJson(_track)),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'not_found').having((e) => e.message, 'message', 'Track not found')),
    );
  });

  test('encodes archive ids segment by segment, keeping the slashes', () async {
    final server = _FakeServer((_) => _json({'url': 'https://x'}));
    await Api(cache, adapter: server).streamUrl(Track.fromJson(_track));
    expect(server.requests.single.uri.path, '/tracks/archive/item/My%20Song%20%231.mp3/stream');
  });

  test('offline, the library falls back to its last good copy; with no copy it reports offline', () async {
    final server = _FakeServer((_) => _json({'items': [{'track': _track, 'addedAt': 1}]}));
    final api = Api(cache, adapter: server);
    expect((await api.favorites()).single.title, 'My Song');

    server.handler = _offline;
    expect((await api.favorites()).single.title, 'My Song');
    await expectLater(api.playlists(), throwsA(isA<ApiException>().having((e) => e.offline, 'offline', true)));
  });

  test('import chunks continue the first chunk\'s playlist', () async {
    final server = _FakeServer((o) => _json({
      'playlistId': 'p1',
      'name': 'Mix',
      'matched': 1,
      'unmatched': [{'line': 2, 'title': 'Gone', 'artist': 'Nobody', 'reason': 'no_match'}],
    }, 201));
    final api = Api(cache, adapter: server);

    final r = await api.importChunk('a - b\nGone - Nobody', name: 'Mix');
    await api.importChunk('c - d', name: 'Mix', playlistId: r.playlistId);

    expect(r.unmatched, ['Gone — Nobody']);
    expect(server.requests[0].uri.queryParameters, {'name': 'Mix'});
    expect(server.requests[1].uri.queryParameters, {'name': 'Mix', 'playlistId': 'p1'});
    expect(server.requests[1].data, 'c - d');
  });

  group('importChunks', () {
    test('splits plain text lines, dropping blanks', () {
      final text = [for (var i = 0; i < 45; i++) 'Song $i - Artist', '', '  '].join('\n');
      final chunks = importChunks(text);
      expect(chunks.map((c) => c.split('\n').length), [20, 20, 5]);
      expect(chunks.first.split('\n').first, 'Song 0 - Artist');
    });

    test('repeats an Exportify header on every chunk', () {
      const header = '"Track URI","Track Name","Artist Name(s)"';
      final text = [header, for (var i = 0; i < 25; i++) '"u","Song $i","A"'].join('\r\n');
      final chunks = importChunks(text);
      expect(chunks, hasLength(2));
      for (final c in chunks) {
        expect(c.split('\n').first, header);
      }
      expect(chunks.last.split('\n'), hasLength(1 + 5));
    });

    test('an empty file has nothing to send', () {
      expect(importChunks('\n\n  \n'), isEmpty);
    });
  });
}
