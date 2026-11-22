// The update text: the build you have, the latest build (date and notes),
// then the other builds you skipped.

import 'package:Bloomee/services/app_updater.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Noon UTC: the same calendar day in every time zone.
  final releases = [
    {
      'tag_name': 'v2.0.0+39',
      'prerelease': true,
      'body': 'test build',
      'published_at': '2026-11-21T12:00:00Z'
    },
    {
      'tag_name': 'v2.0.0+38',
      // The notes repeat the heading on their first line: dropped.
      'body': 'JARX 2.0.0 (build 38)\r\n\r\nJam',
      'published_at': '2026-11-20T12:00:00Z'
    },
    {
      'tag_name': 'v2.0.0+37',
      'body': 'Build 37:\nFirst run\n',
      'published_at': '2026-11-19T12:00:00Z'
    },
    {'tag_name': 'v2.0.0+36', 'body': 'Updater', 'draft': true},
    {'tag_name': 'v2.0.0+35', 'body': 'Sync'},
  ];

  test('current build, then the latest, then the others skipped', () {
    expect(
        notesSince(releases, '2.0.0', 35),
        'Current build\nJARX 2.0.0 (build 35)\n\n'
        'Latest build\nJARX 2.0.0 (build 38) · 20 Nov 2026\nJam\n\n'
        'Also new since your build\n'
        'JARX 2.0.0 (build 37) · 19 Nov 2026\nFirst run');
  });

  test('one build behind: no "also new" part', () {
    expect(
        notesSince(releases, '2.0.0', 37),
        'Current build\nJARX 2.0.0 (build 37)\n\n'
        'Latest build\nJARX 2.0.0 (build 38) · 20 Nov 2026\nJam');
  });

  test('up to date: nothing', () {
    expect(notesSince(releases, '2.0.0', 38), '');
  });

  test('build number from a tag', () {
    expect(buildOfTag('v2.0.0+36'), 36);
    expect(buildOfTag('v2.0.0'), 0);
  });

  group('compulsory update', () {
    final rel = [
      {'tag_name': 'v2.0.0+41', 'body': 'Polish'},
      {'tag_name': 'v2.0.0+40', 'prerelease': true, 'body': requiredMarker},
      {'tag_name': 'v2.0.0+39', 'body': 'Fix\n$requiredMarker'},
      {'tag_name': 'v2.0.0+38', 'body': '$requiredMarker\nOld fix'},
    ];

    test('someone on 37 must install (the newest required is 39)', () {
      expect(requiredTagIn(rel, '2.0.0', 37), '2.0.0+39');
    });

    test('past the required build: free', () {
      expect(requiredTagIn(rel, '2.0.0', 39), '');
    });

    test('pre-releases and unmarked releases never force', () {
      expect(requiredTagIn([rel[0], rel[1]], '2.0.0', 37), '');
    });

    test('same build, older round: must install (2.1.2+43 -> 2.1.5+43)', () {
      final ai = [
        {'tag_name': 'v2.1.5+43', 'body': '$requiredMarker\nJarvix'},
        ...rel,
      ];
      expect(requiredTagIn(ai, '2.1.2', 43), '2.1.5+43');
      expect(requiredTagIn(ai, '2.1.5', 43), '');
      expect(requiredTagIn(ai, '2.1.6', 43), '');
      expect(requiredTagIn(ai, '2.0.0', 42), '2.1.5+43');
    });

    test('newer is decided by version, then build', () {
      expect(isNewerTag('2.1.5+43', '2.1.2', 43), isTrue);
      expect(isNewerTag('v2.1.6+43', '2.1.5', 43), isTrue);
      expect(isNewerTag('2.1.5+43', '2.1.5', 43), isFalse);
      expect(isNewerTag('2.1.5+43', '2.0.0', 42), isTrue);
      expect(isNewerTag('2.0.0+44', '2.1.5', 43), isFalse);
      // Older saved answers held only the build: never block on them.
      expect(isNewerTag('43', '2.1.2', 43), isFalse);
      expect(isNewerTag('', '2.1.2', 43), isFalse);
    });

    test('a same-build round shows in the notes', () {
      final ai = [
        {'tag_name': 'v2.1.5+43', 'body': 'Jarvix'},
      ];
      expect(notesSince(ai, '2.1.2', 43),
          'Current build\nJARX 2.1.2 (build 43)\n\nLatest build\nJARX 2.1.5 (build 43)\nJarvix');
    });

    test('the marker never shows in the notes', () {
      expect(
          notesSince(rel, '2.0.0', 38),
          'Current build\nJARX 2.0.0 (build 38)\n\n'
          'Latest build\nJARX 2.0.0 (build 41)\nPolish\n\n'
          'Also new since your build\nJARX 2.0.0 (build 39)\nFix');
    });
  });

  test('people see the short notes; GitHub keeps the full ones', () {
    const full = '''Meet Jarvix, your music buddy.

In short
- Jarvix: tap the glowing blob
- Settings › Jarvix

What's new
- A very long line about everything that changed.
- Another long line.

Check your download
- SHA-256: abc''';
    expect(shortNotes(full),
        'Meet Jarvix, your music buddy.\n- Jarvix: tap the glowing blob\n- Settings › Jarvix');
    // Older notes (no "In short"): everything but the download check.
    expect(shortNotes('Clearer notices.\n\nWhat\'s new\n- one\n\nCheck your download\n- SHA-256: x'),
        "Clearer notices.\n\nWhat's new\n- one");
  });
}
