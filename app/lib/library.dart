import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api.dart';
import 'now_playing.dart';
import 'player.dart';
import 'widgets.dart';

class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlists = ref.watch(playlistsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Library'),
        actions: [
          IconButton(
            tooltip: 'Import playlist',
            icon: const Icon(Icons.file_upload_outlined),
            onPressed: () => importPlaylist(context, ref),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'New playlist',
        onPressed: () => _create(context, ref),
        child: const Icon(Icons.playlist_add),
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(playlistsProvider.future),
        child: ListView(
          children: [
            ListTile(
              leading: const Icon(Icons.favorite),
              title: const Text('Favorites'),
              onTap: () => _open(context, TrackListScreen(title: 'Favorites', provider: favoritesProvider)),
            ),
            ListTile(
              leading: const Icon(Icons.history),
              title: const Text('Recently played'),
              onTap: () => _open(context, TrackListScreen(title: 'Recently played', provider: recentsProvider)),
            ),
            const Divider(),
            ...switch (playlists) {
              AsyncData(:final value) when value.isEmpty => [
                const MessageView(
                  icon: Icons.queue_music,
                  title: 'No playlists yet',
                  body: 'Create one with +, or import an Exportify CSV.',
                ),
              ],
              AsyncData(:final value) => [
                for (final p in value)
                  ListTile(
                    leading: const Icon(Icons.queue_music),
                    title: Text(p.name),
                    subtitle: Text('${p.trackCount} tracks'),
                    onTap: () => _open(context, PlaylistScreen(id: p.id)),
                  ),
              ],
              AsyncError(:final error) => [
                MessageView(
                  icon: Icons.cloud_off,
                  title: "Couldn't load playlists",
                  body: '$error',
                  action: FilledButton(
                    onPressed: () => ref.invalidate(playlistsProvider),
                    child: const Text('Try again'),
                  ),
                ),
              ],
              _ => [const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))],
            },
          ],
        ),
      ),
    );
  }

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final name = await promptText(context, title: 'New playlist', action: 'Create');
    if (name == null) return;
    try {
      await ref.read(apiProvider).createPlaylist(name);
      ref.invalidate(playlistsProvider);
    } on ApiException catch (e) {
      if (context.mounted) toast(context, e.message);
    }
  }
}

void _open(BuildContext context, Widget screen) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));

/// Favorites or history: a read-only list that plays from the tapped track.
class TrackListScreen extends ConsumerWidget {
  const TrackListScreen({required this.title, required this.provider, super.key});
  final String title;
  final FutureProvider<List<Track>> provider;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      bottomNavigationBar: const MiniPlayer(),
      body: switch (ref.watch(provider)) {
        AsyncData(:final value) when value.isEmpty => const MessageView(icon: Icons.music_off, title: 'Nothing here yet'),
        AsyncData(:final value) => RefreshIndicator(
          onRefresh: () => ref.refresh(provider.future),
          child: ListView(
            children: [
              for (final (i, t) in value.indexed)
                TrackTile(track: t, onPlay: () => ref.read(playerProvider).playTracks(value, i)),
            ],
          ),
        ),
        AsyncError(:final error) => MessageView(icon: Icons.cloud_off, title: "Couldn't load", body: '$error'),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}

class PlaylistScreen extends ConsumerStatefulWidget {
  const PlaylistScreen({required this.id, super.key});
  final String id;

  @override
  ConsumerState<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends ConsumerState<PlaylistScreen> {
  /// Shown while a reorder or removal is in flight, so the list doesn't snap back to the
  /// old order until the server's copy arrives.
  List<Track>? _pending;

  @override
  Widget build(BuildContext context) {
    final provider = playlistProvider(widget.id);
    ref.listen(provider, (_, next) {
      if (next is AsyncData) setState(() => _pending = null);
    });
    return switch (ref.watch(provider)) {
      AsyncValue(:final value?) => _build(value, _pending ?? value.tracks),
      AsyncError(:final error) => Scaffold(
        appBar: AppBar(),
        body: MessageView(icon: Icons.cloud_off, title: "Couldn't load playlist", body: '$error'),
      ),
      _ => Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator())),
    };
  }

  Widget _build(Playlist p, List<Track> tracks) {
    final player = ref.read(playerProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(p.name),
        actions: [
          if (tracks.any((t) => t.playable))
            IconButton(tooltip: 'Play', icon: const Icon(Icons.play_arrow), onPressed: () => player.playTracks(tracks, tracks.indexWhere((t) => t.playable))),
          PopupMenuButton<String>(
            onSelected: (action) => action == 'rename' ? _rename(p) : _delete(p),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'rename', child: Text('Rename')),
              PopupMenuItem(value: 'delete', child: Text('Delete playlist')),
            ],
          ),
        ],
      ),
      bottomNavigationBar: const MiniPlayer(),
      body: tracks.isEmpty
          ? const MessageView(icon: Icons.music_off, title: 'Empty playlist', body: 'Add tracks from search with ⋮.')
          : ReorderableListView.builder(
              itemCount: tracks.length,
              onReorderItem: (from, to) => _move(tracks, from, to), // to is already the final index
              itemBuilder: (context, i) => Dismissible(
                key: ObjectKey(tracks[i]), // per entry instance: stays unique when a playlist repeats a track
                direction: DismissDirection.endToStart,
                background: Container(
                  color: Theme.of(context).colorScheme.errorContainer,
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 24),
                  child: const Icon(Icons.delete_outline),
                ),
                onDismissed: (_) => _remove(tracks, i),
                child: TrackTile(track: tracks[i], onPlay: () => player.playTracks(tracks, i)),
              ),
            ),
    );
  }

  Future<void> _move(List<Track> tracks, int from, int to) {
    if (from == to) return Future.value();
    final next = [...tracks];
    next.insert(to, next.removeAt(from));
    setState(() => _pending = next);
    return _sync(() => ref.read(apiProvider).reorder(widget.id, from, to));
  }

  Future<void> _remove(List<Track> tracks, int i) {
    setState(() => _pending = [...tracks]..removeAt(i));
    return _sync(() => ref.read(apiProvider).removeTrack(widget.id, i));
  }

  /// Runs a mutation, then reloads the server's copy either way; on failure that also
  /// undoes the optimistic change.
  Future<void> _sync(Future<void> Function() mutation) async {
    try {
      await mutation();
    } on ApiException catch (e) {
      if (mounted) toast(context, e.message);
    }
    ref
      ..invalidate(playlistProvider(widget.id))
      ..invalidate(playlistsProvider);
  }

  Future<void> _rename(Playlist p) async {
    final name = await promptText(context, title: 'Rename playlist', action: 'Rename', initial: p.name);
    if (name != null) await _sync(() => ref.read(apiProvider).renamePlaylist(p.id, name));
  }

  Future<void> _delete(Playlist p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete “${p.name}”?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(apiProvider).deletePlaylist(p.id);
      ref.invalidate(playlistsProvider);
      if (mounted) Navigator.pop(context);
    } on ApiException catch (e) {
      if (mounted) toast(context, e.message);
    }
  }
}

/// Picks an Exportify CSV or a "title - artist" text file and imports it in chunks.
Future<void> importPlaylist(BuildContext context, WidgetRef ref) async {
  final file = await FilePicker.pickFile(dialogTitle: 'Import playlist');
  if (file == null || !context.mounted) return;
  final chunks = importChunks(utf8.decode(await file.readAsBytes(), allowMalformed: true));
  if (!context.mounted) return;
  if (chunks.isEmpty) {
    toast(context, 'That file has no rows to import');
    return;
  }
  final name = file.name.replaceFirst(RegExp(r'\.(csv|txt)$', caseSensitive: false), '');
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ImportDialog(name: name, chunks: chunks),
  );
  ref.invalidate(playlistsProvider);
}

class _ImportDialog extends ConsumerStatefulWidget {
  const _ImportDialog({required this.name, required this.chunks});
  final String name;
  final List<String> chunks;

  @override
  ConsumerState<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends ConsumerState<_ImportDialog> {
  int _done = 0, _matched = 0;
  final _unmatched = <String>[];
  String? _error;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final api = ref.read(apiProvider);
    String? playlistId;
    try {
      for (final (i, chunk) in widget.chunks.indexed) {
        // Staying on the Workers Free plan: space the requests out rather than pay for more.
        if (i > 0) await Future<void>.delayed(const Duration(seconds: 1));
        final r = await api.importChunk(chunk, name: widget.name, playlistId: playlistId);
        playlistId = r.playlistId;
        if (!mounted) return;
        setState(() {
          _done++;
          _matched += r.matched;
          _unmatched.addAll(r.unmatched);
        });
      }
    } on ApiException catch (e) {
      _error = e.message;
    }
    if (mounted) setState(() => _finished = true);
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.chunks.length;
    return AlertDialog(
      title: Text(_finished ? 'Imported “${widget.name}”' : 'Importing “${widget.name}”'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!_finished) ...[
              LinearProgressIndicator(value: _done / total),
              const SizedBox(height: 12),
              Text('Batch ${_done + 1} of $total · $_matched matched so far'),
            ] else ...[
              Text('$_matched playable. ${_unmatched.length} not found on Audius or Jamendo; '
                  'those were added as YouTube links.'),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text('Stopped early: $_error', style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
              if (_unmatched.isNotEmpty)
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [for (final u in _unmatched) ListTile(dense: true, title: Text(u))],
                  ),
                ),
            ],
          ],
        ),
      ),
      actions: [if (_finished) FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))],
    );
  }
}
