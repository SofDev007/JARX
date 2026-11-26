// The JARX AI blob: a soft, breathing, liquid blob with two eyes. Its colour
// follows the mood of the song playing; it pulses while music plays, wobbles
// while Saathi thinks, and greys out with closed eyes when offline.
// [SaathiBlobHost] floats it above the mini player on Home and Library.

import 'dart:math' as math;

import 'package:Bloomee/screens/widgets/tip_overlay.dart';
import 'package:Bloomee/blocs/internet_connectivity/cubit/connectivity_cubit.dart';
import 'package:Bloomee/blocs/mini_player/mini_player_cubit.dart';
import 'package:Bloomee/core/theme/app_theme.dart';
import 'package:Bloomee/screens/screen/saathi_chat.dart';
import 'package:Bloomee/screens/widgets/snackbar.dart';
import 'package:Bloomee/services/account/account.dart';
import 'package:Bloomee/services/ai/saathi.dart';
import 'package:Bloomee/services/recommendations/song_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

enum BlobState { paused, playing, thinking, offline }

/// The blob's two colours for a mood (JARX's own colours when none).
(Color, Color) moodColors(Mood? mood) => switch (mood) {
      Mood.sad => (const Color(0xFF3D6BFF), const Color(0xFF8FB0FF)),
      Mood.romantic => (const Color(0xFFFF4F9A), const Color(0xFFFFA0CC)),
      Mood.happy || Mood.uplifting => (
          const Color(0xFFFFB800),
          const Color(0xFFFFE27A)
        ),
      Mood.dance || Mood.energetic => (
          const Color(0xFFFF6A00),
          const Color(0xFFFFB36B)
        ),
      Mood.cozy => (const Color(0xFFC9772F), const Color(0xFFF3C27A)),
      Mood.calm => (const Color(0xFF12B3A2), const Color(0xFF86E8DC)),
      Mood.moody => (const Color(0xFF7B5CFF), const Color(0xFFB9A6FF)),
      Mood.devotional => (const Color(0xFFFF9933), const Color(0xFFFFD27F)),
      null => (AppTheme.accentColor1light, AppTheme.accentColor2),
    };

class SaathiBlob extends StatefulWidget {
  const SaathiBlob({
    super.key,
    this.size = 58,
    required this.colors,
    this.state = BlobState.paused,
  });
  final double size;
  final (Color, Color) colors;
  final BlobState state;

  @override
  State<SaathiBlob> createState() => _SaathiBlobState();
}

class _SaathiBlobState extends State<SaathiBlob>
    with SingleTickerProviderStateMixin {
  final _time = ValueNotifier<double>(0);
  late final Ticker _ticker =
      createTicker((elapsed) => _time.value = elapsed.inMicroseconds / 1e6);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // "Remove animations" in Android's settings: a still blob.
    final still = MediaQuery.of(context).disableAnimations;
    if (still && _ticker.isActive) _ticker.stop();
    if (!still && !_ticker.isActive) _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _time.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The colour fades over a second when the mood changes.
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: widget.colors.$1),
      duration: const Duration(milliseconds: 900),
      builder: (context, a, _) => TweenAnimationBuilder<Color?>(
        tween: ColorTween(end: widget.colors.$2),
        duration: const Duration(milliseconds: 900),
        builder: (context, b, _) => RepaintBoundary(
          child: CustomPaint(
            size: Size.square(widget.size),
            painter: _BlobPainter(_time, a ?? widget.colors.$1,
                b ?? widget.colors.$2, widget.state),
          ),
        ),
      ),
    );
  }
}

class _BlobPainter extends CustomPainter {
  _BlobPainter(this.time, this.a, this.b, this.state) : super(repaint: time);
  final ValueNotifier<double> time;
  final Color a, b;
  final BlobState state;

  @override
  void paint(Canvas canvas, Size size) {
    final t = time.value;
    final s = size.width;
    final offline = state == BlobState.offline;
    final thinking = state == BlobState.thinking;
    final c1 = offline ? const Color(0xFF6B6570) : a;
    final c2 = offline ? const Color(0xFF3A3540) : b;

    canvas.save();
    canvas.translate(s / 2, s / 2);
    if (state == BlobState.playing) {
      // A soft beat, about 2 a second.
      final beat = 1 + 0.03 * (1 + math.sin(t * math.pi * 4));
      canvas.scale(beat);
    }
    if (thinking) canvas.rotate(0.14 * math.sin(t * 9));

    // The liquid edge: 8 points around a circle, each breathing on its own.
    final speed = thinking ? 4.5 : (state == BlobState.paused ? 0.7 : 1.6);
    final amp = offline ? 0.0 : (thinking ? 0.11 : 0.07);
    final r = s * 0.38;
    const n = 8;
    final pts = [
      for (var i = 0; i < n; i++)
        Offset.fromDirection(
          2 * math.pi * i / n,
          r *
              (1 +
                  amp *
                      math.sin(t * speed + i * 1.7) *
                      math.cos(t * speed * 0.6 + i)),
        )
    ];
    final path = Path()..moveTo(pts[0].dx, pts[0].dy);
    for (var i = 0; i < n; i++) {
      // Catmull-Rom through the points, as cubic curves.
      final p0 = pts[(i - 1 + n) % n], p1 = pts[i];
      final p2 = pts[(i + 1) % n], p3 = pts[(i + 2) % n];
      final cp1 = p1 + (p2 - p0) / 6, cp2 = p2 - (p3 - p1) / 6;
      path.cubicTo(cp1.dx, cp1.dy, cp2.dx, cp2.dy, p2.dx, p2.dy);
    }
    path.close();

    final rect = Rect.fromCircle(center: Offset.zero, radius: r * 1.1);
    if (!offline) {
      canvas.drawPath(
          path,
          Paint()
            ..color = c1.withValues(alpha: 0.55)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, s * 0.12));
    }
    canvas.drawPath(
        path,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [c1, c2],
          ).createShader(rect));
    canvas.drawPath(
        path,
        Paint()
          ..shader = RadialGradient(
            center: const Alignment(-0.45, -0.5),
            radius: 0.55,
            colors: [Colors.white.withValues(alpha: 0.45), Colors.transparent],
          ).createShader(rect));

    // Eyes: drift a little, blink every ~5 s; closed when offline.
    final look =
        Offset(math.sin(t * 0.5) * s * 0.03, math.cos(t * 0.37) * s * 0.015);
    final eyeW = s * 0.12, eyeH = s * 0.17, gap = s * 0.14;
    final blink = (t % 5) > 4.85 ? 0.12 : 1.0;
    final eye = Paint()..color = Colors.white;
    for (final side in [-1, 1]) {
      final c = Offset(side * (gap + eyeW) / 2, -s * 0.02) + look;
      if (offline) {
        canvas.drawLine(
            c + Offset(-eyeW / 2, eyeH * 0.2),
            c + Offset(eyeW / 2, eyeH * 0.2),
            Paint()
              ..color = Colors.white70
              ..strokeWidth = s * 0.03
              ..strokeCap = StrokeCap.round);
      } else {
        canvas.drawOval(
            Rect.fromCenter(center: c, width: eyeW, height: eyeH * blink), eye);
      }
    }
    // The smile (a flat, sleepy mouth when offline).
    final mouth = Offset(0, s * 0.13) + look;
    final lip = Paint()
      ..color = offline ? Colors.white70 : Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.035
      ..strokeCap = StrokeCap.round;
    if (offline) {
      canvas.drawLine(
          mouth - Offset(s * 0.05, 0), mouth + Offset(s * 0.05, 0), lip);
    } else {
      canvas.drawArc(
          Rect.fromCenter(center: mouth, width: s * 0.2, height: s * 0.12),
          0.15 * math.pi,
          0.7 * math.pi,
          false,
          lip);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_BlobPainter old) =>
      old.a != a || old.b != b || old.state != state;
}

/// The floating blob over Home and Library (bottom corner, above the mini
/// player): tap to chat, drag to the other side, hold to nap for today.
class SaathiBlobHost extends StatefulWidget {
  const SaathiBlobHost({super.key});

  @override
  State<SaathiBlobHost> createState() => _SaathiBlobHostState();
}

class _SaathiBlobHostState extends State<SaathiBlobHost> {
  static const _size = 58.0, _margin = 14.0;
  Offset? _drag;

  /// Where the blob was when a hold began (hold, then drag).
  Offset _holdFrom = Offset.zero;
  final _blobKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    Saathi.instance.load();
    MoodTags.playing(context.read<MiniPlayerCubit>().state.track);
  }

  bool get _onTabRoot {
    final path =
        GoRouter.of(context).routerDelegate.currentConfiguration.uri.path;
    return path == '/Explore' || path == '/Library';
  }

  void _open(bool offline) {
    HapticFeedback.lightImpact();
    if (offline) {
      SnackbarService.showMessage(
          'I need internet to think. Your downloads still work though.');
      return;
    }
    final box = _blobKey.currentContext?.findRenderObject() as RenderBox?;
    final center = box?.localToGlobal(box.size.center(Offset.zero));
    if (!Saathi.instance.state.helloShown) {
      Saathi.instance.state.helloShown = true;
      Saathi.instance.save();
    }
    openSaathiChat(context, from: center);
  }

  Future<void> _menu() async {
    HapticFeedback.mediumImpact();
    final box = _blobKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final at = box.localToGlobal(Offset.zero);
    final pick = await showMenu<String>(
      context: context,
      color: const Color(0xFF22182A),
      position: RelativeRect.fromLTRB(at.dx, at.dy - 60, at.dx + _size, at.dy),
      items: const [
        PopupMenuItem(value: 'nap', child: Text('💤  Nap for today')),
      ],
    );
    if (pick != 'nap') return;
    await Saathi.instance.nap();
    SnackbarService.showMessage(
      '$saathiName is napping till tomorrow 💤',
      duration: const Duration(seconds: 4),
      action: SnackBarAction(label: 'Wake up', onPressed: Saathi.instance.wake),
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<MiniPlayerCubit, MiniPlayerState>(
      listenWhen: (a, b) => a.track?.id != b.track?.id,
      listener: (context, s) => MoodTags.playing(s.track),
      child: ListenableBuilder(
        listenable: Listenable.merge([
          Saathi.instance.changed,
          Saathi.instance.thinking,
          GoRouter.of(context).routerDelegate,
          Account.instance.state,
        ]),
        builder: (context, _) {
          final saathi = Saathi.instance;
          if (!_onTabRoot ||
              !Account.instance.signedIn ||
              saathi.state.off ||
              saathi.nappingToday) {
            return const SizedBox.shrink();
          }
          return Positioned.fill(
            child: LayoutBuilder(builder: (context, box) {
              final left = saathi.state.left;
              final x = _drag?.dx ??
                  (left ? _margin : box.maxWidth - _size - _margin);
              final y = _drag?.dy ?? box.maxHeight - _size - _margin;
              return Stack(children: [
                if (!saathi.state.helloShown && _drag == null)
                  Positioned(
                    bottom: _size + _margin + 8,
                    left: left ? _margin : null,
                    right: left ? null : _margin,
                    child: const _Hello(),
                  ),
                AnimatedPositioned(
                  duration: _drag == null
                      ? const Duration(milliseconds: 380)
                      : Duration.zero,
                  curve: Curves.easeOutBack,
                  left: x,
                  top: y,
                  child: BlocBuilder<ConnectivityCubit, ConnectivityState>(
                    builder: (context, net) =>
                        BlocBuilder<MiniPlayerCubit, MiniPlayerState>(
                      buildWhen: (a, b) => a.isPlaying != b.isPlaying,
                      builder: (context, player) {
                        final offline = net == ConnectivityState.disconnected;
                        void moveTo(Offset p) => setState(() => _drag = Offset(
                              p.dx.clamp(0, box.maxWidth - _size),
                              p.dy.clamp(0, box.maxHeight - _size),
                            ));
                        // Let go: snap to the nearer side (remembered).
                        void drop() {
                          final toLeft =
                              (_drag?.dx ?? x) + _size / 2 < box.maxWidth / 2;
                          setState(() => _drag = null);
                          if (toLeft != saathi.state.left) {
                            saathi.state.left = toLeft;
                            saathi.save();
                          }
                        }

                        return Semantics(
                          button: true,
                          label: 'Talk to $saathiName',
                          child: GestureDetector(
                              key: _blobKey,
                              onTap: () => _open(offline),
                              // Drag at once, or hold and then drag; hold
                              // and let go without moving: the nap menu.
                              onPanUpdate: (d) => moveTo(
                                  Offset(_drag?.dx ?? x, _drag?.dy ?? y) +
                                      d.delta),
                              onPanEnd: (_) => drop(),
                              onLongPressStart: (_) {
                                HapticFeedback.selectionClick();
                                _holdFrom = Offset(x, y);
                              },
                              onLongPressMoveUpdate: (d) {
                                // A wobble while holding isn't a drag.
                                if (_drag != null ||
                                    d.offsetFromOrigin.distance > 8) {
                                  moveTo(_holdFrom + d.offsetFromOrigin);
                                }
                              },
                              onLongPressEnd: (_) =>
                                  _drag == null ? _menu() : drop(),
                              child: TipAnchor(
                                id: 'J1',
                                child: ValueListenableBuilder<Mood?>(
                                  valueListenable: MoodTags.nowMood,
                                  builder: (context, mood, _) => SaathiBlob(
                                    size: _size,
                                    colors: moodColors(mood),
                                    state: offline
                                        ? BlobState.offline
                                        : saathi.thinking.value
                                            ? BlobState.thinking
                                            : player.isPlaying
                                                ? BlobState.playing
                                                : BlobState.paused,
                                  ),
                                ),
                              )),
                        );
                      },
                    ),
                  ),
                ),
              ]);
            }),
          );
        },
      ),
    );
  }
}

class _Hello extends StatelessWidget {
  const _Hello();

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 16)],
          ),
          child: const Text('Tap me. I talk music.',
              style: TextStyle(
                  color: Color(0xFF1A0F20),
                  fontWeight: FontWeight.w700,
                  fontSize: 13)),
        ),
      );
}
