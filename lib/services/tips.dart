// First-time tips, as a tour: a bubble points at a button, and closing it
// ("Next") brings the next tip on the same screen at once. Each tip shows
// once. "Don't show tips" (I'm a pro) stops them, except [essentialTips].
// New users (the first-run flow calls [TipStore.startOver]) get every tip;
// people updating get only [featureTips], the tips of features added since.
// Which tip, where: [tipTexts]; the widgets are in tip_overlay.dart.

import 'dart:convert';

import 'package:Bloomee/services/db/dao/settings_dao.dart';
import 'package:Bloomee/services/db/db_provider.dart';

/// Tip id -> text, in priority order (when two could show, the earlier).
const tipTexts = <String, String>{
  // The player (shown only while it's open).
  'P1': 'Swipe up on the player to see what plays next.',
  'P2': 'Swipe down to tuck the player away. The music keeps playing.',
  'A4': 'Play video is here. Watch the music video right in the player.',
  'T2': 'Falling asleep to music? Set a sleep timer and JARX stops by itself.',
  // Jarvix.
  'J1': 'Meet Jarvix, your music buddy. Tap me and tell me your mood, or ask '
      'me to play any song or its video.',
  'J2': 'Try "play Kesariya" or "show me the video of Aadat". I play it '
      'right away.',
  // Home.
  'T14': 'Tap your photo for Your corner. Hold it to switch account.',
  'T18': 'Tap the JARX logo to meet the developer behind JARX.',
  'A1': 'Tap ⊖ on a song to never see it again.',
  'T16': 'Updates and news land here. JARX installs updates for you.',
  // Playlists and downloads.
  'A2': "Try Smart shuffle: your playlist plus new songs you'll like.",
  'T10': 'Download the whole playlist and listen without internet.',
  'T11':
      'Saving mobile data? Set downloads to Wi-Fi only in Settings › Downloads.',
  // Search.
  'V1': 'YouTube Video songs come with their music video. Play one and tap '
      'Play video in the player.',
  'T9':
      'Searching YouTube Music. Switch to YouTube Video for songs with music videos.',
  'A3': 'Swipe a song to queue it.',
  'T6': 'Tap ⋮ for more: play next, add to a playlist, download and more.',
  'T7': 'Queued songs play right after this one, in the order you added them.',
  'T8':
      'Not your vibe? Tap ⊖ and JARX learns. It never plays that song for you again.',
  'T4':
      'Lyrics running late? Tap ⋮ › Sync lyrics, then tap a line the moment you hear it.',
  'T5': 'Captions are here. Pick the language and size in settings.',
  'T17': 'Bored of Home? Switch to another layout here.',
};

/// Still shown after "Don't show tips": the gestures nobody finds alone, never
/// suggest (⊖), and YouTube Video's music videos.
const essentialTips = {'P1', 'P2', 'A1', 'T8', 'V1'};

/// Tips for a feature added in an update, id -> the build that added it:
/// existing users get only these. Add a new feature's tip here.
const featureTips = <String, int>{'T18': 46};

/// Tips that point at the player: shown only while it's open (the others
/// only while it's closed, so a tip never points behind it).
const playerTips = {'P1', 'P2', 'A4', 'T2'};

/// Tips that wait until something happened N times (e.g. T2: the second
/// time the full player opens).
const tipNeeds = <String, (String, int)>{'T2': ('player', 2)};

/// What the user has seen; saved as one small setting.
class TipBook {
  TipBook(
      {Set<String>? shown,
      this.tourEnded = false,
      this.everything = false,
      Map<String, int>? counts})
      : shown = shown ?? {},
        counts = counts ?? {};

  final Set<String> shown;

  /// "Don't show tips" pressed: only [essentialTips] from now on.
  bool tourEnded;

  /// A new user (or "Show tips again"): every tip. Otherwise only
  /// [featureTips], so an update doesn't explain the app to old users.
  bool everything;
  final Map<String, int> counts;

  /// The tip to show now out of [offered], or null.
  String? pick(Iterable<String> offered) {
    for (final id in tipTexts.keys) {
      if (!offered.contains(id) || shown.contains(id)) continue;
      if (!everything && !featureTips.containsKey(id)) continue;
      if (tourEnded && !essentialTips.contains(id)) continue;
      final need = tipNeeds[id];
      if (need != null && (counts[need.$1] ?? 0) < need.$2) continue;
      return id;
    }
    return null;
  }

  void markShown(String id) => shown.add(id);

  Map<String, dynamic> toJson() => {
        'shown': shown.toList(),
        if (tourEnded) 'ended': true,
        if (everything) 'all': true,
        'counts': counts,
      };

  static TipBook fromJson(Map j) => TipBook(
        shown: {for (final s in j['shown'] as List? ?? const []) '$s'},
        tourEnded: j['ended'] == true,
        everything: j['all'] == true,
        counts: {
          for (final e in (j['counts'] as Map? ?? const {}).entries)
            '${e.key}': (e.value as num).toInt()
        },
      );
}

class TipStore {
  static const _key = 'tips1';
  static TipBook? _book;

  static Future<TipBook> load() async {
    if (_book != null) return _book!;
    try {
      final raw = await SettingsDAO(DBProvider.db).getSettingStr(_key);
      if (raw != null) return _book = TipBook.fromJson(jsonDecode(raw) as Map);
    } catch (_) {}
    return _book = TipBook();
  }

  static Future<void> save() async {
    final b = _book;
    if (b == null) return;
    await SettingsDAO(DBProvider.db)
        .putSettingStr(_key, jsonEncode(b.toJson()));
  }

  /// [what] happened once more (e.g. 'player' opened).
  static Future<void> bump(String what) async {
    final b = await load();
    b.counts[what] = (b.counts[what] ?? 0) + 1;
    await save();
  }

  /// "Don't show tips": only the must-knows from now on.
  static Future<void> endTour() async {
    (await load()).tourEnded = true;
    await save();
  }

  /// Every tip can show again (first-run done, or "Show tips again").
  static Future<void> startOver() async {
    _book = TipBook(everything: true);
    await save();
  }
}
