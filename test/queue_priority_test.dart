// "Add to queue" order: now playing → the user's queue (first in, first
// out) → rest of the playlist → recommendations.
//
// Run with: flutter test test/queue_priority_test.dart

import 'package:Bloomee/services/player/queue_manager.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/recs_dataset.dart';

final _p = [for (var i = 0; i < 4; i++) tr('p$i', 'Playlist $i', 'A$i')];
final _q1 = tr('q1', 'Queued 1', 'Q');
final _q2 = tr('q2', 'Queued 2', 'Q');
final _r = [for (var i = 0; i < 2; i++) tr('r$i', 'Rec $i', 'R$i')];

List<String> _order(QueueManager m) {
  String id(QueueManager m) => m.currentTrack!.id.split('::').last;
  final out = [id(m)];
  while (m.advanceToNext()) {
    out.add(id(m));
  }
  return out;
}

void main() {
  test('single song: queued songs play before recommendations', () {
    final m = QueueManager()..loadTracks([_p[0]]);
    m.addTracks(_r, atLast: true); // autoplay batch
    m.addTrack(_q1);
    m.addTrack(_q2);
    expect(_order(m), ['p0', 'q1', 'q2', 'r0', 'r1']);
  });

  test('playlist: queued songs jump ahead of the rest of the playlist', () {
    final m = QueueManager()..loadTracks(_p, idx: 1);
    m.addTrack(_q1);
    m.addTrack(_q2);
    expect(_order(m), ['p1', 'q1', 'q2', 'p2', 'p3']);
  });

  test('a song queued while a queued song plays goes after the others', () {
    final m = QueueManager()..loadTracks(_p);
    m.addTrack(_q1);
    m.addTrack(_q2);
    m.advanceToNext(); // now playing q1
    m.addTrack(tr('q3', 'Queued 3', 'Q'));
    expect(_order(m), ['q1', 'q2', 'q3', 'p1', 'p2', 'p3']);
  });

  test('shuffled playlist: queued songs still come next, in order', () {
    final m = QueueManager()..loadTracks(_p, shuffling: true);
    final first = m.currentTrack!.id.split('::').last;
    m.addTrack(_q1);
    m.addTrack(_q2);
    final order = _order(m);
    expect(order.take(3), [first, 'q1', 'q2']);
    expect(order.toSet(), hasLength(6));
  });

  test('a new playlist forgets the old queue marks', () {
    final m = QueueManager()..loadTracks([_p[0]]);
    m.addTrack(_q1);
    m.loadTracks([_q1, _p[1], _p[2]]);
    m.addTrack(_q2);
    expect(_order(m), ['q1', 'q2', 'p1', 'p2']);
  });

  // Build 45: what the user asked for, "no mistake this time".
  group('the user\'s queue always comes next', () {
    final a = tr('qa', 'A', 'Q'), b = tr('qb', 'B', 'Q'), c = tr('qc', 'C', 'Q');

    test('A, B, C play next in that order, before picks and suggestions', () {
      final list = [for (var i = 0; i < 6; i++) tr('s$i', 'Song $i', 'S$i')];
      final m = QueueManager()..loadTracks(list);
      m.addTrack(a);
      m.addTrack(b);
      m.insertEvery(2, [tr('x0', 'Pick', 'X'), tr('x1', 'Pick 1', 'X')]);
      m.addTracks(_r, atLast: true);
      m.addTrack(c);
      final order = _order(m);
      expect(order.take(4), ['s0', 'qa', 'qb', 'qc']);
      expect(order, ['s0', 'qa', 'qb', 'qc', 's1', 'x0', 's2', 's3', 'x1',
          's4', 's5', 'r0', 'r1']);
    });

    test('a song already later in the playlist moves up, its old place goes',
        () {
      final m = QueueManager()..loadTracks(_p);
      m.addTrack(_q1);
      m.addTrack(_p[3]);
      expect(_order(m), ['p0', 'q1', 'p3', 'p1', 'p2']);
    });

    test('a suggestion queued by hand moves up from the end', () {
      final m = QueueManager()..loadTracks([_p[0], _p[1]]);
      m.addTracks(_r, atLast: true);
      m.addTrack(_r[1]);
      expect(_order(m), ['p0', 'r1', 'p1', 'r0']);
    });

    test('a song that already played moves up too (no double)', () {
      final m = QueueManager()..loadTracks(_p, idx: 2);
      m.addTrack(_p[0]);
      final order = _order(m);
      expect(order, ['p2', 'p0', 'p3']);
    });

    test('queuing the song playing now, or one already queued, changes nothing',
        () {
      final m = QueueManager()..loadTracks(_p);
      m.addTrack(_q1);
      m.addTrack(_q2);
      m.addTrack(_p[0]);
      m.addTrack(_q1);
      expect(_order(m), ['p0', 'q1', 'q2', 'p1', 'p2', 'p3']);
    });

    test('smart shuffle picks arriving late go after the queue', () {
      final list = [for (var i = 0; i < 5; i++) tr('s$i', 'Song $i', 'S$i')];
      final m = QueueManager()..loadTracks(list);
      m.addTrack(a);
      m.addTrack(b);
      m.insertEvery(2, [tr('x0', 'Pick', 'X')]);
      expect(_order(m), ['s0', 'qa', 'qb', 's1', 'x0', 's2', 's3', 's4']);
    });

    test('shuffled playlist: a song from it queued by hand plays next', () {
      for (var run = 0; run < 20; run++) {
        final m = QueueManager()..loadTracks(_p, shuffling: true);
        final now = m.currentTrack!.id;
        final pick = _p.firstWhere((t) => t.id != now);
        m.addTrack(_q1);
        m.addTrack(pick);
        final order = _order(m);
        expect(order.skip(1).take(2), ['q1', pick.id.split('::').last]);
        expect(order, hasLength(5), reason: 'no song twice, none lost');
      }
    });

    test('turning shuffle on keeps the queue next, in order', () {
      for (var run = 0; run < 20; run++) {
        final m = QueueManager()..loadTracks(_p);
        m.addTrack(a);
        m.addTrack(b);
        m.addTrack(c);
        m.shuffle(true);
        final order = _order(m);
        expect(order.take(4), ['p0', 'qa', 'qb', 'qc']);
        expect(order.toSet(), hasLength(7));
      }
    });
  });

  group('smart shuffle', () {
    final list = [for (var i = 0; i < 7; i++) tr('s$i', 'Song $i', 'S$i')];
    final picks = [for (var i = 0; i < 3; i++) tr('x$i', 'Pick $i', 'X$i')];

    test('one pick after every 3 songs', () {
      final m = QueueManager()..loadTracks(list);
      m.insertEvery(3, picks);
      expect(_order(m), ['s0', 's1', 's2', 'x0', 's3', 's4', 's5', 'x1', 's6']);
    });

    test('picks arriving in batches fill the next free slots', () {
      final m = QueueManager()..loadTracks(list);
      final x = [for (var i = 0; i < 3; i++) tr('x$i', 'Pick $i', 'X$i')];
      m.insertEvery(2, [x[0]]);
      m.insertEvery(2, [x[1], x[2]], placed: {x[0].id});
      expect(_order(m),
          ['s0', 's1', 'x0', 's2', 's3', 'x1', 's4', 's5', 'x2', 's6']);
    });

    test('never behind the song playing now', () {
      final m = QueueManager()..loadTracks(list, idx: 4);
      m.insertEvery(3, picks);
      expect(_order(m), ['s4', 's5', 'x0', 's6']);
    });

    // Smart shuffle turns shuffle mode off first: a playlist loaded while it
    // was on would keep it on and get no picks.
    test('shuffle mode on from before: turned off, picks go in', () {
      final m = QueueManager()..shuffle(true);
      m.shuffle(false);
      m.loadTracks(list);
      m.insertEvery(3, picks);
      expect(_order(m), contains('x0'));
    });

    test('skipped while shuffle is on', () {
      final m = QueueManager()..loadTracks(list, shuffling: true);
      m.insertEvery(3, picks);
      expect(_order(m), hasLength(7));
    });
  });
}
