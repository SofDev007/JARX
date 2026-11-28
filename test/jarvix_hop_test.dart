import 'dart:math' as math;

import 'package:Bloomee/screens/screen/jarvix_hop.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('nothing moves before the first tap', () {
    final w = HopWorld(400, 800, []);
    final y = w.y;
    w.step(0.1);
    expect(w.y, y);
    expect(w.pillars, isEmpty);
  });

  test('without tapping Jarvix falls and the game ends', () {
    final w = HopWorld(400, 800, [], rng: math.Random(1))..flap();
    for (var i = 0; i < 300 && !w.over; i++) {
      w.step(1 / 60);
    }
    expect(w.over, isTrue);
    expect(w.events, contains(HopEvent.crash));
  });

  /// Holds Jarvix at [y] while only [p] is on screen.
  void hold(HopWorld w, HopPillar p, double y, int frames) {
    for (var i = 0; i < frames; i++) {
      w.pillars
        ..clear()
        ..add(p);
      w.y = y;
      w.vy = 0;
      w.step(1 / 60);
    }
  }

  test('middle of the gap is a Perfect (+2), off-centre is +1', () {
    final w = HopWorld(400, 800, [], rng: math.Random(1))..flap();
    hold(w, HopPillar(w.blobX + 30, 400, 200, null), 400, 120);
    expect(w.over, isFalse);
    expect((w.score, w.streak), (2, 1));

    hold(w, HopPillar(w.blobX + 30, 400, 200, null), 460, 120);
    expect((w.over, w.score, w.streak), (false, 3, 0));
  });

  test('a note adds a point, a pillar ends the game', () {
    final w = HopWorld(400, 800, [], rng: math.Random(1))..flap();
    final p = HopPillar(w.blobX - 43, 400, 200, null, item: HopItem.note);
    hold(w, p, 400, 1);
    expect(w.score, 1);
    expect(p.item, isNull);

    hold(w, HopPillar(w.blobX - 10, 100, 150, null), 400, 1);
    expect(w.over, isTrue);
  });

  test('the shield saves one crash, then Jarvix passes through for a bit',
      () {
    final w = HopWorld(400, 800, [], rng: math.Random(1))..flap();
    w.shield = true;
    hold(w, HopPillar(w.blobX - 10, 100, 150, null), 400, 1);
    expect((w.over, w.shield), (false, false));
    expect(w.events, contains(HopEvent.saved));
    hold(w, HopPillar(w.blobX - 10, 100, 150, null), 400, 30);
    expect(w.over, isFalse);
    // Blink over: the next hit counts.
    w.ghostLeft = 0;
    hold(w, HopPillar(w.blobX - 10, 100, 150, null), 400, 1);
    expect(w.over, isTrue);
  });

  test('slow-mo slows the pillars, moving pillars slide', () {
    final w = HopWorld(400, 800, [])..slowLeft = 2;
    expect(w.speed, closeTo(170 * 0.55, 0.01));
    final p = HopPillar(0, 400, 200, null, amp: 50);
    expect(p.gapY(0), 400);
    expect(p.gapY(1), isNot(400));
  });

  test('sound bytes are a valid WAV', () {
    final b = hopWav([0, 0.5, -0.5]);
    expect(String.fromCharCodes(b.sublist(0, 4)), 'RIFF');
    expect(b.length, 44 + 6);
  });
}
