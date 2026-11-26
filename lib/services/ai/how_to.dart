// "How do I…" answers for Jarvix: matched on the phone (English and
// Hinglish), answered with steps and, when there is one, a short screen
// recording shipped in assets/faq/ ("Watch how" in the chat).

class HowTo {
  const HowTo(this.id, this.steps, {this.clip});
  final String id;
  final String steps;

  /// Asset path of the screen recording, or null (steps only).
  final String? clip;
}

const howTos = <String, HowTo>{
  'download': HowTo(
      'download',
      'Find the song, tap ⋮ next to it, then Download. It shows up in the '
          'Offline tab (the last one at the bottom) and plays without internet.',
      clip: 'assets/faq/faq01_download_song.mp4'),
  'wifi': HowTo(
      'wifi',
      'Open Settings (⚙ on Home) › Downloads › Download over › Wi-Fi. '
          'Downloads then wait until you are on Wi-Fi.',
      clip: 'assets/faq/faq04_wifi_only.mp4'),
  'spotify': HowTo(
      'spotify',
      'In Spotify, open the playlist › Share › Copy link. In JARX open '
          'Library, tap the import icon (top right) › spotify-importer, paste '
          'the link and tap Import. When the songs are matched, tap Save.',
      clip: 'assets/faq/faq06_spotify_import.mp4'),
  'video': HowTo(
      'video',
      'Search the song, pick YouTube Video above the results, play it and tap '
          'Play video in the player. Or just tell me: "play the video of '
          'Kesariya".',
      clip: 'assets/faq/faq18_music_video.mp4'),
  'never': HowTo(
      'never',
      'Tap ⊖ next to a suggested song (on Home or in Up Next) and JARX never '
          'suggests it again. Changed your mind? Tap Undo right away, or open '
          "the song's ⋮ menu later.",
      clip: 'assets/faq/faq20_never_suggest.mp4'),
  'account': HowTo(
      'account',
      'Hold your photo on Home, then pick another account or Add another '
          'account. Each account keeps its own playlists, Liked and downloads.',
      clip: 'assets/faq/faq26_switch_account.mp4'),
  'update': HowTo(
      'update',
      'Tap the bell on Home. If an update is there, open it and tap Update: '
          'JARX downloads and installs it. JARX also tells you when one is out.'),
  'report': HowTo(
      'report',
      'Open Settings › Report a problem, write what went wrong and tap Send. '
          'It goes straight to the developer.'),
};

final _asks = RegExp(
    r"\b(how|where|can i|can you|could i|is there|help|steps|way to|"
    r"kaise|kese|kaisey|kaisay|kaha|kahan|kidhar|batao|bata do|bataiye|"
    r"sikhao|tarika|kya karu|kya karun|kar sakte|kar sakta|kar sakti)\b",
    caseSensitive: false);

// Checked in order: the first topic that matches wins.
final _topics = <(String, RegExp)>[
  ('report', RegExp(r'\b(report|bug|complain|complaint|shikayat|feedback)\b|not working|kaam nahi|problem')),
  ('wifi', RegExp(r'wi-?fi|mobile data|data (bach|save)')),
  ('update', RegExp(r'\b(update|upgrade|new version|naya version|latest version)\b')),
  ('spotify', RegExp(r'\b(spotify|import)\b')),
  ('account', RegExp(r'\b(account|gmail|google id|e-?mail id|login|log in|sign in)\b')),
  ('never', RegExp(r"\b(suggest|suggestion|suggested|recommend|recommended|recommendation)s?\b|stop showing|never show|mat dikhao|nahi chahiye|don'?t want")),
  ('video', RegExp(r'\bvideo\b')),
  ('download', RegExp(r'\b(download|downloaded|offline)\b|save .*(song|gaana|gana)')),
];

/// The how-to answer for a "how do I …?" message, or null.
HowTo? howToFor(String text) {
  final t = text.toLowerCase();
  if (!_asks.hasMatch(t) && !t.trim().endsWith('?')) return null;
  for (final (id, re) in _topics) {
    if (re.hasMatch(t)) return howTos[id];
  }
  return null;
}
