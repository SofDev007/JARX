import 'package:Bloomee/services/ai/saathi.dart';
import 'package:Bloomee/services/account/spaces.dart';
import 'package:Bloomee/services/tips.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('existing users (records from before 2.2.1) get no old tips', () {
    expect(TipBook().pick(['A1', 'P1', 'T7']), isNull);
    final old = TipBook.fromJson(
        {'on': false, 'shown': ['T14'], 'day': '2026-11-21', 'today': 3,
         'counts': {'player': 2}});
    expect(old.pick(['A1', 'P1']), isNull, reason: 'the queue tip for a 44 user');
    expect(old.counts['player'], 2);
  });

  test('the developer tip (new in 46) reaches existing users, not pros', () {
    expect(TipBook().pick(['T18', 'P1']), 'T18');
    expect(TipBook(everything: true).pick(['T18']), 'T18');
    expect(TipBook(tourEnded: true).pick(['T18']), isNull);
  });

  test('new users (first run / Show tips again) get every tip, kept saved',
      () {
    final b = TipBook(everything: true);
    expect(b.pick(['A1']), 'A1');
    expect(TipBook.fromJson(b.toJson()).everything, isTrue);
  });

  test('the tour: each tip once, the more important one first', () {
    final b = TipBook(everything: true);
    expect(b.pick(['A1', 'T14']), 'T14', reason: 'photo tip comes first');
    b.markShown('T14');
    expect(b.pick(['A1', 'T14']), 'A1');
    expect(b.pick(['A2', 'P2', 'P1']), 'P1', reason: 'player: swipe up first');
  });

  test('build 42 users who saw every old tip still get the new ones', () {
    final b = TipBook(
        everything: true, shown: {'T14', 'A1', 'A2', 'T10', 'T9', 'A3'});
    expect(b.pick(['J1', 'T14']), 'J1', reason: 'Jarvix is new in 43');
  });

  test('after "Don\'t show tips" only the must-knows show', () {
    final b = TipBook(everything: true, tourEnded: true);
    expect(b.pick(['T14', 'A2', 'J1']), isNull);
    for (final id in ['P1', 'P2', 'A1', 'T8', 'V1']) {
      expect(b.pick([id]), id);
    }
    final back = TipBook.fromJson(b.toJson());
    expect(back.tourEnded, isTrue);
  });

  test('sleep timer tip waits for the second time the player opens', () {
    final b = TipBook(everything: true);
    b.counts['player'] = 1;
    expect(b.pick(['T2']), isNull);
    b.counts['player'] = 2;
    expect(b.pick(['T2']), 'T2');
  });

  test("another account's Jarvix chat is never shown", () {
    final mine = SaathiState()..owner = 'me';
    expect(belongsTo(mine, 'me', 'space2'), isTrue);
    expect(belongsTo(mine, 'friend', 'space2'), isFalse);
    // Saved before 2.1.3 (no owner): trusted only in the first space; a
    // second account's space got it as a copy.
    final legacy = SaathiState();
    expect(belongsTo(legacy, 'me', Spaces.first), isTrue);
    expect(belongsTo(legacy, 'friend', 'space2'), isFalse);
    expect(SaathiState.fromJson(mine.toJson()).owner, 'me');
  });
}
