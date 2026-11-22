// The edge glow: soft colours of light running around the screen's edges,
// like Siri's on iPhone. Shown when someone turns Jarvix on by hand.

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Lights up the screen's edges for about 2.6 s, above everything; taps go
/// through it.
void showEdgeGlow(BuildContext context) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  late final OverlayEntry entry;
  entry = OverlayEntry(builder: (_) => EdgeGlow(onDone: () => entry.remove()));
  overlay.insert(entry);
}

class EdgeGlow extends StatefulWidget {
  const EdgeGlow({super.key, required this.onDone, this.radius = 44});
  final VoidCallback onDone;

  /// The screen's corner radius (phones are rounded; most are ~40-50).
  final double radius;

  @override
  State<EdgeGlow> createState() => _EdgeGlowState();
}

class _EdgeGlowState extends State<EdgeGlow>
    with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 2600));

  @override
  void initState() {
    super.initState();
    _c.forward().whenComplete(widget.onDone);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: RepaintBoundary(
          child: AnimatedBuilder(
            animation: _c,
            builder: (_, __) => CustomPaint(
              size: Size.infinite,
              painter: EdgeGlowPainter(_c.value, widget.radius),
            ),
          ),
        ),
      );
}

/// [t] 0..1 through the glow: fades in, the colours travel about one turn
/// around the edge, then it fades out.
class EdgeGlowPainter extends CustomPainter {
  EdgeGlowPainter(this.t, this.radius);
  final double t, radius;

  static const _colors = [
    Color(0xFFFF5EAE), // pink
    Color(0xFFFF8A3D), // orange
    Color(0xFFB46BFF), // purple
    Color(0xFF3D8BFF), // blue
    Color(0xFF2EE6E6), // cyan
    Color(0xFFFF5EAE), // back to pink: no seam
  ];

  /// 0 → 1 → 0 with smooth ends.
  double get opacity {
    if (t < 0.18) return Curves.easeOut.transform(t / 0.18);
    if (t > 0.68) return Curves.easeIn.transform((1 - t) / 0.32);
    return 1;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final o = opacity;
    if (o <= 0) return;
    final rect = Offset.zero & size;
    final shader = SweepGradient(
      colors: _colors,
      transform:
          GradientRotation(Curves.easeInOutSine.transform(t) * math.pi * 2),
    ).createShader(rect);
    // Breathes a little while it's lit.
    final breath = 0.92 + 0.08 * math.sin(t * math.pi * 6);
    // (width, blur, strength): a wide soft haze, a glow, a bright thin rim.
    for (final (w, blur, a) in [
       (14.0 * breath, 10.0, 0.35), // soft haze: narrower, less spread
      (6.0 * breath, 4.0, 0.7),    // glow: hugs the edge
      (2.5, 0.0, 0.95),            // thin bright rim
    ]) {
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = w
        ..shader = shader
        ..color = Color.fromRGBO(255, 255, 255, a * o);
      if (blur > 0) paint.maskFilter = MaskFilter.blur(BlurStyle.normal, blur);
      canvas.drawRRect(
          RRect.fromRectAndRadius(rect.deflate(w / 2),
              Radius.circular(math.max(0, radius - w / 2))),
          paint);
    }
  }

  @override
  bool shouldRepaint(EdgeGlowPainter old) => old.t != t;
}
