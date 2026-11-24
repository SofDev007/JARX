// The in-app updater: downloads a new JARX APK with progress and opens
// Android's installer. Android checks the update is signed with the same key
// as the installed JARX before it installs anything.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'package:Bloomee/services/bloomee_updater_tools.dart'
    show isUpdateAvailable;

class AppUpdater {
  static const _channel = MethodChannel('jarx/app');

  /// Downloads [url] to the app's cache, reporting 0..1 (null while the size
  /// is unknown). Returns the saved file's path.
  static Future<String> download(String url, void Function(double?) onProgress) async {
    final dir = Directory('${(await getTemporaryDirectory()).path}/updates');
    await dir.create(recursive: true);
    final file = File('${dir.path}/jarx_update.apk');
    final client = http.Client();
    try {
      final res = await client.send(http.Request('GET', Uri.parse(url)));
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
      final total = res.contentLength;
      var got = 0;
      final sink = file.openWrite();
      await for (final chunk in res.stream) {
        sink.add(chunk);
        got += chunk.length;
        onProgress(total == null || total == 0 ? null : got / total);
      }
      await sink.close();
      return file.path;
    } finally {
      client.close();
    }
  }

  static Future<void> install(String path) =>
      _channel.invokeMethod('installApk', {'path': path});
}

/// A compulsory update. Put this line in a GitHub release's notes (GitHub
/// hides HTML comments) and every phone on JARX 37+ that is older than that
/// release stops playing songs until it updates.
const requiredMarker = '<!-- jarx:required -->';

/// Whether release [tag] (`v2.1.5+43`) is newer than the installed
/// [version] + [build]: the version decides first, then the build. Rounds
/// can share a build number (2.1.2+43 → 2.1.5+43), so the build alone isn't
/// enough. A tag without `+` (older saved answers held only the build) is
/// never newer.
bool isNewerTag(String tag, String version, int build) {
  final t = tag.trim().replaceFirst(RegExp('^[vV]'), '').split('+');
  if (t.length < 2) return false;
  return isUpdateAvailable(version, '$build', t[0], t[1]);
}

/// The newest full release newer than [version] + [build] whose notes carry
/// [requiredMarker], as `2.1.5+43`; '' when no update is compulsory.
String requiredTagIn(List releases, String version, int build) {
  var req = '';
  for (final r in releases.cast<Map>()) {
    final tag = '${r['tag_name']}'.replaceFirst(RegExp('^[vV]'), '');
    if (r['draft'] != true &&
        r['prerelease'] != true &&
        isNewerTag(tag, version, build) &&
        (req.isEmpty || _newerThan(tag, req)) &&
        '${r['body'] ?? ''}'.contains(requiredMarker)) {
      req = tag;
    }
  }
  return req;
}

/// [a] and [b] are tags like `2.1.5+43`.
bool _newerThan(String a, String b) {
  final p = b.split('+');
  return isNewerTag(a, p[0], int.tryParse(p[1]) ?? 0);
}

/// A compulsory update is waiting: songs don't play, and the guided tour
/// (bell -> update -> Download/Install) shows on any play attempt.
class UpdateGate {
  /// The build the user must install, 0 for none.
  static final requiredBuild = ValueNotifier<int>(0);

  /// The Home tour (spotlight on the bell) is showing. The update in the
  /// bell list and the Download/Install button glow whenever [blocked].
  static final showingTour = ValueNotifier<bool>(false);

  static bool get blocked => requiredBuild.value > 0;

  /// The guided tour (at app start while [blocked]).
  static void showTour() => showingTour.value = true;

  /// Opens the bell page; set by GlobalEventListener.
  static VoidCallback? openBell;

  /// Something tried to play while [blocked]: straight to the bell page,
  /// where the update waits (whoever closed the tour, "Later", lands there).
  static void playBlocked() => (openBell ?? showTour)();
}

/// Build number from a release tag like `v2.0.0+38` (0 when missing).
int buildOfTag(String tag) => int.tryParse(tag.split('+').last) ?? 0;

/// A release notes' own first line when it only repeats the heading
/// ("JARX 2.0.0 (build 39)", "Build 37:").
final _repeatedTitle = RegExp(r'^\s*(JARX .*\(build \d+\)|build \d+\s*:?)\s*$',
    caseSensitive: false);

String _releaseName(Map r) =>
    'JARX ${'${r['tag_name']}'.replaceFirst(RegExp('^[vV]'), '').replaceFirst('+', ' (build ')})';

String _releaseDate(Map r) {
  final d = DateTime.tryParse('${r['published_at']}')?.toLocal();
  return d == null ? '' : DateFormat('d MMM yyyy').format(d);
}

/// What people see of a release's notes in the app (the full notes stay on
/// GitHub): with an "In short" section, only the tagline above it and its
/// points; never "Check your download" (that's for GitHub downloads).
/// Releases written before "In short" existed show the rest as before.
String shortNotes(String notes) {
  bool heading(String l, String name) => l.trim().toLowerCase() == name;
  var lines = notes.split('\n');
  final check = lines.indexWhere((l) => heading(l, 'check your download'));
  if (check >= 0) lines = lines.sublist(0, check);
  final short = lines.indexWhere((l) => heading(l, 'in short'));
  if (short < 0) return lines.join('\n').trim();
  final points = <String>[];
  for (final l in lines.skip(short + 1)) {
    if (l.trim().isEmpty) {
      if (points.isEmpty) continue; // blank line right after the heading
      break;
    }
    if (!l.trimLeft().startsWith('-')) break; // the next heading
    points.add(l.trim());
  }
  return [lines.sublist(0, short).join('\n').trim(), points.join('\n')]
      .where((x) => x.isNotEmpty)
      .join('\n');
}

/// One release: its name and date, then its notes (the short version).
String _section(Map r) {
  var lines = '${r['body'] ?? ''}'
      .replaceAll(requiredMarker, '')
      .replaceAll('\r', '')
      .trim()
      .split('\n');
  if (_repeatedTitle.hasMatch(lines.first)) lines = lines.sublist(1);
  final date = _releaseDate(r);
  final notes = shortNotes(lines.join('\n')).trim();
  return '${_releaseName(r)}${date.isEmpty ? '' : ' · $date'}'
      '${notes.isEmpty ? '' : '\n$notes'}';
}

/// The update text: the build you have, the latest build (date and notes),
/// then any other builds you skipped. Empty when up to date.
/// [releases] is GitHub's release list; drafts and pre-releases don't count.
String notesSince(List releases, String currentVersion, int currentBuild) {
  String tag(Map r) => '${r['tag_name']}'.replaceFirst(RegExp('^[vV]'), '');
  final newer = [
    for (final r in releases.cast<Map>())
      if (r['draft'] != true &&
          r['prerelease'] != true &&
          isNewerTag(tag(r), currentVersion, currentBuild))
        r
  ]..sort((a, b) => _newerThan(tag(a), tag(b))
      ? -1
      : _newerThan(tag(b), tag(a))
          ? 1
          : 0);
  if (newer.isEmpty) return '';
  return [
    'Current build\nJARX $currentVersion (build $currentBuild)',
    'Latest build\n${_section(newer.first)}',
    if (newer.length > 1)
      'Also new since your build\n${newer.skip(1).map(_section).join('\n\n')}',
  ].join('\n\n');
}
