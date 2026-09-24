import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarx/api.dart';
import 'package:jarx/search.dart';

Track _track(String id, {required bool playable}) => Track(
  source: playable ? 'audius' : 'youtube',
  sourceId: id,
  title: 'Song $id',
  artist: 'Artist $id',
  playable: playable,
  deepLink: playable ? null : 'https://www.youtube.com/watch?v=$id',
);

/// Renders the results for "q" with the search endpoint answering [answer].
Future<void> _pump(WidgetTester tester, Future<List<Track>> Function() answer) => tester.pumpWidget(
  ProviderScope(
    retry: (_, _) => null,
    overrides: [
      searchProvider.overrideWith((ref, q) => answer()),
      favoritesProvider.overrideWith((ref) async => const []),
    ],
    child: const MaterialApp(home: Scaffold(body: SearchResults(query: 'q'))),
  ),
);

void main() {
  testWidgets('only-YouTube results read as an answer, not a failure', (tester) async {
    await _pump(tester, () async => [_track('a', playable: false), _track('b', playable: false)]);
    await tester.pumpAndSettle();

    expect(find.text('Found on YouTube'), findsOneWidget);
    expect(find.textContaining('YouTube has it'), findsOneWidget);
    expect(find.text('YouTube'), findsNWidgets(2)); // an "open" button on every row
    expect(find.text('Song a'), findsOneWidget);
    expect(find.text('No matches'), findsNothing);
    expect(find.text('Search failed'), findsNothing);
  });

  testWidgets('a YouTube best match above playable ones says the playable ones may be covers', (tester) async {
    await _pump(tester, () async => [_track('a', playable: false), _track('b', playable: true)]);
    await tester.pumpAndSettle();

    expect(find.text('Best match is on YouTube'), findsOneWidget);
    expect(find.textContaining('covers or remixes'), findsOneWidget);
  });

  testWidgets('a playable best match shows no YouTube banner', (tester) async {
    await _pump(tester, () async => [_track('a', playable: true), _track('b', playable: false)]);
    await tester.pumpAndSettle();

    expect(find.text('Found on YouTube'), findsNothing);
    expect(find.text('Best match is on YouTube'), findsNothing);
    expect(find.text('Song a'), findsOneWidget);
  });

  testWidgets('no results at all is its own state', (tester) async {
    await _pump(tester, () async => const []);
    await tester.pumpAndSettle();

    expect(find.text('No matches'), findsOneWidget);
    expect(find.text('Found on YouTube'), findsNothing);
  });

  testWidgets('a failed search explains itself and can be retried', (tester) async {
    var calls = 0;
    await _pump(tester, () async {
      calls++;
      throw const ApiException('offline', "Can't reach the JARX server");
    });
    await tester.pumpAndSettle();

    expect(find.text('Search failed'), findsOneWidget);
    expect(find.text("Can't reach the JARX server"), findsOneWidget);

    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(calls, 2);
  });

  testWidgets('shows progress while searching', (tester) async {
    await _pump(tester, () => Future.delayed(const Duration(seconds: 1), () => const []));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pumpAndSettle();
  });
}
