// The JARX AI chat with Saathi: grows out of the blob, swipe down to close.
// Consent first; then a greeting (with the one-time video tip), quick chips,
// replies with mix cards (songs found on YT Music, 🎬 for the video), the
// helpline card when someone sounds very low, and Copy / Report on hold.

import 'dart:math' as math;

import 'package:Bloomee/blocs/media_player/bloomee_player_cubit.dart';
import 'package:Bloomee/blocs/mini_player/mini_player_cubit.dart';
import 'package:Bloomee/blocs/player_overlay/player_overlay_cubit.dart';
import 'package:Bloomee/core/models/exported.dart';
import 'package:Bloomee/core/models/media_playlist_model.dart';
import 'package:Bloomee/core/theme/app_theme.dart';
import 'package:Bloomee/screens/widgets/edge_glow.dart';
import 'package:Bloomee/screens/widgets/player_video.dart';
import 'package:Bloomee/screens/widgets/saathi_blob.dart';
import 'package:Bloomee/screens/widgets/tip_overlay.dart';
import 'package:Bloomee/screens/widgets/snackbar.dart';
import 'package:Bloomee/services/account/account.dart';
import 'package:Bloomee/services/ai/saathi.dart';
import 'package:Bloomee/services/recommendations/song_card.dart';
import 'package:Bloomee/utils/load_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:url_launcher/url_launcher.dart';

const _quickChips = [
  "I'm sad",
  'Hype me up',
  'Something new',
  'Old is gold',
  'Roast my taste',
];

/// Opens the chat, growing out of [from] (the blob's centre on screen).
Future<void> openSaathiChat(BuildContext context, {Offset? from}) =>
    Navigator.of(context, rootNavigator: true).push(PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 520),
      reverseTransitionDuration: const Duration(milliseconds: 360),
      pageBuilder: (_, __, ___) => const SaathiChatPage(),
      transitionsBuilder: (context, anim, _, child) {
        if (MediaQuery.of(context).disableAnimations) return child;
        final size = MediaQuery.sizeOf(context);
        final c = from ?? Offset(size.width - 43, size.height - 190);
        final far = [
          Offset.zero,
          Offset(size.width, 0),
          Offset(0, size.height),
          Offset(size.width, size.height),
        ].map((p) => (p - c).distance).reduce(math.max);
        final r = Curves.easeInOutCubic.transform(anim.value) * far;
        return ClipPath(clipper: _Circle(c, r), child: child);
      },
    ));

class _Circle extends CustomClipper<Path> {
  _Circle(this.c, this.r);
  final Offset c;
  final double r;
  @override
  Path getClip(Size size) =>
      Path()..addOval(Rect.fromCircle(center: c, radius: r));
  @override
  bool shouldReclip(_Circle old) => old.r != r || old.c != c;
}

/// When a message was sent: "10:42 pm" today, "Yesterday, 10:42 pm",
/// else "21 Nov, 10:42 pm". Empty for chats saved before times were kept.
String messageTime(DateTime at, DateTime now) {
  if (at.millisecondsSinceEpoch == 0) return '';
  final time = DateFormat('h:mm a').format(at).toLowerCase();
  final days = DateTime(now.year, now.month, now.day)
      .difference(DateTime(at.year, at.month, at.day))
      .inDays;
  if (days == 0) return time;
  if (days == 1) return 'Yesterday, $time';
  final day =
      DateFormat(at.year == now.year ? 'd MMM' : 'd MMM yyyy').format(at);
  return '$day, $time';
}

String _shown(String text) =>
    fillName(text, Account.instance.user?.name).replaceAll('**', '');

class SaathiChatPage extends StatefulWidget {
  const SaathiChatPage({super.key});

  @override
  State<SaathiChatPage> createState() => _SaathiChatPageState();
}

class _SaathiChatPageState extends State<SaathiChatPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  double _dragY = 0;
  final saathi = Saathi.instance;

  @override
  void initState() {
    super.initState();
    // The edge glow for 5 s as the chat opens. After the first frame, so
    // it sits above this route (see showEdgeGlow).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) showEdgeGlow(context, duration: const Duration(seconds: 5));
    });
    saathi.load().then((_) => _greetIfNeeded());
    saathi.videoStarted.addListener(_openVideo);
  }

  /// "play the video of …": show the player in video mode.
  void _openVideo() {
    if (!mounted) return;
    final overlay = context.read<PlayerOverlayCubit>();
    PlayerVideo.open.value = true;
    Navigator.of(context).pop();
    overlay.showPlayer();
  }

  @override
  void dispose() {
    saathi.videoStarted.removeListener(_openVideo);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Track? get _playing {
    final s = context.read<MiniPlayerCubit>().state;
    return s.isVisible ? s.track : null;
  }

  Future<void> _greetIfNeeded() async {
    if (!mounted || !saathi.state.consent || !saathi.needsGreeting) return;
    await saathi.greet(playing: _playing);
  }

  /// Back to the newest message (the list is bottom-anchored: 0 = newest).
  void _toLatest() {
    if (_scroll.hasClients && _scroll.offset > 0) {
      _scroll.animateTo(0,
          duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }
  }

  void _send(String text) {
    if (text.trim().isEmpty) return;
    _input.clear();
    _toLatest();
    saathi.send(text, playing: _playing);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([saathi.changed, saathi.thinking]),
      builder: (context, _) => ValueListenableBuilder<Mood?>(
        valueListenable: MoodTags.nowMood,
        builder: (context, mood, _) {
          final colors = moodColors(mood);
          return Scaffold(
            backgroundColor: AppTheme.themeColor,
            body: Transform.translate(
              offset: Offset(0, _dragY),
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.center,
                    colors: [
                      Color.lerp(AppTheme.themeColor, colors.$1, 0.16)!,
                      AppTheme.themeColor,
                    ],
                  ),
                ),
                child: SafeArea(
                  child: Stack(children: [
                    Column(children: [
                      _handle(),
                      const _NowPlaying(),
                      _header(colors),
                      Expanded(child: _messages(colors)),
                      _chips(),
                      _inputBar(colors),
                    ]),
                    if (!saathi.state.consent)
                      _Consent(
                        colors: colors,
                        onYes: () async {
                          saathi.state.consent = true;
                          await saathi.save();
                          await _greetIfNeeded();
                        },
                      ),
                  ]),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _handle() => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: (d) =>
            setState(() => _dragY = math.max(0, _dragY + d.delta.dy)),
        onVerticalDragEnd: (d) {
          if (_dragY > 120 || (d.primaryVelocity ?? 0) > 700) {
            Navigator.of(context).pop();
          } else {
            setState(() => _dragY = 0);
          }
        },
        child: Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 6),
          child: Center(
            child: Container(
              width: 44,
              height: 5,
              decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(5)),
            ),
          ),
        ),
      );

  Widget _header((Color, Color) colors) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 4, 6),
        child: Row(children: [
          SaathiBlob(
            size: 40,
            colors: colors,
            state:
                saathi.thinking.value ? BlobState.thinking : BlobState.paused,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(saathiName,
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: AppTheme.primaryColor1)),
                Text(
                    saathi.thinking.value
                        ? 'thinking…'
                        : saathi.limitedToday
                            ? 'resting · back tomorrow'
                            : saathiFullForm,
                    style:
                        const TextStyle(fontSize: 12, color: Colors.white54)),
              ],
            ),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded, color: Colors.white70),
            color: const Color(0xFF22182A),
            onSelected: (v) async {
              if (v == 'memory') {
                await Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const JarvixMemoryPage()));
              } else if (v == 'clear') {
                await saathi.clearChat();
                await _greetIfNeeded();
              } else if (v == 'privacy') {
                if (!mounted) return;
                await showModalBottomSheet(
                    context: context,
                    backgroundColor: const Color(0xFF1A111B),
                    isScrollControlled: true,
                    builder: (_) => const JarvixPrivacySheet());
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                  value: 'memory',
                  child: Text('🧠  What I remember about you')),
              PopupMenuItem(value: 'clear', child: Text('🧹  Clear chat')),
              PopupMenuItem(value: 'privacy', child: Text('🔒  Privacy')),
            ],
          ),
          IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.keyboard_arrow_down_rounded,
                color: Colors.white70, size: 28),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ]),
      );

  Widget _messages((Color, Color) colors) {
    final chat = saathi.state.chat;
    final thinking = saathi.thinking.value;
    // Bottom-anchored (reverse): it opens on the newest messages and stays
    // there as replies arrive, without jumping while the user scrolls up
    // (it used to jump to the end on every change, so it couldn't scroll).
    return ListView.builder(
      controller: _scroll,
      reverse: true,
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
      itemCount: chat.length + (thinking ? 1 : 0),
      itemBuilder: (context, j) {
        final i = chat.length - 1 - (thinking ? j - 1 : j);
        if (thinking && j == 0) {
          return Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: SaathiBlob(
                  size: 30, colors: colors, state: BlobState.thinking),
            ),
          );
        }
        final m = chat[i];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: m.mine
              ? _Bubble(m, mine: true)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Bubble(m, mine: false),
                    if (m.helpline) const _Helpline(),
                    if (m.mix != null) _MixCard(m.mix!, colors: colors),
                  ],
                ),
        );
      },
    );
  }

  Widget _chips() => SizedBox(
        height: 44,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          children: [
            for (final c in _quickChips)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ActionChip(
                  label: Text(c),
                  labelStyle: const TextStyle(
                      color: AppTheme.primaryColor1, fontSize: 13),
                  backgroundColor: Colors.white.withValues(alpha: 0.06),
                  side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
                  shape: const StadiumBorder(),
                  onPressed: saathi.thinking.value || saathi.limitedToday
                      ? null
                      : () => _send(c),
                ),
              ),
          ],
        ),
      );

  Widget _inputBar((Color, Color) colors) {
    final resting = saathi.limitedToday;
    final bar = Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
      child: Row(children: [
        Expanded(
          child: TextField(
            controller: _input,
            enabled: !resting,
            minLines: 1,
            maxLines: 4,
            textCapitalization: TextCapitalization.sentences,
            style: const TextStyle(color: AppTheme.primaryColor1),
            onSubmitted: _send,
            decoration: InputDecoration(
              hintText: resting
                  ? '$saathiName is resting · back tomorrow'
                  : 'Talk to $saathiName…',
              hintStyle: const TextStyle(color: Colors.white38),
              filled: true,
              fillColor: const Color(0xFF1B1220),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: resting ? null : () => _send(_input.text),
          child: Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(colors: [colors.$1, colors.$2]),
            ),
            child:
                const Icon(Icons.send_rounded, color: Colors.white, size: 20),
          ),
        ),
      ]),
    );
    // Its tip waits until Jarvix is on: before that the welcome covers it.
    return saathi.state.consent ? TipAnchor(id: 'J2', child: bar) : bar;
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble(this.m, {required this.mine});
  final SaathiMsg m;
  final bool mine;

  Future<void> _actions(BuildContext context) async {
    HapticFeedback.mediumImpact();
    final text = _shown(m.text);
    final pick = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF1A111B),
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
              leading: const Icon(Icons.copy_rounded),
              title: const Text('Copy'),
              onTap: () => Navigator.pop(context, 'copy')),
          if (!m.local && !m.reported)
            ListTile(
                leading: const Icon(Icons.flag_rounded),
                title: const Text('Report this reply'),
                subtitle: const Text('Sends this reply to the JARX owner'),
                onTap: () => Navigator.pop(context, 'report')),
        ]),
      ),
    );
    if (pick == 'copy') {
      await Clipboard.setData(ClipboardData(text: text));
      SnackbarService.showMessage('Copied');
    } else if (pick == 'report') {
      final ok = await Saathi.instance.report(m);
      SnackbarService.showMessage(ok
          ? 'Thanks. The JARX owner will look at this reply.'
          : "Couldn't send the report. Try again when online.");
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Text(_shown(m.text),
        style: const TextStyle(color: Colors.white, fontSize: 15, height: 1.4));
    final bubble = Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.82),
        child: GestureDetector(
          onLongPress: mine ? null : () => _actions(context),
          child: Opacity(
            opacity: m.reported ? 0.45 : 1,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                gradient: mine
                    ? const LinearGradient(
                        colors: [AppTheme.accentColor1, Color(0xFF7B3DF0)])
                    : null,
                color: mine ? null : Colors.white.withValues(alpha: 0.07),
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(18),
                  topRight: const Radius.circular(18),
                  bottomLeft: Radius.circular(mine ? 18 : 4),
                  bottomRight: Radius.circular(mine ? 4 : 18),
                ),
              ),
              child: text,
            ),
          ),
        ),
      ),
    );
    final time = messageTime(m.at, DateTime.now());
    if (time.isEmpty) return bubble;
    return Column(
      crossAxisAlignment:
          mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        bubble,
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 3, 6, 0),
          child: Text(time,
              style: const TextStyle(color: Colors.white38, fontSize: 11)),
        ),
      ],
    );
  }
}

class _Helpline extends StatelessWidget {
  const _Helpline();

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF3D6BFF).withValues(alpha: 0.12),
          border:
              Border.all(color: const Color(0xFF3D6BFF).withValues(alpha: 0.4)),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Want to talk to a real person?',
                style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 15)),
            const SizedBox(height: 4),
            const Text(
                "Tele-MANAS is India's free government mental-health helpline. "
                'Open 24×7, in many languages, no judgement.',
                style: TextStyle(color: Colors.white70, height: 1.4)),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF3D6BFF)),
                onPressed: () => launchUrl(Uri.parse('tel:14416')),
                icon: const Icon(Icons.call_rounded),
                label: const Text('Call 14416'),
              ),
            ),
            const SizedBox(height: 4),
            const Center(
              child: Text('or 1-800-891-4416',
                  style: TextStyle(color: Colors.white54, fontSize: 12)),
            ),
          ],
        ),
      );
}

class _MixCard extends StatelessWidget {
  const _MixCard(this.mix, {required this.colors});
  final SaathiMix mix;
  final (Color, Color) colors;

  Future<void> _play(BuildContext context, List<Track> tracks,
      {bool shuffle = false, int at = 0, Track? video}) async {
    final player = context.read<BloomeePlayerCubit>().bloomeePlayer;
    final list = shuffle ? (List.of(tracks)..shuffle()) : List.of(tracks);
    if (video != null) list[at] = video;
    await player.loadPlaylist(Playlist(tracks: list, title: mix.title),
        idx: at, doPlay: true);
  }

  Future<void> _video(BuildContext context, List<Track> tracks, int i) async {
    SnackbarService.showMessage('Finding the video…', loading: true);
    final video = await Saathi.instance.findVideo(tracks[i]);
    SnackbarService.hide();
    if (!context.mounted) return;
    if (video == null) {
      SnackbarService.showMessage("Couldn't find the video for this one.");
      return;
    }
    final overlay = context.read<PlayerOverlayCubit>();
    await _play(context, tracks, at: i, video: video);
    PlayerVideo.open.value = true;
    if (context.mounted) Navigator.of(context).pop();
    overlay.showPlayer();
  }

  @override
  Widget build(BuildContext context) {
    // Songs show up as they're found (the page rebuilds on Saathi changes).
    if (mix.tracks == null) {
      Future.microtask(() => Saathi.instance.findSongs(mix));
    }
    final tracks = mix.tracks;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF170E1C),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            _covers(tracks),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(mix.title,
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 17)),
                  const SizedBox(height: 3),
                  Text(
                      mix.fromPlaylists.isEmpty
                          ? 'Picked for your taste'
                          : 'From your playlists: ${mix.fromPlaylists.join(', ')}',
                      style:
                          const TextStyle(color: Colors.white54, fontSize: 12)),
                  const SizedBox(height: 6),
                  Wrap(spacing: 6, runSpacing: 4, children: [
                    for (final m in mix.moods)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 9, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(m,
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 11)),
                      ),
                  ]),
                ],
              ),
            ),
          ]),
          const SizedBox(height: 8),
          if (tracks == null || (mix.finding && tracks.isEmpty)) ...[
            const Text('Finding the songs on YT Music…',
                style: TextStyle(color: Colors.white54, fontSize: 13)),
            const SizedBox(height: 6),
            LinearProgressIndicator(
                color: colors.$1,
                backgroundColor: Colors.white10,
                borderRadius: BorderRadius.circular(4)),
          ] else if (tracks.isEmpty)
            Row(children: [
              const Expanded(
                child: Text("Couldn't reach YT Music for these songs.",
                    style: TextStyle(color: Colors.white54, fontSize: 13)),
              ),
              TextButton(
                onPressed: () => Saathi.instance.retryFind(mix),
                child: Text('Try again', style: TextStyle(color: colors.$1)),
              ),
            ])
          else ...[
            if (mix.finding)
              const Padding(
                padding: EdgeInsets.only(bottom: 4),
                child: Text('Finding more…',
                    style: TextStyle(color: Colors.white38, fontSize: 12)),
              ),
            for (var i = 0; i < tracks.length; i++)
              InkWell(
                onTap: () => _play(context, tracks, at: i),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(children: [
                    Expanded(
                      child: Text.rich(
                        TextSpan(children: [
                          TextSpan(
                              text: tracks[i].title,
                              style: const TextStyle(color: Colors.white)),
                          TextSpan(
                              text:
                                  '  ·  ${tracks[i].artists.map((a) => a.name).take(2).join(', ')}',
                              style: const TextStyle(
                                  color: Colors.white54, fontSize: 12)),
                        ]),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Watch the video',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.ondemand_video_rounded,
                          size: 20, color: Colors.white60),
                      onPressed: () => _video(context, tracks, i),
                    ),
                  ]),
                ),
              ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      backgroundColor: colors.$1,
                      foregroundColor: Colors.white),
                  onPressed: () => _play(context, tracks),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const FittedBox(
                      fit: BoxFit.scaleDown, child: Text('Play', maxLines: 1)),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8)),
                  onPressed: () => _play(context, tracks, shuffle: true),
                  icon: const Icon(Icons.shuffle_rounded, size: 18),
                  label: const FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text('Shuffle', maxLines: 1)),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8)),
                  onPressed: () async {
                    final name = await Saathi.saveAsPlaylist(mix.title, tracks);
                    SnackbarService.showMessage(name == null
                        ? "Couldn't save the playlist."
                        : 'Saved as playlist "$name"');
                  },
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const FittedBox(
                      fit: BoxFit.scaleDown, child: Text('Save', maxLines: 1)),
                ),
              ),
            ]),
            const SizedBox(height: 6),
            Center(
              child: Text(
                  'Plays from YT Music · ${tracks.length} songs + more as you listen',
                  style: const TextStyle(color: Colors.white38, fontSize: 11)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _covers(List<Track>? tracks) {
    final urls = [
      for (final t in tracks ?? const <Track>[])
        t.thumbnail.urlLow ?? t.thumbnail.url
    ];
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 76,
        height: 76,
        child: GridView.count(
          crossAxisCount: 2,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          children: [
            for (var i = 0; i < 4; i++)
              i < urls.length
                  ? LoadImageCached(imageUrl: urls[i], fit: BoxFit.cover)
                  : DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment(-1 + i * 0.5, -1),
                          end: const Alignment(1, 1),
                          colors: [colors.$1, colors.$2],
                        ),
                      ),
                    ),
          ],
        ),
      ),
    );
  }
}

class _NowPlaying extends StatelessWidget {
  const _NowPlaying();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<MiniPlayerCubit, MiniPlayerState>(
      builder: (context, s) {
        if (!s.isVisible) return const SizedBox.shrink();
        final t = s.track!;
        final player = context.read<BloomeePlayerCubit>().bloomeePlayer;
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 12),
          padding: const EdgeInsets.fromLTRB(6, 4, 4, 4),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 30,
                height: 30,
                child: LoadImageCached(
                    imageUrl: t.thumbnail.urlLow ?? t.thumbnail.url),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '${t.title} · ${t.artists.map((a) => a.name).take(2).join(', ')}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: Icon(
                  s.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  color: Colors.white),
              onPressed: () => s.isPlaying ? player.pause() : player.play(),
            ),
          ]),
        );
      },
    );
  }
}

const _consentPoints = [
  'Your messages go to an outside AI (Groq, OpenRouter or Cloudflare) to get replies. Some free AIs may use chats to improve themselves.',
  'To pick music it also gets: the song playing, songs you played lately, your top artists, your languages and your playlists.',
  'Your name stays on this phone. The AI never sees it; the phone adds it to replies. Your email and contacts never leave the phone.',
  'Chats stay on this phone only.',
  "It's a music buddy, not a doctor or a therapist.",
];

class _Consent extends StatelessWidget {
  const _Consent({required this.colors, required this.onYes});
  final (Color, Color) colors;
  final VoidCallback onYes;

  @override
  Widget build(BuildContext context) => Positioned.fill(
        child: Container(
          color: AppTheme.themeColor.withValues(alpha: 0.97),
          padding: const EdgeInsets.fromLTRB(24, 40, 24, 20),
          child: Column(children: [
            SaathiBlob(size: 90, colors: colors),
            const SizedBox(height: 12),
            const Text('Meet $saathiName',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            const Text(saathiFullForm,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: Colors.white54,
                    fontSize: 12.5,
                    fontStyle: FontStyle.italic)),
            const SizedBox(height: 8),
            const Text(
                'Your music buddy. Tell it how you feel, it plays the right songs.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white60, fontSize: 14)),
            const SizedBox(height: 18),
            Expanded(
              child: ListView(children: [
                for (final p in _consentPoints)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('•  ',
                            style: TextStyle(color: Colors.white70)),
                        Expanded(
                          child: Text(p,
                              style: const TextStyle(
                                  color: Colors.white70, height: 1.4)),
                        ),
                      ],
                    ),
                  ),
                TextButton(
                  onPressed: () => launchUrl(Uri.parse(jarxPrivacyUrl),
                      mode: LaunchMode.externalApplication),
                  child: const Text('Read the privacy policy'),
                ),
              ]),
            ),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: colors.$1,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: onYes,
                child: const Text('Turn on $saathiName',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Not now',
                  style: TextStyle(color: Colors.white54)),
            ),
          ]),
        ),
      );
}

class JarvixPrivacySheet extends StatelessWidget {
  const JarvixPrivacySheet({super.key});

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Privacy',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w800)),
              const SizedBox(height: 10),
              for (final p in _consentPoints)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text('•  $p',
                      style:
                          const TextStyle(color: Colors.white70, height: 1.4)),
                ),
              Row(children: [
                TextButton(
                  onPressed: () => launchUrl(Uri.parse(jarxPrivacyUrl),
                      mode: LaunchMode.externalApplication),
                  child: const Text('Privacy policy'),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () async {
                    final s = Saathi.instance;
                    s.state.consent = false;
                    await s.save();
                    if (context.mounted) Navigator.of(context).pop();
                  },
                  child: const Text('Turn off $saathiName',
                      style: TextStyle(color: Color(0xFFFF9FB1))),
                ),
              ]),
            ],
          ),
        ),
      );
}

class JarvixMemoryPage extends StatefulWidget {
  const JarvixMemoryPage({super.key});

  @override
  State<JarvixMemoryPage> createState() => JarvixMemoryPageState();
}

class JarvixMemoryPageState extends State<JarvixMemoryPage> {
  late final List<TextEditingController> _lines = [
    for (final m in Saathi.instance.state.memory) TextEditingController(text: m)
  ];

  @override
  void dispose() {
    for (final c in _lines) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() =>
      Saathi.instance.setMemory([for (final c in _lines) c.text]);

  @override
  Widget build(BuildContext context) {
    return PopScope(
      onPopInvokedWithResult: (_, __) => _save(),
      child: Scaffold(
        backgroundColor: AppTheme.themeColor,
        appBar: AppBar(
          backgroundColor: AppTheme.themeColor,
          title: const Text('What I remember about you'),
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
                'Only on this phone. Edit a line or tap ✕ to delete it. '
                '$saathiName adds new notes as you chat.',
                style: TextStyle(color: Colors.white54)),
            const SizedBox(height: 12),
            if (_lines.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Text('Nothing yet. Fresh start. ✨',
                    style: TextStyle(color: Colors.white70)),
              ),
            for (final c in _lines)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.only(left: 12),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(children: [
                  Expanded(
                    child: TextField(
                      controller: c,
                      style: const TextStyle(color: Colors.white),
                      decoration:
                          const InputDecoration(border: InputBorder.none),
                    ),
                  ),
                  IconButton(
                    icon:
                        const Icon(Icons.close_rounded, color: Colors.white54),
                    onPressed: () => setState(() => _lines.remove(c)),
                  ),
                ]),
              ),
            if (_lines.isNotEmpty)
              TextButton(
                onPressed: () => setState(_lines.clear),
                child: const Text('Forget everything',
                    style: TextStyle(color: Color(0xFFFF9FB1))),
              ),
          ],
        ),
      ),
    );
  }
}
