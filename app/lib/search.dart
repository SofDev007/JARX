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
                    body: 'Music plays in JARX unless a row says it opens elsewhere. '
                        'YouTube videos are listed separately and open in YouTube.',
                  )
                : SearchResults(query: _query),
          ),
        ],
      ),
    );
  }
}

/// Every outcome of a search. Music JARX plays comes first; YouTube videos, which play only
/// in YouTube, sit below a separator in their own section and are never queued.
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
          data: (r) {
            final videoNote = switch (r.videoError) {
              null => null,
              'quota_exceeded' => 'YouTube videos are unavailable: today’s YouTube search quota is used up.',
              _ => 'YouTube videos are unavailable right now.',
            };
            if (r.music.isEmpty && r.videos.isEmpty) {
              return MessageView(
                icon: Icons.search_off,
                title: 'No matches',
                body: ['Nothing for “$query”.', ?videoNote].join(' '),
              );
            }
            final muted = Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
            return ListView(
              children: [
                if (r.music.isEmpty) _Note('No music results for “$query”.', style: muted),
                for (final (i, t) in r.music.indexed)
                  TrackTile(track: t, onPlay: () => ref.read(playerProvider).playTracks(r.music, i)),
                if (r.videos.isNotEmpty) ...[
                  const Divider(height: 32),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                    child: Text('Video playback (ads included)', style: Theme.of(context).textTheme.titleSmall),
                  ),
                  for (final t in r.videos) TrackTile(track: t),
                ],
                if (videoNote != null) _Note(videoNote, style: muted),
              ],
            );
          },
        );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text, {this.style});
  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 12), child: Text(text, style: style));
}
