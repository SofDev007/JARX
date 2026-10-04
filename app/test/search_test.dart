import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarx/api.dart';
import 'package:jarx/player.dart';
import 'package:jarx/search.dart';
import 'package:jarx/widgets.dart';

const _videoLabel = 'Video playback (ads included)';

Track _song(String id) => Track(
  source: 'audius',
  sourceId: id,
  title: 'Song $id',
  artist: 'Artist $id',
  playable: true,
  streamUrl: 'https://cdn.example/$id.mp3',
);

Track _video(String id) => Track(
  source: 'youtube',
  sourceId: id,
  title: 'Video $id',
  artist: 'Channel $id',
  playable: false,
  deepLink: 'https://www.youtube.com/watch?v=$id',
);

SearchAnswer _answer({List<Track> music = const [], List<Track> videos = const [], String? videoError}) =>
    (music: music, videos: videos, videoError: videoError);

/// Records what the search screen asks the JARX player to play; nothing else is needed here.
class _FakePlayer implements Player {
  final played = <(List<Track>, int)>[];

  @override
  Future<void> playTracks(List<Track> list, int start) async => played.add((list, start));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Renders the results for "q" with the search endpoint answering [answer].
Future<_FakePlayer> _pump(WidgetTester tester, Future<SearchAnswer> Function() answer) async {
  final player = _FakePlayer();
  await tester.pumpWidget(
    ProviderScope(
      retry: (_, _) => null,
      overrides: [
        searchProvider.overrideWith((ref, q) => answer()),
        favoritesProvider.overrideWith((ref) async => const []),
        playerProvider.overrideWithValue(player),
      ],
      child: const MaterialApp(home: Scaffold(body: SearchResults(query: 'q'))),
    ),
  );
  await tester.pumpAndSettle();
  return player;
}

double _top(WidgetTester tester, Finder f) => tester.getTopLeft(f).dy;

void main() {
  final music = [_song('a'), _song('b')];
  final videos = [_video('v1'), _video('v2')];

  testWidgets('music comes first, YouTube videos sit below a separator in their own section', (tester) async {
    await _pump(tester, () async => _answer(music: music, videos: videos));

    expect(find.text(_videoLabel), findsOneWidget);
    expect(find.byType(Divider), findsOneWidget);
    expect(_top(tester, find.text('Song b')), lessThan(_top(tester, find.byType(Divider))));
    expect(_top(tester, find.byType(Divider)), lessThan(_top(tester, find.text(_videoLabel))));
    expect(_top(tester, find.text(_videoLabel)), lessThan(_top(tester, find.text('Video v1'))));
  });

  testWidgets('no separator or video label without YouTube results', (tester) async {
    await _pump(tester, () async => _answer(music: music));

    expect(find.text('Song a'), findsOneWidget);
    expect(find.text(_videoLabel), findsNothing);
    expect(find.byType(Divider), findsNothing);
  });

  testWidgets('YouTube rows carry the Y badge and say they play on YouTube; music rows do not', (tester) async {
    await _pump(tester, () async => _answer(music: music, videos: videos));

    expect(find.descendant(of: find.byType(SourceBadge), matching: find.text('Y')), findsNWidgets(2));
    expect(find.text('Watch on YouTube'), findsNWidgets(2));
    expect(find.text('Video v1'), findsOneWidget); // the provider stays out of the title
    expect(find.descendant(of: find.widgetWithText(ListTile, 'Song a'), matching: find.byType(SourceBadge)), findsNothing);
    expect(find.descendant(of: find.widgetWithText(ListTile, 'Song a'), matching: find.textContaining('Audius')), findsOneWidget);
  });

  testWidgets('tapping a YouTube row hands off to YouTube and never reaches the player', (tester) async {
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    final launched = <Map<Object?, Object?>>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      launched.add(call.arguments as Map<Object?, Object?>);
      return true;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    final player = await _pump(tester, () async => _answer(music: music, videos: videos));

    await tester.tap(find.text('Video v1'));
    await tester.pumpAndSettle();

    expect(launched, hasLength(1));
    expect(launched.single['url'], 'https://www.youtube.com/watch?v=v1');
    expect(launched.single['universalLinksOnly'], isTrue); // the YouTube app first, as before
    expect(player.played, isEmpty);
  });

  testWidgets('tapping a music row plays it in JARX, queueing only the music', (tester) async {
    final player = await _pump(tester, () async => _answer(music: music, videos: videos));

    await tester.tap(find.text('Song b'));
    await tester.pumpAndSettle();

    expect(player.played, hasLength(1));
    final (queue, start) = player.played.single;
    expect(queue.map((t) => t.id), ['audius:a', 'audius:b']);
    expect(start, 1);
  });

  testWidgets('only videos: says there is no music, then shows the video section', (tester) async {
    await _pump(tester, () async => _answer(videos: videos));

    expect(find.text('No music results for “q”.'), findsOneWidget);
    expect(find.text(_videoLabel), findsOneWidget);
    expect(find.text('No matches'), findsNothing);
    expect(find.text('Search failed'), findsNothing);
  });

  testWidgets('says when YouTube’s quota is spent instead of silently dropping videos', (tester) async {
    await _pump(tester, () async => _answer(music: music, videoError: 'quota_exceeded'));

    expect(find.textContaining('quota is used up'), findsOneWidget);
    expect(find.text(_videoLabel), findsNothing);
    expect(find.text('Song a'), findsOneWidget);
  });

  testWidgets('no results at all is its own state', (tester) async {
    await _pump(tester, () async => _answer());

    expect(find.text('No matches'), findsOneWidget);
    expect(find.text(_videoLabel), findsNothing);
  });

  testWidgets('a failed search explains itself and can be retried', (tester) async {
    var calls = 0;
    await _pump(tester, () async {
      calls++;
      throw const ApiException('offline', "Can't reach the JARX server");
    });

    expect(find.text('Search failed'), findsOneWidget);
    expect(find.text("Can't reach the JARX server"), findsOneWidget);

    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(calls, 2);
  });

  testWidgets('shows progress while searching', (tester) async {
    final player = _FakePlayer();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          searchProvider.overrideWith((ref, q) => Future.delayed(const Duration(seconds: 1), _answer)),
          playerProvider.overrideWithValue(player),
        ],
        child: const MaterialApp(home: Scaffold(body: SearchResults(query: 'q'))),
      ),
    );
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pumpAndSettle();
  });
}
