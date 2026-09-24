import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';

const sourceNames = {'audius': 'Audius', 'jamendo': 'Jamendo', 'archive': 'Internet Archive', 'youtube': 'YouTube'};

String formatDuration(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

void toast(BuildContext context, String message) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));

/// Opens a YouTube row in the YouTube app. On Android 11+ the first attempt refuses
/// browsers, so the app wins when it's installed; the second falls back to a browser.
Future<void> openOnYouTube(BuildContext context, Track t) async {
  final link = t.deepLink;
  if (link == null) return;
  final uri = Uri.parse(link);
  final opened =
      await launchUrl(uri, mode: LaunchMode.externalNonBrowserApplication) ||
      await launchUrl(uri, mode: LaunchMode.externalApplication);
  if (!opened && context.mounted) toast(context, "Couldn't open YouTube");
}

class Artwork extends StatelessWidget {
  const Artwork(this.url, {this.size = 48, super.key});
  final String? url;
  final double size;

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      width: size,
      height: size,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(Icons.music_note, size: size * 0.5),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(size / 8),
      child: url == null
          ? placeholder
          : Image.network(url!, width: size, height: size, fit: BoxFit.cover, errorBuilder: (_, _, _) => placeholder),
    );
  }
}

/// One row for a track anywhere in the app. Playable rows call [onPlay]; YouTube rows are
/// visibly different and open the YouTube app instead of the player.
class TrackTile extends StatelessWidget {
  const TrackTile({required this.track, required this.onPlay, this.selected = false, this.menu = true, super.key});
  final Track track;
  final VoidCallback onPlay;
  final bool selected, menu;

  @override
  Widget build(BuildContext context) {
    final t = track;
    final details = [
      if (t.artist.isNotEmpty) t.artist,
      if (t.playable) sourceNames[t.source] ?? t.source else 'YouTube · not streamable',
      if (t.durationMs != null) formatDuration(Duration(milliseconds: t.durationMs!)),
    ];
    return ListTile(
      selected: selected,
      leading: t.playable
          ? Artwork(t.artworkUrl)
          : Stack(
              children: [
                Opacity(opacity: 0.6, child: Artwork(t.artworkUrl)),
                const Positioned.fill(child: Icon(Icons.smart_display, color: Colors.white)),
              ],
            ),
      title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(details.join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!t.playable)
            TextButton.icon(
              onPressed: () => openOnYouTube(context, t),
              icon: const Icon(Icons.open_in_new, size: 18),
              label: const Text('YouTube'),
            ),
          if (menu) TrackMenu(t),
        ],
      ),
      onTap: t.playable ? onPlay : () => openOnYouTube(context, t),
    );
  }
}

/// Favorite and add-to-playlist actions for a track.
class TrackMenu extends ConsumerWidget {
  const TrackMenu(this.track, {super.key});
  final Track track;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isFavorite = ref.watch(favoritesProvider).value?.any((f) => f.id == track.id) ?? false;
    return PopupMenuButton<VoidCallback>(
      tooltip: 'More',
      onSelected: (action) => action(),
      itemBuilder: (_) => [
        PopupMenuItem(
          value: () => _toggleFavorite(context, ref, isFavorite),
          child: Text(isFavorite ? 'Remove from favorites' : 'Add to favorites'),
        ),
        PopupMenuItem(value: () => addToPlaylist(context, ref, track), child: const Text('Add to playlist…')),
      ],
    );
  }

  Future<void> _toggleFavorite(BuildContext context, WidgetRef ref, bool isFavorite) async {
    final api = ref.read(apiProvider);
    try {
      await (isFavorite ? api.unfavorite(track) : api.favorite(track));
      ref.invalidate(favoritesProvider);
      if (context.mounted) toast(context, isFavorite ? 'Removed from favorites' : 'Added to favorites');
    } on ApiException catch (e) {
      if (context.mounted) toast(context, e.message);
    }
  }
}

/// Picks a playlist (or makes a new one) and appends [track] to it.
Future<void> addToPlaylist(BuildContext context, WidgetRef ref, Track track) async {
  final picked = await showDialog<(String, String)>(context: context, builder: (_) => const _PlaylistPicker());
  if (picked == null) return;
  final (id, name) = picked;
  try {
    await ref.read(apiProvider).addTracks(id, [track]);
    ref
      ..invalidate(playlistsProvider)
      ..invalidate(playlistProvider(id));
    if (context.mounted) toast(context, 'Added to $name');
  } on ApiException catch (e) {
    if (context.mounted) toast(context, e.message);
  }
}

/// Returns the chosen playlist as (id, name).
class _PlaylistPicker extends ConsumerWidget {
  const _PlaylistPicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SimpleDialog(
      title: const Text('Add to playlist'),
      children: [
        SimpleDialogOption(
          onPressed: () async {
            final name = await promptText(context, title: 'New playlist', action: 'Create');
            if (name == null || !context.mounted) return;
            try {
              final id = await ref.read(apiProvider).createPlaylist(name);
              if (context.mounted) Navigator.pop(context, (id, name));
            } on ApiException catch (e) {
              if (context.mounted) toast(context, e.message);
            }
          },
          child: const ListTile(leading: Icon(Icons.add), title: Text('New playlist…')),
        ),
        ...switch (ref.watch(playlistsProvider)) {
          AsyncData(:final value) => [
            for (final p in value)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, (p.id, p.name)),
                child: ListTile(title: Text(p.name), subtitle: Text('${p.trackCount} tracks')),
              ),
          ],
          AsyncError(:final error) => [Padding(padding: const EdgeInsets.all(24), child: Text('$error'))],
          _ => [const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))],
        },
      ],
    );
  }
}

/// A one-field dialog; returns the trimmed text, or null if cancelled or empty.
Future<String?> promptText(BuildContext context, {required String title, required String action, String initial = ''}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) {
      void submit() {
        final text = controller.text.trim();
        Navigator.pop(context, text.isEmpty ? null : text);
      }

      return AlertDialog(
        title: Text(title),
        content: TextField(controller: controller, autofocus: true, onSubmitted: (_) => submit()),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: submit, child: Text(action)),
        ],
      );
    },
  );
}

/// A centered icon, title and explanation, for empty, error and hint states.
class MessageView extends StatelessWidget {
  const MessageView({required this.icon, required this.title, this.body, this.action, super.key});
  final IconData icon;
  final String title;
  final String? body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48),
            const SizedBox(height: 16),
            Text(title, style: text.titleMedium, textAlign: TextAlign.center),
            if (body != null) ...[
              const SizedBox(height: 8),
              Text(body!, style: text.bodyMedium, textAlign: TextAlign.center),
            ],
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}
