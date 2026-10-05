import 'api.dart';

/// A track at its provider: [source] is the provider id, [sourceId] the provider's own id.
/// Its string form is Track.id, `<source>:<sourceId>`. Never holds a stream URL.
typedef TrackRef = ({String source, String sourceId});

/// Splits a Track.id at its first ':'. Provider ids never contain one; source ids may
/// (`archive:item/a.mp3`, `youtube:search:<query>`).
TrackRef trackRef(String id) {
  final at = id.indexOf(':');
  if (at <= 0 || at == id.length - 1) throw PlaybackException('invalid_source', 'Not a track id: $id');
  return (source: id.substring(0, at), sourceId: id.substring(at + 1));
}

/// Why a track couldn't be resolved for playback.
class PlaybackException implements Exception {
  const PlaybackException(this.code, this.message);

  /// `not_playable`, `no_stream`, `unavailable` or `invalid_source`.
  final String code;
  final String message;

  @override
  String toString() => message;
}

/// One way a provider can stream a track.
class StreamCandidate {
  const StreamCandidate(this.uri, {this.mimeType, this.bitrateKbps, this.expiresAt, this.headers});
  final String uri;
  final String? mimeType;
  final int? bitrateKbps;

  /// Epoch milliseconds; null when the provider gives no expiry.
  final int? expiresAt;
  final Map<String, String>? headers;
}

/// What the player plays, and all it learns about a source.
class PlayableSource {
  const PlayableSource(this.uri, {this.headers});
  final Uri uri;

  /// Null, never empty, when there are none: just_audio sends any headers through a local
  /// plain-HTTP proxy, which this app doesn't allow.
  final Map<String, String>? headers;
}

enum QualityPreference { best, dataSaver }

/// Chooses which candidate to play. Knows nothing about providers.
abstract final class QualitySelector {
  /// A candidate this close to expiring is skipped, so it can't run out mid-load.
  static const expiryMargin = Duration(seconds: 30);
  static const _schemes = {'https', 'content', 'file'};

  /// best: highest known bitrate first; dataSaver: lowest. Unknown bitrates come after known
  /// ones, and ties keep the provider's order.
  static PlayableSource pick(
    List<StreamCandidate> candidates, {
    QualityPreference pref = QualityPreference.best,
    required DateTime now,
  }) {
    final deadline = now.add(expiryMargin).millisecondsSinceEpoch;
    final usable = [
      for (final c in candidates)
        if (_uri(c) case final uri? when c.expiresAt == null || c.expiresAt! > deadline) (c, uri),
    ];
    if (usable.isEmpty) throw const PlaybackException('no_stream', 'No playable stream for this track');
    final ordered = [...usable.indexed]
      ..sort((a, b) {
        final (x, y) = (a.$2.$1.bitrateKbps, b.$2.$1.bitrateKbps);
        if (x != null && y != null && x != y) return pref == QualityPreference.best ? y - x : x - y;
        if ((x == null) != (y == null)) return x == null ? 1 : -1;
        return a.$1 - b.$1; // List.sort isn't stable
      });
    final (c, uri) = ordered.first.$2;
    return PlayableSource(uri, headers: (c.headers?.isEmpty ?? true) ? null : c.headers);
  }

  static Uri? _uri(StreamCandidate c) {
    final uri = Uri.tryParse(c.uri);
    if (uri == null || !_schemes.contains(uri.scheme)) return null;
    // Dart turns an empty file path into "/", so a file URI needs more than that.
    return (uri.scheme == 'file' ? uri.path.length > 1 : uri.host.isNotEmpty) ? uri : null;
  }
}

/// Resolves a track to what the player should play: provider routing, the resolution
/// cache, expiry and the choice of candidate all live here, so the player sees only a
/// PlayableSource. (Search is the backend's resolver.ts; this is playback only.)
class SourceResolver {
  /// [streams] fetches a track's candidates; it defaults to the backend, and tests replace it.
  SourceResolver(this._api, {Future<List<StreamCandidate>> Function(Track)? streams, DateTime Function()? now})
    : _now = now ?? DateTime.now {
    _streams = streams ?? _fromServer;
  }

  final Api _api;
  final DateTime Function() _now;
  late final Future<List<StreamCandidate>> Function(Track) _streams;

  // ponytail: in memory for the session only; stream URLs are short-lived, so nothing persists.
  final _cache = <String, List<StreamCandidate>>{};
  final _hintTried = <String>{};

  Future<PlayableSource> resolve(Track t) async {
    trackRef(t.id); // a malformed id is invalid_source
    if (!t.playable) throw const PlaybackException('not_playable', "This track can't be played in JARX");
    final known = _cache[t.id] ?? _hint(t);
    if (known != null) {
      try {
        return QualitySelector.pick(known, now: _now());
      } on PlaybackException {
        // expired, or an unusable legacy hint: resolve afresh
      }
    }
    final fresh = _cache[t.id] = await _streams(t);
    return QualitySelector.pick(fresh, now: _now());
  }

  /// Resolves [t] ahead of time so it starts promptly. Never throws; a failure just
  /// leaves it to resolve() later.
  void prefetch(Track t) {
    if (!t.playable || _cache.containsKey(t.id) || _hint(t) != null) return;
    Future.sync(() => _streams(t)).then((c) {
      _cache[t.id] = c;
    }, onError: (Object _) {}).ignore();
  }

  /// Forgets what [t] resolved to, after its stream failed to play.
  void invalidate(Track t) {
    _cache.remove(t.id);
    _hintTried.add(t.id);
  }

  /// Legacy hint: tracks saved before the playback contract carry the URL they were found
  /// with. It's tried once (Jamendo's and Archive's never expire, which also keeps playback
  /// off Jamendo's flaky lookup); after that, only [_streams] is asked.
  List<StreamCandidate>? _hint(Track t) {
    final url = t.streamUrl;
    if (url == null || !_hintTried.add(t.id)) return null;
    return _cache[t.id] = [StreamCandidate(url)];
  }

  /// Transitional: /stream answers one URL with no expiry.
  Future<List<StreamCandidate>> _fromServer(Track t) async {
    try {
      return [StreamCandidate(await _api.streamUrl(t))];
    } on ApiException catch (e) {
      throw PlaybackException(switch (e.code) {
        'not_playable' => 'not_playable',
        'not_found' => 'no_stream',
        'invalid_request' => 'invalid_source',
        _ => 'unavailable',
      }, e.message);
    }
  }
}
