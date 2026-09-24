import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api.dart';
import 'player.dart';
import 'widgets.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  Timer? _debounce;
  String _query = '';

  void _search(String text, {bool now = false}) {
    _debounce?.cancel();
    void apply() => setState(() => _query = text.trim());
    now ? apply() : _debounce = Timer(const Duration(milliseconds: 500), apply);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: SearchBar(
              hintText: 'Songs, artists, albums',
              leading: const Icon(Icons.search),
              onChanged: _search,
              onSubmitted: (text) => _search(text, now: true),
            ),
          ),
          Expanded(
            child: _query.isEmpty
                ? const MessageView(
                    icon: Icons.library_music_outlined,
                    title: 'Search for music',
                    body: 'Plays from Audius, Jamendo and the Internet Archive. '
                        'Anything only YouTube has opens in the YouTube app.',
                  )
                : SearchResults(query: _query),
          ),
        ],
      ),
    );
  }
}

/// Every outcome of a search, including the one where only YouTube has the song. That's an
/// answer ("it exists, here's where"), so it gets its own banner rather than reading as an
/// empty or failed search.
class SearchResults extends ConsumerWidget {
  const SearchResults({required this.query, super.key});
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref
        .watch(searchProvider(query))
        .when(
          skipLoadingOnRefresh: false,
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => MessageView(
            icon: Icons.cloud_off,
            title: 'Search failed',
            body: '$e',
            action: FilledButton(onPressed: () => ref.invalidate(searchProvider(query)), child: const Text('Try again')),
          ),
          data: (results) {
            if (results.isEmpty) {
              return MessageView(
                icon: Icons.search_off,
                title: 'No matches',
                body: 'Nothing for “$query” on Audius, Jamendo, the Internet Archive or YouTube.',
              );
            }
            return ListView(
              children: [
                // The backend only asks YouTube when nothing playable matched confidently,
                // so a YouTube row on top means YouTube has the best version of this song.
                if (!results.first.playable)
                  YouTubeAnswer(query: query, alsoPlayable: results.any((t) => t.playable)),
                for (final (i, t) in results.indexed)
                  TrackTile(track: t, onPlay: () => ref.read(playerProvider).playTracks(results, i)),
              ],
            );
          },
        );
  }
}

class YouTubeAnswer extends StatelessWidget {
  const YouTubeAnswer({required this.query, required this.alsoPlayable, super.key});
  final String query;
  final bool alsoPlayable;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.smart_display, color: scheme.onSecondaryContainer, size: 32),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    alsoPlayable ? 'Best match is on YouTube' : 'Found on YouTube',
                    style: text.titleMedium?.copyWith(color: scheme.onSecondaryContainer),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    alsoPlayable
                        ? 'The playable versions below are likely covers or remixes. '
                              'Tap a YouTube result to open it in the YouTube app.'
                        : 'None of JARX’s music sources stream “$query”, but YouTube has it. '
                              'Tap a result to open it in the YouTube app.',
                    style: text.bodyMedium?.copyWith(color: scheme.onSecondaryContainer),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
