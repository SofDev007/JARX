// Jarvix Hop: a tap-to-hop mini game. Jarvix (the AI blob) flies through
// gaps between pillars made of the user's own songs (cover + title).
// Notes to collect, "Perfect" streaks, shield and slow-mo power-ups, moving
// pillars after 15 points, a new Jarvix colour every 3 points, soft sounds
// and a roast when you crash.
// Opened from the Jarvix bubble's hold menu.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:Bloomee/blocs/media_player/bloomee_player_cubit.dart';
import 'package:Bloomee/core/models/exported.dart';
import 'package:Bloomee/core/models/media_playlist_model.dart';
import 'package:Bloomee/screens/widgets/saathi_blob.dart';
import 'package:Bloomee/services/db/dao/history_dao.dart';
import 'package:Bloomee/services/db/dao/playlist_dao.dart';
import 'package:Bloomee/services/db/dao/settings_dao.dart';
import 'package:Bloomee/services/db/dao/track_dao.dart';
import 'package:Bloomee/services/db/db_provider.dart';
import 'package:Bloomee/services/recommendations/song_card.dart';
import 'package:Bloomee/utils/load_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:media_kit/media_kit.dart' show Media, Player;
import 'package:path_provider/path_provider.dart';

void openJarvixHop(BuildContext context) =>
    Navigator.of(context, rootNavigator: true)
        .push(MaterialPageRoute(builder: (_) => const JarvixHop()));

enum HopItem { note, shield, slow }

enum HopEvent { perfect, note, shield, slow, saved, crash }

class HopPillar {
  HopPillar(this.x, this.baseY, this.gap, this.track,
      {this.amp = 0, this.phase = 0, this.item, this.itemDy = 0});
  double x;
  final double baseY, gap, amp, phase, itemDy;
  final Track? track;
  HopItem? item;
  bool passed = false, centred = false, perfect = false;

  /// Gap centre at game time [t]: still, or sliding up and down.
  double gapY(double t) => baseY + amp * math.sin(phase + t * 1.6);
}

bool circleHitsRect(Offset c, double r, Rect rect) {
  final dx = c.dx - c.dx.clamp(rect.left, rect.right);
  final dy = c.dy - c.dy.clamp(rect.top, rect.bottom);
  return dx * dx + dy * dy < r * r;
}

/// The game itself, no Flutter widgets: [y] is the blob's centre.
class HopWorld {
  HopWorld(this.w, this.h, this.songs, {math.Random? rng})
      : _rng = rng ?? math.Random() {
    reset();
  }
  final double w, h;
  final List<Track> songs;
  final math.Random _rng;

  static const blobSize = 54.0, pillarW = 86.0, spacing = 250.0;
  static const gravity = 1700.0, hop = -540.0, itemR = 15.0;
  double get blobX => w * 0.28;
  double get radius => blobSize * 0.36;

  double y = 0, vy = 0, t = 0;
  int score = 0, streak = 0, _next = 0;
  bool started = false, over = false, shield = false;

  /// Seconds left of slow-mo, and of the blink after the shield saves you.
  double slowLeft = 0, ghostLeft = 0;
  Track? hitBy;
  final pillars = <HopPillar>[];

  /// What happened in the last [step] (sounds, pop-up text).
  final events = <HopEvent>[];

  /// Narrower gaps and faster songs as the score climbs.
  double get gap => math.max(150, 210 - score * 2.0);
  double get speed =>
      (170 + math.min(score, 40) * 4.0) * (slowLeft > 0 ? 0.55 : 1);

  void reset() {
    y = h * 0.45;
    vy = t = slowLeft = ghostLeft = 0;
    score = streak = 0;
    started = over = shield = false;
    hitBy = null;
    pillars.clear();
    events.clear();
  }

  void flap() {
    if (over) return;
    started = true;
    vy = hop;
  }

  void step(double dt) {
    if (!started || over) return;
    t += dt;
    slowLeft = math.max(0, slowLeft - dt);
    ghostLeft = math.max(0, ghostLeft - dt);
    vy += gravity * dt;
    y += vy * dt;
    if (y < radius) {
      y = radius;
      vy = 0;
    }
    for (final p in pillars) {
      p.x -= speed * dt;
    }
    pillars.removeWhere((p) => p.x < -pillarW);
    if (pillars.isEmpty || pillars.last.x < w - spacing) _spawn();

    final c = Offset(blobX, y);
    if (y + radius >= h && !_saved()) over = true;
    for (final p in pillars) {
      final gy = p.gapY(t);
      final item = p.item;
      if (item != null &&
          (c - Offset(p.x + pillarW / 2, gy + p.itemDy)).distance <
              radius + itemR) {
        p.item = null;
        switch (item) {
          case HopItem.note:
            score++;
            events.add(HopEvent.note);
          case HopItem.shield:
            shield = true;
            events.add(HopEvent.shield);
          case HopItem.slow:
            slowLeft = 4;
            events.add(HopEvent.slow);
        }
      }
      final top = Rect.fromLTRB(p.x, -h, p.x + pillarW, gy - p.gap / 2);
      final bottom = Rect.fromLTRB(p.x, gy + p.gap / 2, p.x + pillarW, h * 2);
      if (ghostLeft == 0 &&
          (circleHitsRect(c, radius, top) ||
              circleHitsRect(c, radius, bottom)) &&
          !_saved()) {
        over = true;
        hitBy = p.track;
      }
      // Right through the middle of the gap: a Perfect, worth 2.
      if (!p.centred && p.x + pillarW / 2 <= blobX) {
        p.centred = true;
        p.perfect = (y - gy).abs() < p.gap * 0.12;
      }
      if (!p.passed && p.x + pillarW < blobX - radius) {
        p.passed = true;
        if (p.perfect) {
          streak++;
          score += 2;
          events.add(HopEvent.perfect);
        } else {
          streak = 0;
          score++;
        }
      }
    }
    if (over) events.add(HopEvent.crash);
  }

  /// A crash while the shield is up: it breaks, Jarvix blinks for a moment
  /// (passes through pillars) and bounces.
  bool _saved() {
    if (ghostLeft > 0) {
      if (y + radius >= h) vy = hop;
      return true;
    }
    if (!shield) return false;
    shield = false;
    ghostLeft = 1.2;
    vy = hop * 0.8;
    events.add(HopEvent.saved);
    return true;
  }

  void _spawn() {
    final g = gap;
    final amp = score >= 15 ? math.min(70.0, 25 + (score - 15) * 2.5) : 0.0;
    final edge = 70 + g / 2 + amp;
    final baseY = edge + _rng.nextDouble() * math.max(0, h - 2 * edge);
    final track = songs.isEmpty ? null : songs[_next++ % songs.length];
    final r = _rng.nextDouble();
    final item = score >= 5 && r < 0.07 && !shield
        ? HopItem.shield
        : score >= 5 && r < 0.14
            ? HopItem.slow
            : r < 0.55
                ? HopItem.note
                : null;
    pillars.add(HopPillar(w + 40, baseY, g, track,
        amp: amp,
        phase: _rng.nextDouble() * math.pi * 2,
        item: item,
        itemDy: (_rng.nextDouble() - 0.5) * g * 0.5));
  }
}

/// Mono 16-bit PCM WAV bytes for [samples] in -1..1.
Uint8List hopWav(List<double> samples, {int rate = 22050}) {
  final b = ByteData(44 + samples.length * 2);
  void str(int at, String s) {
    for (var i = 0; i < s.length; i++) {
      b.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  str(0, 'RIFF');
  b.setUint32(4, 36 + samples.length * 2, Endian.little);
  str(8, 'WAVEfmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little);
  b.setUint16(22, 1, Endian.little);
  b.setUint32(24, rate, Endian.little);
  b.setUint32(28, rate * 2, Endian.little);
  b.setUint16(32, 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  str(36, 'data');
  b.setUint32(40, samples.length * 2, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    b.setInt16(44 + i * 2, (samples[i].clamp(-1.0, 1.0) * 32767).round(),
        Endian.little);
  }
  return b.buffer.asUint8List();
}

/// A short sweep from [f0] to [f1] Hz that fades out.
List<double> _tone(double ms, double f0, double f1,
    {double decay = 5, bool noise = false}) {
  const rate = 22050;
  final n = (rate * ms / 1000).round();
  final rng = math.Random(7);
  var phase = 0.0;
  return List.generate(n, (i) {
    final p = i / n;
    phase += 2 * math.pi * (f0 + (f1 - f0) * p) / rate;
    var s = math.sin(phase);
    if (noise) s = s * 0.5 + (rng.nextDouble() * 2 - 1) * 0.5;
    final attack = math.min(1.0, i / (rate * 0.004));
    return s * 0.6 * attack * math.exp(-decay * p);
  });
}

/// The game's sounds, made on the fly (no files shipped). Each one has its
/// own small player at a low volume, so they mix over the music instead of
/// pausing it (only JARX's own player takes audio focus).
class _Sfx {
  static final _sounds = <String, (List<double> Function(), double)>{
    'hop': (() => _tone(70, 520, 880), 18),
    'note': (() => [..._tone(80, 1320, 1320), ..._tone(140, 1760, 1760)], 30),
    'perfect': (
      () => [
            ..._tone(70, 1046, 1046),
            ..._tone(70, 1318, 1318),
            ..._tone(130, 1568, 1568)
          ],
      28
    ),
    'power': (() => _tone(240, 400, 1200, decay: 2), 30),
    'saved': (() => _tone(180, 900, 300, decay: 3), 32),
    'crash': (() => _tone(300, 180, 50, decay: 4, noise: true), 38),
  };
  final _players = <String, Player>{};
  bool on = true, _gone = false;

  Future<void> load() async {
    final dir = await getTemporaryDirectory();
    for (final e in _sounds.entries) {
      final f = File('${dir.path}/jarvix_hop_${e.key}.wav');
      await f.writeAsBytes(hopWav(e.value.$1()));
      if (_gone) return;
      final p = Player();
      _players[e.key] = p;
      await p.setVolume(e.value.$2);
      await p.open(Media(f.path), play: false);
    }
  }

  Future<void> play(String key) async {
    final p = _players[key];
    if (!on || p == null) return;
    await p.seek(Duration.zero);
    await p.play();
  }

  void dispose() {
    _gone = true;
    for (final p in _players.values) {
      p.dispose();
    }
  }
}

/// Jarvix's crash lines; {song} and {artist} are filled in.
const _roasts = [
  'You crashed into "{song}". Bold way to skip a song.',
  '"{song}" said no. Respect the song.',
  'You and "{song}" had a moment. A very loud one.',
  '"{song}" hit harder than its chorus.',
  'That wasn\'t a skip, that was a collision.',
  'Plot twist: "{song}" was the boss level.',
  'Maybe listen to "{song}" instead of flying into it?',
  'At least you crashed into a banger.',
  'Jarvix rates that crash 10/10. "{song}" rates you 2/10.',
];
const _artistRoasts = [
  '{artist} did not sign up for this.',
  '{artist} sends regards. And a bill for the damage.',
  'Even {artist} couldn\'t save that run.',
];
const _floorRoasts = [
  'Jarvix met the floor. The floor won.',
  'Gravity: 1. Jarvix: 0.',
  'You forgot to tap. Jarvix forgot to fly.',
];

String hopRoast(Track? t, math.Random rng) {
  String pick(List<String> l) => l[rng.nextInt(l.length)];
  if (t == null) return pick(_floorRoasts);
  final artist = t.artists.isEmpty ? '' : t.artists.first.name;
  final line = artist.isNotEmpty && rng.nextInt(3) == 0
      ? pick(_artistRoasts)
      : pick(_roasts);
  return line.replaceAll('{song}', t.title).replaceAll('{artist}', artist);
}

class JarvixHop extends StatefulWidget {
  const JarvixHop({super.key});

  @override
  State<JarvixHop> createState() => _JarvixHopState();
}

class _JarvixHopState extends State<JarvixHop>
    with SingleTickerProviderStateMixin {
  static const _bestKey = 'arcade_hop_best', _soundKey = 'arcade_hop_sound';

  /// Jarvix's colour changes every 3 points, going round this list.
  static final _palette = {
    (const Color(0xFFFF4F9A), const Color(0xFFB9A6FF)),
    for (final m in Mood.values) moodColors(m),
  }.toList();
  late final Ticker _ticker = createTicker(_tick);
  final _settings = SettingsDAO(DBProvider.db);
  final _sfx = _Sfx();
  final _rng = math.Random();
  final _songs = <Track>[];
  HopWorld? _world;
  Duration _last = Duration.zero, _now = Duration.zero;
  Duration _crashAt = Duration.zero, _sayAt = Duration.zero;
  Duration _colourAt = const Duration(days: -1);
  int _best = 0, _colourStep = 0;
  String _say = '', _roast = '';

  @override
  void initState() {
    super.initState();
    _load();
    _sfx.load();
    _ticker.start();
  }

  Future<void> _load() async {
    final trackDao = TrackDAO(DBProvider.db);
    final lists = await Future.wait([
      HistoryDAO(DBProvider.db, trackDao).getHistory(limit: 80),
      PlaylistDAO(DBProvider.db, trackDao)
          .loadPlaylist(PlaylistDAO.likedPlaylist)
          .then((p) => p.tracks),
    ]);
    final best = await _settings.getSettingStr(_bestKey);
    final sound = await _settings.getSettingBool(_soundKey);
    final seen = <String>{};
    if (!mounted) return;
    setState(() {
      _songs.addAll([
        for (final t in lists.expand((l) => l))
          if (t.thumbnail.url.isNotEmpty && seen.add(t.id)) t
      ]..shuffle());
      _best = int.tryParse(best ?? '') ?? 0;
      _sfx.on = sound ?? true;
    });
  }

  void _show(String text) {
    _say = text;
    _sayAt = _now;
  }

  void _tick(Duration elapsed) {
    final dt = ((elapsed - _last).inMicroseconds / 1e6).clamp(0.0, 1 / 30);
    _last = _now = elapsed;
    final w = _world;
    if (w == null) return;
    w.step(dt);
    for (final e in w.events) {
      switch (e) {
        case HopEvent.perfect:
          _show(w.streak > 1 ? 'Perfect ×${w.streak}' : 'Perfect!');
          _sfx.play('perfect');
        case HopEvent.note:
          _show('+1 ♪');
          _sfx.play('note');
        case HopEvent.shield:
          _show('Shield up!');
          _sfx.play('power');
        case HopEvent.slow:
          _show('Slow-mo!');
          _sfx.play('power');
        case HopEvent.saved:
          _show('Saved by the shield!');
          _sfx.play('saved');
          HapticFeedback.mediumImpact();
        case HopEvent.crash:
          _crashAt = elapsed;
          _roast = hopRoast(w.hitBy, _rng);
          _sfx.play('crash');
          HapticFeedback.heavyImpact();
          if (w.score > _best) {
            _best = w.score;
            _settings.putSettingStr(_bestKey, '$_best');
          }
      }
    }
    w.events.clear();
    if (w.score ~/ 3 != _colourStep) {
      _colourStep = w.score ~/ 3;
      if (_colourStep > 0) _colourAt = elapsed;
    }
    setState(() {});
  }

  void _tap() {
    final w = _world;
    if (w == null || w.over) return;
    HapticFeedback.selectionClick();
    _sfx.play('hop');
    w.flap();
  }

  Future<void> _play(Track t) async {
    await context.read<BloomeePlayerCubit>().bloomeePlayer.loadPlaylist(
        Playlist(tracks: [t], title: 'Jarvix Hop'),
        doPlay: true);
  }

  void _toggleSound() {
    setState(() => _sfx.on = !_sfx.on);
    _settings.putSettingBool(_soundKey, _sfx.on);
  }

  @override
  void dispose() {
    _ticker.dispose();
    _sfx.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF120B17),
      body: LayoutBuilder(builder: (context, box) {
        var w = _world;
        if (w == null || w.w != box.maxWidth || w.h != box.maxHeight) {
          w = _world = HopWorld(box.maxWidth, box.maxHeight, _songs);
        }
        final bob = w.started ? 0.0 : math.sin(_now.inMilliseconds / 300) * 8;
        const s = HopWorld.blobSize;
        // A little pop when the colour changes.
        final pop = 1 +
            0.35 *
                (1 - (_now - _colourAt).inMilliseconds / 350).clamp(0.0, 1.0);
        final blink = w.ghostLeft > 0 && (_now.inMilliseconds ~/ 90).isEven;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => _tap(),
          child: Stack(children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: w.slowLeft > 0
                        ? const [Color(0xFF14303A), Color(0xFF0D0810)]
                        : const [Color(0xFF2A1834), Color(0xFF0D0810)],
                  ),
                ),
              ),
            ),
            for (final p in w.pillars) ..._pillar(p, w),
            Positioned(
              left: w.blobX - s / 2,
              top: w.y + bob - s / 2,
              child: Opacity(
                opacity: blink ? 0.35 : 1,
                child: Transform.rotate(
                  angle: (w.vy / 1000).clamp(-0.4, 0.7),
                  child: Transform.scale(
                    scale: pop,
                    child: Container(
                      decoration: w.shield
                          ? BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                  color: const Color(0xFF5CE1FF), width: 2.5),
                              boxShadow: const [
                                BoxShadow(
                                    color: Color(0x665CE1FF), blurRadius: 12)
                              ],
                            )
                          : null,
                      child: SaathiBlob(
                        size: s,
                        colors: _palette[_colourStep % _palette.length],
                        state: w.over ? BlobState.offline : BlobState.playing,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            SafeArea(
              child: Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(
                      w.started ? '${w.score}' : '',
                      style: const TextStyle(
                          fontSize: 48,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                          shadows: [Shadow(blurRadius: 8)]),
                    ),
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      if (w.shield)
                        const Icon(Icons.shield_rounded,
                            color: Color(0xFF5CE1FF), size: 20),
                      if (w.slowLeft > 0) ...[
                        const SizedBox(width: 8),
                        const Icon(Icons.hourglass_bottom_rounded,
                            color: Color(0xFF7CFFB2), size: 20),
                        Text(' ${w.slowLeft.ceil()}s',
                            style: const TextStyle(color: Color(0xFF7CFFB2))),
                      ],
                    ]),
                    const SizedBox(height: 6),
                    Opacity(
                      opacity: w.over
                          ? 0
                          : (1 - (_now - _sayAt).inMilliseconds / 900)
                              .clamp(0.0, 1.0),
                      child: Text(_say,
                          style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFFFFE27A),
                              shadows: [Shadow(blurRadius: 6)])),
                    ),
                  ]),
                ),
              ),
            ),
            SafeArea(
              child: Row(children: [
                IconButton(
                  icon: const Icon(Icons.close_rounded, color: Colors.white70),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                const Spacer(),
                IconButton(
                  icon: Icon(
                      _sfx.on
                          ? Icons.volume_up_rounded
                          : Icons.volume_off_rounded,
                      color: Colors.white70),
                  onPressed: _toggleSound,
                ),
              ]),
            ),
            if (!w.started) _ready(),
            if (w.over) _gameOver(w),
          ]),
        );
      }),
    );
  }

  List<Widget> _pillar(HopPillar p, HopWorld w) {
    final gy = p.gapY(w.t);
    final top = gy - p.gap / 2, bottom = gy + p.gap / 2;
    final t = p.track;
    final item = p.item;
    return [
      Positioned(
        key: ObjectKey((p, 0)),
        left: p.x,
        top: 0,
        width: HopWorld.pillarW,
        height: top,
        child: _SongPillar(track: t, label: t?.title, coverAtBottom: true),
      ),
      Positioned(
        key: ObjectKey((p, 1)),
        left: p.x,
        top: bottom,
        width: HopWorld.pillarW,
        height: w.h - bottom,
        child: _SongPillar(
            track: t,
            label: t?.artists.map((a) => a.name).take(2).join(', '),
            coverAtBottom: false),
      ),
      if (item != null)
        Positioned(
          key: ObjectKey((p, 2)),
          left: p.x + HopWorld.pillarW / 2 - HopWorld.itemR,
          top: gy + p.itemDy - HopWorld.itemR,
          child: _ItemBadge(item),
        ),
    ];
  }

  Widget _ready() => IgnorePointer(
        child: Align(
          alignment: const Alignment(0, 0.45),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Jarvix Hop',
                style: TextStyle(
                    fontSize: 34,
                    fontWeight: FontWeight.w800,
                    color: Colors.white)),
            const SizedBox(height: 6),
            Text(
              _songs.isEmpty
                  ? 'Tap to hop.'
                  : 'Tap to hop. Dodge your own songs.',
              style: const TextStyle(color: Colors.white70, fontSize: 16),
            ),
            const SizedBox(height: 4),
            const Text('♪ +1   ·   middle of the gap = Perfect, +2',
                style: TextStyle(color: Colors.white54, fontSize: 13)),
            if (_best > 0) ...[
              const SizedBox(height: 6),
              Text('Best: $_best',
                  style: const TextStyle(color: Colors.white54)),
            ],
          ]),
        ),
      );

  Widget _gameOver(HopWorld w) {
    final t = w.hitBy;
    final ready = _now - _crashAt > const Duration(milliseconds: 500);
    return Center(
      child: Container(
        margin: const EdgeInsets.all(28),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: const Color(0xEE22182A),
          borderRadius: BorderRadius.circular(22),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('${w.score}',
              style: const TextStyle(
                  fontSize: 52,
                  fontWeight: FontWeight.w800,
                  color: Colors.white)),
          Text(
              w.score >= _best && w.score > 0
                  ? 'New best!'
                  : 'Best: $_best',
              style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 14),
          Text(
            _roast,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, fontSize: 16),
          ),
          const SizedBox(height: 18),
          Wrap(spacing: 12, runSpacing: 8, children: [
            if (t != null)
              OutlinedButton.icon(
                onPressed: () => _play(t),
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('Play it'),
              ),
            FilledButton.icon(
              onPressed: ready
                  ? () => setState(() {
                        w.reset();
                        _colourStep = 0;
                        _say = '';
                      })
                  : null,
              icon: const Icon(Icons.replay_rounded),
              label: const Text('Again'),
            ),
          ]),
        ]),
      ),
    );
  }
}

class _ItemBadge extends StatelessWidget {
  const _ItemBadge(this.item);
  final HopItem item;

  @override
  Widget build(BuildContext context) {
    final (color, child) = switch (item) {
      HopItem.note => (
          const Color(0xFFFFD54F),
          const Text('♪',
              style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF3A2A00)))
        ),
      HopItem.shield => (
          const Color(0xFF5CE1FF),
          const Icon(Icons.shield_rounded, size: 17, color: Color(0xFF00313D))
        ),
      HopItem.slow => (
          const Color(0xFF7CFFB2),
          const Icon(Icons.hourglass_bottom_rounded,
              size: 17, color: Color(0xFF00361A))
        ),
    };
    return Container(
      width: HopWorld.itemR * 2,
      height: HopWorld.itemR * 2,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 10)
        ],
      ),
      child: child,
    );
  }
}

/// One half of a song pillar: the cover stretched behind, the song's name
/// (or artist) written along it, and the cover again at the gap's edge.
class _SongPillar extends StatelessWidget {
  const _SongPillar(
      {required this.track, required this.label, required this.coverAtBottom});
  final Track? track;
  final String? label;
  final bool coverAtBottom;

  @override
  Widget build(BuildContext context) {
    final url = track?.thumbnail.urlLow ?? track?.thumbnail.url;
    return LayoutBuilder(builder: (context, box) {
      final cover = box.maxHeight > 90
          ? Padding(
              padding: const EdgeInsets.all(6),
              child: AspectRatio(
                aspectRatio: 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                  child: url == null
                      ? const SizedBox()
                      : LoadImageCached(
                          imageUrl: url,
                          borderRadius: BorderRadius.circular(8)),
                ),
              ),
            )
          : null;
      final text = box.maxHeight > 200 && (label ?? '').isNotEmpty
          ? Expanded(
              child: Center(
                child: RotatedBox(
                  quarterTurns: 3,
                  child: Text(
                    label!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        shadows: [Shadow(blurRadius: 6)]),
                  ),
                ),
              ),
            )
          : const Spacer();
      return ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Stack(fit: StackFit.expand, children: [
          if (url != null) LoadImageCached(imageUrl: url, fit: BoxFit.cover),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  const Color(0xFF7B5CFF).withValues(alpha: 0.75),
                  const Color(0xFF22182A).withValues(alpha: 0.85),
                ],
              ),
            ),
          ),
          Column(
            children: [
              if (!coverAtBottom && cover != null) cover,
              text,
              if (coverAtBottom && cover != null) cover,
            ],
          ),
        ]),
      );
    });
  }
}
