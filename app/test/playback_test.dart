import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarx/api.dart';
import 'package:jarx/db.dart';
import 'package:jarx/playback.dart';

import 'fakes.dart';

Matcher _code(String code) => throwsA(isA<PlaybackException>().having((e) => e.code, 'code', code));

void main() {
  final now = DateTime.utc(2026, 10, 5, 12);
  int at(Duration d) => now.add(d).millisecondsSinceEpoch;

  group('TrackRef', () {
    test('splits a Track.id at its first colon', () {
      expect(trackRef('audius:95wro'), (source: 'audius', sourceId: '95wro'));
      expect(trackRef('archive:item/My Song.mp3'), (source: 'archive', sourceId: 'item/My Song.mp3'));
      expect(trackRef('youtube:search:Blinding Lights'), (source: 'youtube', sourceId: 'search:Blinding Lights'));
      expect(trackRef(song('a').id), (source: 'audius', sourceId: 'a'));
    });

    test('rejects anything that is not provider:id', () {
      for (final id in ['nocolon', ':x', 'x:', '']) {
        expect(() => trackRef(id), _code('invalid_source'), reason: id);
      }
    });
  });

  group('QualitySelector', () {
    PlayableSource pick(List<StreamCandidate> c, [QualityPreference pref = QualityPreference.best]) =>
        QualitySelector.pick(c, pref: pref, now: now);
    StreamCandidate kbps(int? rate, [String name = '']) =>
        StreamCandidate('https://cdn.example/${rate ?? 'unknown'}$name.mp3', bitrateKbps: rate);
    String chosen(List<StreamCandidate> c, [QualityPreference pref = QualityPreference.best]) => pick(c, pref).uri.path;

    test('best takes the highest known bitrate, dataSaver the lowest', () {
      final c = [kbps(128), kbps(320), kbps(96)];
      expect(chosen(c), '/320.mp3');
      expect(chosen(c, QualityPreference.dataSaver), '/96.mp3');
    });

    test('puts unknown bitrates after known ones, whatever the preference', () {
      final c = [kbps(null, 'a'), kbps(128), kbps(null, 'b')];
      expect(chosen(c), '/128.mp3');
      expect(chosen(c, QualityPreference.dataSaver), '/128.mp3');
      expect(chosen([kbps(null, 'a'), kbps(null, 'b')]), '/unknowna.mp3');
    });

    test('keeps the provider order on ties', () {
      expect(chosen([kbps(128), kbps(320, 'first'), kbps(320, 'second')]), '/320first.mp3');
      expect(chosen([kbps(96, 'first'), kbps(96, 'second'), kbps(320)], QualityPreference.dataSaver), '/96first.mp3');
    });

    test('skips candidates that expire within the safety margin', () {
      final soon = StreamCandidate('https://cdn.example/soon.mp3', bitrateKbps: 320, expiresAt: at(const Duration(seconds: 10)));
      final later = StreamCandidate('https://cdn.example/later.mp3', bitrateKbps: 128, expiresAt: at(const Duration(minutes: 5)));
      const forever = StreamCandidate('https://cdn.example/forever.mp3', bitrateKbps: 64);
      expect(chosen([soon, later, forever]), '/later.mp3');
      expect(chosen([soon, forever]), '/forever.mp3');
      final edge = StreamCandidate('https://cdn.example/edge.mp3', expiresAt: at(QualitySelector.expiryMargin));
      expect(() => pick([soon, edge]), _code('no_stream'));
    });

    test('drops invalid URIs and schemes other than https, content and file', () {
      final bad = [
        for (final u in ['not a uri', 'https://', 'http://cdn.example/a.mp3', 'ftp://cdn.example/a.mp3', 'data:audio/mpeg;base64,AA', 'file://'])
          StreamCandidate(u),
      ];
      expect(() => pick(bad), _code('no_stream'));
      expect(chosen([...bad, kbps(128)]), '/128.mp3');
    });

    test('accepts https, content and file URIs', () {
      for (final u in ['https://cdn.example/a.mp3', 'content://media/external/audio/media/42', 'file:///sdcard/Music/a.mp3']) {
        expect(pick([StreamCandidate(u)]).uri, Uri.parse(u));
      }
    });

    test('has nothing to play without candidates', () {
      expect(() => pick([]), _code('no_stream'));
    });

    test('passes headers on only when there are some', () {
      expect(pick([const StreamCandidate('https://cdn.example/a.mp3', headers: {})]).headers, isNull);
      expect(pick([const StreamCandidate('https://cdn.example/a.mp3')]).headers, isNull);
      expect(pick([const StreamCandidate('https://cdn.example/a.mp3', headers: {'Referer': 'https://x'})]).headers, {'Referer': 'https://x'});
    });
  });

  group('SourceResolver', () {
    late Cache cache;
    late FakeServer server;
    late DateTime clock;

    ResponseBody backend(RequestOptions o) {
      final stream = RegExp(r'^/tracks/audius/(.+)/stream$').firstMatch(o.uri.path);
      return stream != null ? json({'url': 'https://fresh.example/${stream[1]}.mp3'}) : apiError(404, 'not_found', 'Route not found');
    }

    SourceResolver resolver({Future<List<StreamCandidate>> Function(Track)? streams}) =>
        SourceResolver(Api(cache, adapter: server), streams: streams, now: () => clock);

    setUp(() {
      cache = Cache(NativeDatabase.memory());
      server = FakeServer(backend);
      clock = now;
    });
    tearDown(() => cache.close());

    test('asks the server on a miss, then answers from its cache', () async {
      final r = resolver();
      expect((await r.resolve(song('a'))).uri, Uri.parse('https://fresh.example/a.mp3'));
      expect((await r.resolve(song('a'))).uri, Uri.parse('https://fresh.example/a.mp3'));
      expect(server.calls, ['GET /tracks/audius/a/stream']);
    });

    test('tries a stored stream URL once as a legacy hint, then only the server', () async {
      final r = resolver();
      final t = song('a', streamUrl: 'https://cdn.example/stored.mp3');
      expect((await r.resolve(t)).uri, Uri.parse('https://cdn.example/stored.mp3'));
      expect(server.calls, isEmpty);

      r.invalidate(t);
      expect((await r.resolve(t)).uri, Uri.parse('https://fresh.example/a.mp3'));
      r.invalidate(t);
      expect((await r.resolve(t)).uri, Uri.parse('https://fresh.example/a.mp3')); // the hint isn't reused
      expect(server.calls, hasLength(2));
    });

    test('falls back to the server when the stored URL is unusable', () async {
      final r = resolver();
      expect((await r.resolve(song('a', streamUrl: 'http://insecure.example/a.mp3'))).uri, Uri.parse('https://fresh.example/a.mp3'));
    });

    test('resolves again once the cached candidate is about to expire', () async {
      var fetches = 0;
      // Each answer is good for 60s from when it was fetched.
      final r = resolver(
        streams: (_) async => [
          StreamCandidate('https://cdn.example/a.mp3?v=${++fetches}', expiresAt: clock.add(const Duration(seconds: 60)).millisecondsSinceEpoch),
        ],
      );
      expect((await r.resolve(song('a'))).uri.query, 'v=1');
      clock = now.add(const Duration(seconds: 20)); // 40s left: still cached
      expect((await r.resolve(song('a'))).uri.query, 'v=1');
      clock = now.add(const Duration(seconds: 35)); // 25s left: inside the margin
      expect((await r.resolve(song('a'))).uri.query, 'v=2');
    });

    test('invalidate makes the next resolve ask again', () async {
      final r = resolver();
      await r.resolve(song('a'));
      r.invalidate(song('a'));
      await r.resolve(song('a'));
      expect(server.calls, hasLength(2));
    });

    test('turns backend answers into typed errors, keeping their message', () async {
      for (final (status, backendCode, message, code) in [
        (422, 'not_playable', 'YouTube tracks are metadata-only; open the deep link', 'not_playable'),
        (404, 'not_found', 'Track not found', 'no_stream'),
        (502, 'upstream_error', 'Could not resolve a stream from audius', 'unavailable'),
        (400, 'invalid_request', 'Request validation failed', 'invalid_source'),
      ]) {
        server.handler = (_) => apiError(status, backendCode, message);
        await expectLater(
          resolver().resolve(song('a')),
          throwsA(isA<PlaybackException>().having((e) => e.code, 'code', code).having((e) => e.message, 'message', message)),
        );
      }
      server.handler = (o) => throw DioException.connectionError(requestOptions: o, reason: 'no network');
      await expectLater(resolver().resolve(song('a')), _code('unavailable'));
    });

    test('refuses non-playable and malformed tracks without asking anyone', () async {
      final r = resolver();
      await expectLater(r.resolve(song('v', source: 'youtube', playable: false)), _code('not_playable'));
      await expectLater(r.resolve(Track(source: '', sourceId: 'x', title: 'T', artist: 'A', playable: true)), _code('invalid_source'));
      expect(server.calls, isEmpty);
    });

    test('prefetch warms the cache, and a failed prefetch stays silent', () async {
      final r = resolver();
      r.prefetch(song('a'));
      await settle();
      await r.resolve(song('a'));
      expect(server.calls, ['GET /tracks/audius/a/stream']); // resolve used the prefetched answer

      server.handler = (_) => apiError(502, 'upstream_error', 'down');
      r.prefetch(song('b')); // must not throw
      await settle();
      await expectLater(r.resolve(song('b')), _code('unavailable')); // nothing was cached
    });

    test('hands the player the headers a provider asked for', () async {
      final r = resolver(streams: (_) async => [const StreamCandidate('https://cdn.example/a.mp3', headers: {'Referer': 'https://x'})]);
      expect((await r.resolve(song('a'))).headers, {'Referer': 'https://x'});
    });
  });
}
