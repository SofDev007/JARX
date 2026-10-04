import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'db.dart';

/// The deployed Worker. Override with --dart-define=JARX_URL=... to point elsewhere.
const baseUrl = String.fromEnvironment(
  'JARX_URL',
  defaultValue: 'https://jarx-backend.jarx-backend.workers.dev',
);

/// Compiled in from app/.env (gitignored) via `--dart-define-from-file=.env`.
const token = String.fromEnvironment('JARX_TOKEN');

/// Mirrors the backend's normalized track model field for field.
class Track {
  const Track({
    required this.source,
    required this.sourceId,
    required this.title,
    required this.artist,
    this.album,
    this.artworkUrl,
    this.durationMs,
    this.streamUrl,
    this.mbid,
    required this.playable,
    this.deepLink,
  });

  final String source, sourceId, title, artist;
  final String? album, artworkUrl, streamUrl, mbid, deepLink;
  final int? durationMs;

  /// False for every YouTube row: those are metadata only and open the YouTube app.
  final bool playable;

  String get id => '$source:$sourceId';

  factory Track.fromJson(Map<String, dynamic> j) => Track(
    source: j['source'] as String,
    sourceId: j['sourceId'] as String,
    title: j['title'] as String,
    artist: j['artist'] as String? ?? '',
    album: j['album'] as String?,
    artworkUrl: j['artworkUrl'] as String?,
    durationMs: j['durationMs'] as int?,
    streamUrl: j['streamUrl'] as String?,
    mbid: j['mbid'] as String?,
    playable: j['playable'] == true,
    deepLink: j['deepLink'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'source': source,
    'sourceId': sourceId,
    'title': title,
    'artist': artist,
    'album': album,
    'artworkUrl': artworkUrl,
    'durationMs': durationMs,
    'streamUrl': streamUrl,
    'mbid': mbid,
    'playable': playable,
    'deepLink': deepLink,
  };
}

/// The backend's `{ error: { code, message } }`, or `offline` when it can't be reached.
class ApiException implements Exception {
  const ApiException(this.code, this.message);
  final String code, message;

  bool get offline => code == 'offline';

  @override
  String toString() => message;
}

/// A search answer: music JARX plays, and YouTube videos, which play only in YouTube.
/// [videoError] says why [videos] is empty when YouTube failed: `quota_exceeded` or `unavailable`.
typedef SearchAnswer = ({List<Track> music, List<Track> videos, String? videoError});

class PlaylistSummary {
  const PlaylistSummary(this.id, this.name, this.trackCount);
  final String id, name;
  final int trackCount;
}

class Playlist {
  const Playlist(this.id, this.name, this.tracks);
  final String id, name;

  /// In playlist order; a track's index is its server-side position.
  final List<Track> tracks;
}

class ImportResult {
  const ImportResult(this.playlistId, this.matched, this.unmatched);
  final String playlistId;
  final int matched;

  /// "title — artist" for each row that had no playable match.
  final List<String> unmatched;
}

class Api {
  /// [adapter] replaces the network in tests; everything else is the real configuration.
  Api(this._cache, {HttpClientAdapter? adapter})
    : _dio = Dio(
        BaseOptions(
          baseUrl: baseUrl,
          headers: {'Authorization': 'Bearer $token'},
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 60), // imports resolve rows server-side
        ),
      ) {
    if (adapter != null) _dio.httpClientAdapter = adapter;
  }

  final Dio _dio;
  final Cache _cache;

  Future<SearchAnswer> search(String q) => _call(
    () => _dio.get('/search', queryParameters: {'q': q, 'limit': 25}),
    (d) => (music: _tracks(d['music']), videos: _tracks(d['videos']), videoError: d['videoError'] as String?),
  );

  /// A fresh stream URL. Archive ids contain slashes, so each segment is encoded on its own.
  Future<String> streamUrl(Track t) => _call(
    () => _dio.get('/tracks/${t.source}/${t.sourceId.split('/').map(Uri.encodeComponent).join('/')}/stream'),
    (d) => d['url'] as String,
  );

  Future<List<PlaylistSummary>> playlists() async => [
    for (final p in (await _cachedGet('/playlists'))['playlists'])
      PlaylistSummary(p['id'] as String, p['name'] as String, p['trackCount'] as int),
  ];

  Future<Playlist> playlist(String id) async {
    final d = await _cachedGet('/playlists/$id');
    return Playlist(d['id'] as String, d['name'] as String, [
      for (final e in d['tracks']) Track.fromJson(e['track'] as Map<String, dynamic>),
    ]);
  }

  Future<List<Track>> favorites() async => [
    for (final e in (await _cachedGet('/favorites'))['items']) Track.fromJson(e['track'] as Map<String, dynamic>),
  ];

  Future<List<Track>> recents() async => [
    for (final e in (await _cachedGet('/recently-played'))['items']) Track.fromJson(e['track'] as Map<String, dynamic>),
  ];

  Future<String> createPlaylist(String name) =>
      _call(() => _dio.post('/playlists', data: {'name': name}), (d) => d['id'] as String);

  Future<void> renamePlaylist(String id, String name) =>
      _call(() => _dio.patch('/playlists/$id', data: {'name': name}), (_) {});

  Future<void> deletePlaylist(String id) => _call(() => _dio.delete('/playlists/$id'), (_) {});

  Future<void> addTracks(String id, List<Track> tracks) => _call(
    () => _dio.post('/playlists/$id/tracks', data: {'tracks': [for (final t in tracks) t.toJson()]}),
    (_) {},
  );

  Future<void> removeTrack(String id, int position) =>
      _call(() => _dio.delete('/playlists/$id/tracks/$position'), (_) {});

  /// [to] is the track's final index, as the backend expects.
  Future<void> reorder(String id, int from, int to) =>
      _call(() => _dio.post('/playlists/$id/reorder', data: {'from': from, 'to': to}), (_) {});

  Future<void> favorite(Track t) => _call(() => _dio.post('/favorites', data: {'track': t.toJson()}), (_) {});

  Future<void> unfavorite(Track t) => _call(() => _dio.delete('/favorites/${Uri.encodeComponent(t.id)}'), (_) {});

  Future<void> played(Track t) => _call(() => _dio.post('/recently-played', data: {'track': t.toJson()}), (_) {});

  /// Imports one chunk from [importChunks]. Pass the first chunk's playlistId to the rest,
  /// so they all land in one playlist.
  Future<ImportResult> importChunk(String text, {required String name, String? playlistId}) => _call(
    () => _dio.post(
      '/import/playlist',
      queryParameters: {'name': name, 'playlistId': ?playlistId},
      data: text,
      options: Options(contentType: 'text/plain'),
    ),
    (d) => ImportResult(d['playlistId'] as String, d['matched'] as int, [
      for (final u in d['unmatched']) [u['title'], u['artist']].where((s) => '$s'.isNotEmpty).join(' — '),
    ]),
  );

  Future<T> _call<T>(Future<Response<dynamic>> Function() send, T Function(dynamic data) parse) async {
    try {
      return parse((await send()).data);
    } on DioException catch (e) {
      throw _error(e);
    }
  }

  /// Network first. When the server can't be reached, the last good copy from [Cache].
  Future<dynamic> _cachedGet(String path) async {
    try {
      final data = (await _dio.get(path)).data;
      await _cache.putJson(path, jsonEncode(data));
      return data;
    } on DioException catch (e) {
      final err = _error(e);
      final saved = err.offline ? await _cache.getJson(path) : null;
      if (saved == null) throw err;
      return jsonDecode(saved);
    }
  }

  static ApiException _error(DioException e) {
    final body = e.response?.data;
    final err = body is Map ? body['error'] : null;
    if (err is Map) return ApiException('${err['code']}', '${err['message']}');
    if (e.response == null) return const ApiException('offline', "Can't reach the JARX server");
    return ApiException('http_${e.response!.statusCode}', 'Server error ${e.response!.statusCode}');
  }

  static List<Track> _tracks(dynamic list) => [
    for (final t in list as List) Track.fromJson(t as Map<String, dynamic>),
  ];
}

/// Splits an import file into request-sized chunks. Each row costs the backend ~2 upstream
/// requests and the Workers Free plan allows 50 per request, so [size] leaves headroom for
/// host failovers. An Exportify CSV keeps its header on every chunk, because the server
/// detects the format from it.
List<String> importChunks(String text, {int size = 20}) {
  final lines = const LineSplitter().convert(text).where((l) => l.trim().isNotEmpty).toList();
  if (lines.isEmpty) return const [];
  final header = lines.first.contains('Track Name') ? lines.removeAt(0) : null;
  return [
    for (var i = 0; i < lines.length; i += size)
      [?header, ...lines.skip(i).take(size)].join('\n'),
  ];
}

final apiProvider = Provider<Api>((ref) => throw UnimplementedError('overridden in main()'));

final searchProvider = FutureProvider.autoDispose.family<SearchAnswer, String>(
  (ref, q) => ref.watch(apiProvider).search(q),
);
final playlistsProvider = FutureProvider.autoDispose((ref) => ref.watch(apiProvider).playlists());
final playlistProvider = FutureProvider.autoDispose.family<Playlist, String>(
  (ref, id) => ref.watch(apiProvider).playlist(id),
);
final favoritesProvider = FutureProvider.autoDispose((ref) => ref.watch(apiProvider).favorites());
final recentsProvider = FutureProvider.autoDispose((ref) => ref.watch(apiProvider).recents());
