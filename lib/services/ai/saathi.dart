// JARX AI ("Jarvix"): the music buddy chat and AI mood tags. The AI itself
// runs behind the JARX server (server/src/ai.js); this side keeps the chat,
// what Saathi remembers and the consent ON THE PHONE (per account), builds
// what the AI is told, and turns its song picks into real YT Music tracks
// (the AI never decides what is playable: a song that isn't found is left
// out).

import 'dart:async';
import 'dart:convert';
import 'dart:developer';

import 'package:Bloomee/core/di/service_locator.dart';
import 'package:Bloomee/core/models/exported.dart';
import 'package:Bloomee/core/models/media_playlist_model.dart';
import 'package:Bloomee/services/account/account.dart';
import 'package:Bloomee/services/account/spaces.dart';
import 'package:Bloomee/services/audio_service_initializer.dart';
import 'package:Bloomee/services/db/dao/history_dao.dart';
import 'package:Bloomee/services/db/dao/playlist_dao.dart';
import 'package:Bloomee/services/db/dao/settings_dao.dart';
import 'package:Bloomee/services/db/dao/track_dao.dart';
import 'package:Bloomee/services/db/db_provider.dart';
import 'package:Bloomee/services/db/legacy/legacy_media_id_mapper.dart'
    show pluginYtMusicId;
import 'package:Bloomee/services/meta_resolver/cross_plugin_resolver.dart';
import 'package:Bloomee/services/player/listening_time.dart';
import 'package:Bloomee/services/player/related_songs_manager.dart';
import 'package:Bloomee/services/player/video_streams.dart' show ytVideoPlugin;
import 'package:Bloomee/services/ai/how_to.dart';
import 'package:Bloomee/services/recommendations/recommendation_ranker.dart';
import 'package:Bloomee/services/recommendations/song_card.dart';
import 'package:Bloomee/src/rust/api/plugin/commands.dart'
    show ContentSearchFilter;
import 'package:Bloomee/src/rust/api/plugin/models.dart';
import 'package:Bloomee/src/rust/api/plugin/types.dart';
import 'package:flutter/foundation.dart';

const saathiName = 'Jarvix';

/// Shown under the name when the chat opens.
const saathiFullForm = 'Just A Rather Vibe Intelligent eXpert';

/// The day in India (limits on the server reset at Indian midnight).
String indiaDay([DateTime? now]) => (now ?? DateTime.now())
    .toUtc()
    .add(const Duration(hours: 5, minutes: 30))
    .toIso8601String()
    .substring(0, 10);

/// The user's first name in place of the AI's {name} (the AI never sees it).
String fillName(String text, String? fullName) {
  final first = (fullName ?? '').trim().split(RegExp(r'\s+')).first;
  return text.replaceAll('{name}', first.isEmpty ? 'friend' : first);
}

/// Words that always bring up the helpline card, whatever the AI said.
final _veryLow = RegExp(
    r"suicid|kill myself|end my life|want to die|wanna die|don'?t want to live|"
    r'self[- ]?harm|cut myself|marna chaht|mar jaun|mar jaau|mar jaana|'
    r'jeena nahi|jeene ka mann nahi|khudkushi|aatmhatya',
    caseSensitive: false);
bool soundsVeryLow(String text) => _veryLow.hasMatch(text);

typedef SongAsk = ({String title, String artist});

final _playEn = RegExp(
    r'^(?:please\s+|pls\s+|can you\s+|could you\s+)?(?:play|put on)\s+'
    r'(?:the\s+song\s+|song\s+)?(.+?)(?:\s+by\s+(.+?))?[\s.!?]*$',
    caseSensitive: false);
final _playHi = RegExp(
    r'^(.+?)\s+(?:bajao|baja do|chalao|chala do|sunao|suna do|lagao|laga do|'
    r'play karo|play kar do)[\s.!?]*$',
    caseSensitive: false);
final _vagueStart = RegExp(
    r'^(something|some|anything|any|music|a song|songs?|my|random|more|the playlist|'
    r'playlist|mix|kuch|koi|gaane|gaana|mera|meri|hindi|english|punjabi)\b',
    caseSensitive: false);
final _vagueEnd = RegExp(
    r'\b(songs?|music|gaane|gaana|vibes?|mix|playlist|tracks?)$',
    caseSensitive: false);

final _videoEn = RegExp(
    r'^(?:please\s+|pls\s+|can you\s+)?(?:play|show|open|watch|put on)\s+(?:me\s+)?'
    r'(?:the\s+)?(?:music\s+)?video\s+(?:of|for)\s+(.+?)(?:\s+by\s+(.+?))?[\s.!?]*$',
    caseSensitive: false);
final _videoEnEnd = RegExp(
    r'^(?:please\s+)?(?:play|show|open|watch|put on)\s+(?:me\s+)?(?:the\s+)?(.+?)'
    r'(?:\s+by\s+(.+?))?\s+(?:music\s+)?video[\s.!?]*$',
    caseSensitive: false);
final _videoHi = RegExp(
    r'^(.+?)\s+(?:ka|ki|ke)?\s*(?:music\s+)?video\s+(?:chalao|chala do|dikhao|dikha do|'
    r'lagao|laga do|play karo|play kar do|bajao)[\s.!?]*$',
    caseSensitive: false);

/// "play the video of Aadat", "watch Kesariya video", "Aadat ka video
/// dikhao": the song's music video, from the YouTube Video plugin.
SongAsk? videoRequest(String text) {
  final t = text.trim();
  final m = _videoEn.firstMatch(t) ??
      _videoEnEnd.firstMatch(t) ??
      _videoHi.firstMatch(t);
  if (m == null) return null;
  final title =
      m.group(1)!.trim().replaceAll(RegExp(r'''^["'“]+|["'”]+$'''), '');
  final artist = (m.groupCount >= 2 ? m.group(2) : null)?.trim() ?? '';
  if (title.length < 2 || _vagueStart.hasMatch(title)) return null;
  return (title: title, artist: artist);
}

/// "play Kesariya", "play Tum Hi Ho by Arijit", "Kesariya bajao": the one
/// song asked for, played at once without asking the AI. Vague asks ("play
/// something", "play romantic songs") are left to the AI's mixes.
SongAsk? playRequest(String text) {
  final t = text.trim();
  final m = _playEn.firstMatch(t) ?? _playHi.firstMatch(t);
  if (m == null) return null;
  final title =
      m.group(1)!.trim().replaceAll(RegExp(r'''^["'“]+|["'”]+$'''), '');
  final artist = (m.groupCount >= 2 ? m.group(2) : null)?.trim() ?? '';
  if (title.length < 2 ||
      _vagueStart.hasMatch(title) ||
      _vagueEnd.hasMatch(title)) {
    return null;
  }
  return (title: title, artist: artist);
}

class MixSong {
  const MixSong(this.title, this.artist);
  final String title, artist;
  Map<String, String> toJson() => {'t': title, 'a': artist};
  static MixSong fromJson(Map j) =>
      MixSong('${j['t'] ?? ''}', '${j['a'] ?? ''}');
}

class SaathiMix {
  SaathiMix(this.title, this.moods, this.fromPlaylists, this.songs);
  final String title;
  final List<String> moods, fromPlaylists;
  final List<MixSong> songs;

  /// Found on YT Music so far (kept in memory; found again after a
  /// restart), and whether more are still being looked for.
  List<Track>? tracks;
  bool finding = false;
  Future<List<Track>>? _finding;

  Map<String, dynamic> toJson() => {
        'title': title,
        'moods': moods,
        'from': fromPlaylists,
        'songs': [for (final s in songs) s.toJson()],
      };

  static SaathiMix fromJson(Map j) => SaathiMix(
        '${j['title'] ?? 'Your mix'}',
        [for (final m in j['moods'] as List? ?? const []) '$m'],
        [for (final p in j['from'] ?? j['fromPlaylists'] ?? const []) '$p'],
        [
          for (final s in j['songs'] as List? ?? const [])
            if (s is Map)
              s.containsKey('t')
                  ? MixSong.fromJson(s)
                  : MixSong('${s['title'] ?? ''}', '${s['artist'] ?? ''}')
        ],
      );
}

class SaathiMsg {
  SaathiMsg(this.mine, this.text,
      {this.mix,
      this.helpline = false,
      this.local = false,
      this.reported = false,
      this.howTo,
      DateTime? at})
      : at = at ?? DateTime.now();

  /// Written by the user.
  final bool mine;
  final String text;
  final SaathiMix? mix;
  final bool helpline;

  /// Made on the phone (greeting, errors): never sent to the AI.
  final bool local;
  bool reported;
  final DateTime at;

  /// A "how do I…" answer: the [howTos] id (steps + "Watch how" clip).
  final String? howTo;

  Map<String, dynamic> toJson() => {
        if (mine) 'me': true,
        'text': text,
        if (mix != null) 'mix': mix!.toJson(),
        if (helpline) 'help': true,
        if (local) 'local': true,
        if (reported) 'rep': true,
        if (howTo != null) 'how': howTo,
        'at': at.millisecondsSinceEpoch,
      };

  static SaathiMsg fromJson(Map j) => SaathiMsg(
        j['me'] == true,
        '${j['text'] ?? ''}',
        mix: j['mix'] is Map ? SaathiMix.fromJson(j['mix'] as Map) : null,
        helpline: j['help'] == true,
        local: j['local'] == true,
        reported: j['rep'] == true,
        howTo: j['how'] is String ? j['how'] as String : null,
        at: DateTime.fromMillisecondsSinceEpoch(
            (j['at'] as num?)?.toInt() ?? 0),
      );

  /// How the AI sees this message later in the chat.
  String get forAi => mix == null
      ? text
      : '$text\n[Mix "${mix!.title}": ${mix!.songs.map((s) => '${s.title} — ${s.artist}').join('; ')}]';
}

/// Everything Saathi keeps on the phone, saved as one setting per account.
class SaathiState {
  /// The account this chat belongs to (Google id). Empty: saved before
  /// 2.1.3, when a new account's space got a copy of the last one's chat.
  String owner = '';

  /// Turned off in Settings › Jarvix: no blob, no chats.
  bool off = false;
  bool consent = false;
  bool helloShown = false;
  bool left = false; // the blob's side
  String napDay = '';
  String limitDay = '';
  List<String> memory = [];
  List<SaathiMsg> chat = [];

  Map<String, dynamic> toJson() => {
        if (owner.isNotEmpty) 'owner': owner,
        if (off) 'off': true,
        'consent': consent,
        'hello': helloShown,
        'left': left,
        'nap': napDay,
        'limit': limitDay,
        'memory': memory,
        'chat': [for (final m in chat) m.toJson()],
      };

  static SaathiState fromJson(Map j) => SaathiState()
    ..owner = '${j['owner'] ?? ''}'
    ..off = j['off'] == true
    ..consent = j['consent'] == true
    ..helloShown = j['hello'] == true
    ..left = j['left'] == true
    ..napDay = '${j['nap'] ?? ''}'
    ..limitDay = '${j['limit'] ?? ''}'
    ..memory = [for (final m in j['memory'] as List? ?? const []) '$m']
    ..chat = [
      for (final m in j['chat'] as List? ?? const [])
        if (m is Map) SaathiMsg.fromJson(m)
    ];
}

/// Whether saved [s] is the chat of user [me] in space [space]. One saved
/// before owners were stamped is trusted only in the first space (the only
/// one never made as a copy of another).
bool belongsTo(SaathiState s, String me, String space) {
  if (me.isEmpty) return true; // not signed in yet: can't tell
  if (s.owner.isNotEmpty) return s.owner == me;
  return space == Spaces.first;
}

class Saathi {
  Saathi._();
  static final instance = Saathi._();

  static const _key = 'saathi1';
  static const _keepMessages = 200;
  static const _keepMemory = 20;

  /// Bumped on every change, for the UI.
  final changed = ValueNotifier<int>(0);

  /// Bumped when a song's video was started: the chat opens the player in
  /// video mode.
  final videoStarted = ValueNotifier<int>(0);
  final thinking = ValueNotifier<bool>(false);
  SaathiState state = SaathiState();
  bool _loaded = false;

  Future<SaathiState> load() async {
    if (_loaded) return state;
    _loaded = true;
    try {
      final raw = await SettingsDAO(DBProvider.db).getSettingStr(_key);
      if (raw != null) state = SaathiState.fromJson(jsonDecode(raw) as Map);
    } catch (e) {
      log('Reading Saathi failed: $e', name: 'Saathi');
    }
    final me = Account.instance.user?.id ?? '';
    if (!belongsTo(state, me, Spaces.active)) {
      // Another account's chat (copied with a new account's space): start
      // fresh; it also held what Jarvix remembered about that person.
      state = SaathiState();
    }
    if (me.isNotEmpty && state.owner != me) {
      state.owner = me;
      await save();
    }
    _bump();
    return state;
  }

  /// After switching accounts: read that account's Saathi.
  void forget() {
    _loaded = false;
    state = SaathiState();
  }

  Future<void> save() async {
    if (state.chat.length > _keepMessages) {
      state.chat = state.chat.sublist(state.chat.length - _keepMessages);
    }
    _bump();
    await SettingsDAO(DBProvider.db)
        .putSettingStr(_key, jsonEncode(state.toJson()));
  }

  void _bump() => changed.value++;

  bool get nappingToday => state.napDay == indiaDay();
  bool get limitedToday => state.limitDay == indiaDay();

  /// Settings › Jarvix switch. Turning it on also means "yes, I want to
  /// chat" (the welcome's consent).
  Future<void> setOn(bool on) async {
    await load();
    state.off = !on;
    if (on) state.consent = true;
    await save();
  }

  Future<void> nap() async {
    state.napDay = indiaDay();
    await save();
  }

  Future<void> wake() async {
    state.napDay = '';
    await save();
  }

  /// A new chat starts with a greeting (and, only then, the video tip) when
  /// the chat is empty or quiet for 3 hours.
  bool get needsGreeting =>
      state.chat.isEmpty ||
      DateTime.now().difference(state.chat.last.at) > const Duration(hours: 3);

  Future<void> greet({Track? playing, DateTime? now}) async {
    state.chat.add(SaathiMsg(false, greeting(playing, now ?? DateTime.now()),
        local: true));
    state.chat.add(SaathiMsg(
        false,
        'Psst: everything I play comes from YT Music, so if you ever want '
        'the video too, tap 🎬 on any song.',
        local: true));
    await save();
  }

  static String greeting(Track? playing, DateTime now) {
    final artist = playing == null || playing.artists.isEmpty
        ? null
        : playing.artists.first.name;
    final h = now.hour, hh = h % 12 == 0 ? 12 : h % 12;
    if (artist == null) {
      return h < 5
          ? 'Hey {name}! Up at $hh a.m.? Same. What are we listening to?'
          : h < 12
              ? 'Good morning, {name}! What should today sound like?'
              : h < 17
                  ? 'Hey {name}! Afternoon slump? I can fix that. What\'s the mood?'
                  : h < 21
                      ? 'Hey {name}! Evening vibes. What\'s the mood today?'
                      : 'Hey {name}! Night mode on. Tell me how you feel.';
    }
    return h < 5
        ? "Hey {name}! $hh a.m. and $artist again? 😄 Can't sleep, or don't want to?"
        : h < 12
            ? 'Good morning, {name}! Starting the day with $artist, I see. Strong choice.'
            : h < 17
                ? "Hey {name}! Afternoon slump? $artist won't fix it, but I might."
                : h < 21
                    ? "Hey {name}! Evening vibes with $artist. What's the mood today?"
                    : 'Hey {name}! Night mode on. $artist at this hour means feelings. Spill.';
  }

  Future<void> clearChat() async {
    state.chat = [];
    await save();
  }

  Future<void> setMemory(List<String> memory) async {
    state.memory = memory.where((m) => m.trim().isNotEmpty).toList();
    await save();
  }

  /// Sends [text]; the reply (or a friendly error) is added to the chat.
  Future<void> send(String text, {Track? playing}) async {
    text = text.trim();
    if (text.isEmpty || thinking.value) return;
    await load();
    state.chat.add(SaathiMsg(true, text));
    await save();
    final how = howToFor(text);
    if (how != null) {
      state.chat.add(SaathiMsg(false, how.steps, local: true, howTo: how.id));
      await save();
      return;
    }
    final video = videoRequest(text);
    final asked = video ?? playRequest(text);
    if (asked != null) {
      thinking.value = true;
      try {
        state.chat.add(SaathiMsg(false,
            await playSong(asked.title, asked.artist, video: video != null),
            local: true));
      } finally {
        thinking.value = false;
        await save();
      }
      return;
    }
    if (limitedToday) {
      state.chat.add(SaathiMsg(false, limitLine, local: true));
      await save();
      return;
    }
    thinking.value = true;
    try {
      final history = [
        for (final m in state.chat
            .where((m) => !m.local && !(!m.mine && m.text.trim() == '🎶'))
            .toList()
            .reversed
            .take(12)
            .toList()
            .reversed)
          {'role': m.mine ? 'user' : 'assistant', 'content': m.forAi}
      ];
      final res = await Account.instance.api('POST', '/ai/chat',
          body: {'messages': history, 'context': await _context(playing)});
      final error = res == null ? 'offline' : _errorOf(res.body);
      if (res != null && res.statusCode == 200) {
        final j = jsonDecode(res.body) as Map;
        final mix =
            j['mix'] is Map ? SaathiMix.fromJson(j['mix'] as Map) : null;
        final remember = [
          for (final r in j['remember'] as List? ?? const []) '$r'
        ];
        if (remember.isNotEmpty) {
          state.memory = [...state.memory, ...remember];
          if (state.memory.length > _keepMemory) {
            state.memory =
                state.memory.sublist(state.memory.length - _keepMemory);
          }
        }
        var reply = '${j['reply'] ?? ''}'.trim();
        final play = j['play'] is Map ? j['play'] as Map : null;
        if (play != null) {
          final said = await playSong(
              '${play['title'] ?? ''}', '${play['artist'] ?? ''}',
              video: play['video'] == true);
          reply = reply.isEmpty ? said : '$reply\n$said';
        }
        state.chat.add(SaathiMsg(
            false, reply.isEmpty ? 'Here you go, {name}. 🎧' : reply,
            mix: mix, helpline: j['helpline'] == true || soundsVeryLow(text)));
        if (mix != null) unawaited(findSongs(mix));
      } else if (error == 'ai_limit') {
        state.limitDay = indiaDay();
        state.chat.add(SaathiMsg(false, limitLine, local: true));
      } else {
        state.chat.add(SaathiMsg(
            false,
            error == 'offline'
                ? 'I need internet to think. Your downloads still work though.'
                : 'My brain glitched for a second. 😵 Try again?',
            local: true,
            helpline: soundsVeryLow(text)));
      }
    } catch (e) {
      log('Saathi chat failed: $e', name: 'Saathi');
      state.chat.add(SaathiMsg(
          false, 'My brain glitched for a second. 😵 Try again?',
          local: true, helpline: soundsVeryLow(text)));
    } finally {
      thinking.value = false;
      await save();
    }
  }

  static const limitLine =
      "I've talked too much today. Throat's dry. 🥲 Back tomorrow, {name}. "
      'Your mixes keep playing till then. 🎶';

  static String _errorOf(String body) {
    try {
      return '${(jsonDecode(body) as Map)['error'] ?? ''}';
    } catch (_) {
      return '';
    }
  }

  /// What the AI is told: never the name, email or contacts.
  Future<Map<String, dynamic>> _context(Track? playing) async {
    String line(Track t) =>
        '${t.title} — ${t.artists.isEmpty ? '' : t.artists.first.name}';
    List<String> sample(List<Track> l, int n) {
      if (l.length <= n) return [for (final t in l) line(t)];
      final step = l.length / n;
      return [for (var i = 0; i < n; i++) line(l[(i * step).floor()])];
    }

    final ctx = <String, dynamic>{'memory': state.memory};
    final now = DateTime.now();
    const days = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday'
    ];
    ctx['time'] =
        '${days[now.weekday - 1]} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    if (playing != null) ctx['playing'] = line(playing);
    try {
      final trackDao = TrackDAO(DBProvider.db);
      final results = await Future.wait<Object>([
        RelatedSongsManager.userPlaylists(trackDao),
        PlaylistDAO(DBProvider.db, trackDao)
            .loadPlaylist(PlaylistDAO.likedPlaylist)
            .then((p) => p.tracks),
        HistoryDAO(DBProvider.db, trackDao).getHistory(limit: 20),
        ListeningTime.loadAllPhones(),
        RelatedSongsManager.tasteFromDevice(_ranker),
      ]);
      final playlists = results[0] as Map<String, List<Track>>;
      final liked = results[1] as List<Track>;
      ctx['playlists'] = {
        if (liked.isNotEmpty) 'Liked songs': sample(liked, 25),
        for (final e in playlists.entries.take(14))
          if (e.value.isNotEmpty) e.key: sample(e.value, 25),
      };
      ctx['recent'] = [for (final t in results[2] as List<Track>) line(t)];
      final stats = results[3] as ListeningStats;
      final month = stats.months[monthKey(now)] ?? stats;
      ctx['topArtists'] = [for (final a in month.topArtists(10)) a.name];
      ctx['languages'] = [
        for (final l in (results[4] as UserTaste).languages)
          if (l != SongLanguage.other) l.name
      ];
    } catch (e) {
      log('Saathi context: $e', name: 'Saathi');
    }
    return ctx;
  }

  static final _ranker = RecommendationRanker(
      CrossPluginResolver(pluginService: ServiceLocator.pluginService));
  static final _finder = CrossPluginResolver(
      pluginService: ServiceLocator.pluginService,
      pluginTimeout: const Duration(seconds: 12));

  /// The music plugin to search: YT Music, or another loaded one.
  static Future<String?> _musicPlugin() async {
    final plugins = await _loadedResolvers();
    return plugins.contains(pluginYtMusicId)
        ? pluginYtMusicId
        : plugins.where((p) => p != ytVideoPlugin).firstOrNull;
  }

  /// The mix's songs on YT Music, in the AI's order, shown as they're found.
  /// Searched 3 at a time: the plugin answers one search at a time, and
  /// asking for all 12 at once made most of them time out ("Couldn't find
  /// these songs"). A song that isn't found is left out.
  Future<List<Track>> findSongs(SaathiMix mix) {
    if (mix.tracks != null && !mix.finding) return Future.value(mix.tracks!);
    return mix._finding ??= () async {
      mix.finding = true;
      final where = await _musicPlugin();
      final found = List<Track?>.filled(mix.songs.length, null);
      void publish() {
        final seen = <String>{};
        mix.tracks = [
          for (final t in found)
            if (t != null && seen.add(t.id)) t
        ];
        _bump();
      }

      if (where != null) {
        var next = 0;
        Future<void> worker() async {
          while (next < mix.songs.length) {
            final i = next++;
            found[i] = await _quickFind(mix.songs[i], where);
            if (found[i] != null) publish();
          }
        }

        await Future.wait([worker(), worker(), worker()]);
      }
      mix.finding = false;
      publish();
      return mix.tracks!;
    }();
  }

  /// Nothing was found (offline, plugins still loading): look again.
  void retryFind(SaathiMix mix) {
    mix.tracks = null;
    mix._finding = null;
    unawaited(findSongs(mix));
  }

  /// The same song on YouTube Video (it has the music video), or null.
  /// Video titles look like "Kesariya (Official Video) | Brahmastra", so the
  /// top search result is taken when none matches closely.
  Future<Track?> findVideo(Track track) async {
    final plugins = await _loadedResolvers();
    if (!plugins.contains(ytVideoPlugin)) return null;
    final song = MixSong(
        track.title, track.artists.isEmpty ? '' : track.artists.first.name);
    return await _quickFind(song, ytVideoPlugin) ??
        await _quickFind(song, ytVideoPlugin, filter: ContentSearchFilter.all);
  }

  /// One search for "title artist" on [plugin]: the closest match among the
  /// first results, else the top result (the AI names real songs, and YT
  /// Music titles often carry extras like "(From Brahmastra)").
  Future<Track?> _quickFind(MixSong s, String plugin,
      {ContentSearchFilter filter = ContentSearchFilter.track}) async {
    if (s.title.isEmpty) return null;
    try {
      final results = await _finder
          .searchMedia(
              pluginId: plugin,
              queries: ['${s.title} ${s.artist}'.trim()],
              filter: filter)
          .timeout(const Duration(seconds: 25));
      final tracks = [
        for (final r in results)
          if (r.item case MediaItem_Track(:final field0)) field0
      ];
      if (tracks.isEmpty) return null;
      final target = TrackMatchTarget(
          title: s.title, artistNames: [if (s.artist.isNotEmpty) s.artist]);
      var best = tracks.first;
      var score = -1.0;
      for (final t in tracks.take(5)) {
        final c = _finder.scoreTrack(target, t);
        if (c > score) {
          score = c;
          best = t;
        }
      }
      return score >= 0.45 ? best : tracks.first;
    } catch (e) {
      log('Finding "${s.title}" failed: $e', name: 'Saathi');
      return null;
    }
  }

  /// Plays the one song the user asked for: from their own playlists (Liked
  /// first) when it's there, with that playlist as the queue; else the top
  /// match on YT Music. With [video], its music video from the YouTube
  /// Video plugin instead. Returns the line for the chat.
  Future<String> playSong(String title, String artist,
      {bool video = false}) async {
    final want = _finder.normalized(title);
    if (want.isEmpty) return 'Which song? Tell me its name.';
    if (video) {
      final plugins = await _loadedResolvers();
      if (plugins.contains(ytVideoPlugin)) {
        final song = MixSong(title, artist);
        final v = await _quickFind(song, ytVideoPlugin) ??
            await _quickFind(song, ytVideoPlugin,
                filter: ContentSearchFilter.all);
        if (v != null) {
          final player = await PlayerInitializer().getBloomeeMusicPlayer();
          await player.updateQueueTracks([v], doPlay: true);
          videoStarted.value++;
          return 'Playing the video of ${v.title} 🎬';
        }
        return "Couldn't find a video for \"$title\". Here's the song instead.\n"
            '${await playSong(title, artist)}';
      }
      return 'The YouTube Video plugin is off, so here is the song.\n'
          '${await playSong(title, artist)}';
    }
    final wantArtist = _finder.normalized(artist);
    bool matches(Track t) {
      final got = _finder.normalized(t.title);
      final titleOk = got == want ||
          got.startsWith('$want ') ||
          (want.length >= 4 && got.contains(want));
      if (!titleOk) return false;
      return wantArtist.isEmpty ||
          t.artists.any((a) {
            final n = _finder.normalized(a.name);
            return n.isNotEmpty &&
                (n.contains(wantArtist) || wantArtist.contains(n));
          });
    }

    final player = await PlayerInitializer().getBloomeeMusicPlayer();
    try {
      final trackDao = TrackDAO(DBProvider.db);
      final liked = (await PlaylistDAO(DBProvider.db, trackDao)
              .loadPlaylist(PlaylistDAO.likedPlaylist))
          .tracks;
      final lists = {
        PlaylistDAO.likedPlaylist: liked,
        ...await RelatedSongsManager.userPlaylists(trackDao),
      };
      for (final e in lists.entries) {
        final i = e.value.indexWhere(matches);
        if (i < 0) continue;
        await player.loadPlaylist(Playlist(tracks: e.value, title: e.key),
            idx: i, doPlay: true);
        return 'Playing ${e.value[i].title} from your playlist "${e.key}". ▶';
      }
    } catch (e) {
      log('Looking in the playlists failed: $e', name: 'Saathi');
    }
    final where = await _musicPlugin();
    final t =
        where == null ? null : await _quickFind(MixSong(title, artist), where);
    if (t == null) {
      return "Couldn't find \"$title\" right now. Try the name a bit differently?";
    }
    await player.updateQueueTracks([t], doPlay: true);
    return 'Playing ${t.title} · '
        '${t.artists.map((a) => a.name).take(2).join(', ')} ▶';
  }

  static Future<List<String>> _loadedResolvers() async {
    final plugins = ServiceLocator.pluginService;
    final available = await plugins.getAvailablePlugins();
    final loaded = plugins.getLoadedPlugins().toSet();
    return [
      for (final p in available)
        if (p.pluginType == PluginType.contentResolver &&
            loaded.contains(p.manifest.id))
          p.manifest.id,
    ];
  }

  /// Saves [tracks] as a new playlist; returns its name (made unique).
  static Future<String?> saveAsPlaylist(
      String title, List<Track> tracks) async {
    final dao = PlaylistDAO(DBProvider.db, TrackDAO(DBProvider.db));
    for (var i = 1; i < 50; i++) {
      final name = i == 1 ? title : '$title $i';
      final id =
          await dao.createPlaylist(name, description: 'Made with $saathiName');
      if (id != null) {
        await dao.addTracksToPlaylist(id, tracks);
        return name;
      }
    }
    return null;
  }

  /// "Report this reply": sent to the owner (admin page).
  Future<bool> report(SaathiMsg reply) async {
    final i = state.chat.indexOf(reply);
    final said = i > 0
        ? state.chat
            .sublist(0, i)
            .lastWhere((m) => m.mine, orElse: () => SaathiMsg(true, ''))
            .text
        : '';
    final res = await Account.instance
        .api('POST', '/ai/report', body: {'said': said, 'reply': reply.forAi});
    if (res?.statusCode != 200) return false;
    reply.reported = true;
    await save();
    return true;
  }
}

/// AI mood tags, shared by all JARX users (the server asks the AI once per
/// song). Kept on the phone too; [of] is what the song cards read.
class MoodTags {
  MoodTags._();
  static const _key = 'moodTags1';
  static const _keep = 4000;
  static final _tags = <String, Set<Mood>>{}; // insertion order: oldest first
  static final _asked = <String>{};
  static bool _loaded = false;

  /// The main mood of the song playing now (the blob's colour).
  static final nowMood = ValueNotifier<Mood?>(null);

  static Set<Mood>? of(String key) => _tags[key];

  static String keyOf(Track t) => Saathi._ranker.songKey(t);

  static Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final raw = await SettingsDAO(DBProvider.db).getSettingStr(_key);
      if (raw == null) return;
      for (final e in (jsonDecode(raw) as Map).entries) {
        _tags[e.key as String] = _moods(e.value);
      }
    } catch (e) {
      log('Reading mood tags failed: $e', name: 'MoodTags');
    }
  }

  static Set<Mood> _moods(Object? names) => {
        for (final n in names is List ? names : const [])
          for (final m in Mood.values)
            if (m.name == n) m
      };

  /// Asks for the moods of up to 30 [tracks] JARX doesn't know yet.
  static Future<void> fetch(Iterable<Track> tracks) async {
    if (!Account.instance.signedIn) return;
    await _load();
    final ask = <String, Track>{};
    for (final t in tracks) {
      final k = keyOf(t);
      if (_tags.containsKey(k) || _asked.contains(k)) continue;
      ask[k] = t;
      if (ask.length == 30) break;
    }
    if (ask.isEmpty) return;
    _asked.addAll(ask.keys);
    final res = await Account.instance.api('POST', '/ai/tags', body: {
      'songs': [
        for (final e in ask.entries)
          {
            'key': e.key,
            'title': e.value.title,
            'artist': e.value.artists.map((a) => a.name).take(2).join(', '),
            if (e.value.album?.title != null) 'album': e.value.album!.title,
          }
      ]
    });
    if (res?.statusCode != 200) return;
    final got = (jsonDecode(res!.body) as Map)['tags'];
    if (got is! Map || got.isEmpty) return;
    for (final e in got.entries) {
      final moods = _moods(e.value);
      if (moods.isNotEmpty) _tags['${e.key}'] = moods;
    }
    while (_tags.length > _keep) {
      _tags.remove(_tags.keys.first);
    }
    await SettingsDAO(DBProvider.db).putSettingStr(
        _key,
        jsonEncode({
          for (final e in _tags.entries)
            e.key: [for (final m in e.value) m.name]
        }));
  }

  /// Sets [nowMood] for [track]: its AI tag, else the title-word guess.
  static Future<void> playing(Track? track) async {
    if (track == null || track.id == 'Null') {
      nowMood.value = null;
      return;
    }
    await _load();
    void pick() {
      final moods = of(keyOf(track)) ??
          moodsOfText('${track.title} ${track.album?.title ?? ''}');
      nowMood.value = mainMood(moods);
    }

    pick();
    try {
      await fetch([track]);
    } catch (_) {}
    pick();
  }

  /// The mood that wins the colour when a song has several.
  static Mood? mainMood(Set<Mood> moods) {
    for (final m in const [
      Mood.sad,
      Mood.romantic,
      Mood.dance,
      Mood.energetic,
      Mood.happy,
      Mood.uplifting,
      Mood.calm,
      Mood.cozy,
      Mood.moody,
      Mood.devotional,
    ]) {
      if (moods.contains(m)) return m;
    }
    return null;
  }

  @visibleForTesting
  static void putForTest(String key, Set<Mood> moods) {
    _loaded = true;
    _tags[key] = moods;
  }
}
