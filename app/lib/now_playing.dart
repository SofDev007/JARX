import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'player.dart';
import 'widgets.dart';

/// Playback position, ticking while playing. PlaybackState extrapolates between updates.
Stream<Duration> _position(Player p) =>
    Stream.periodic(const Duration(milliseconds: 250), (_) => p.playbackState.value.position);

/// The strip above the navigation bar. Hidden until something has been queued.
class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    return StreamBuilder<MediaItem?>(
      stream: player.mediaItem,
      builder: (context, snap) {
        final item = snap.data;
        if (item == null) return const SizedBox.shrink();
        return Material(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          child: InkWell(
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const NowPlayingScreen())),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                StreamBuilder<Duration>(
                  stream: _position(player),
                  builder: (_, pos) {
                    final total = item.duration?.inMilliseconds ?? 0;
                    final at = pos.data?.inMilliseconds ?? 0;
                    return LinearProgressIndicator(value: total > 0 ? (at / total).clamp(0.0, 1.0) : 0, minHeight: 2);
                  },
                ),
                ListTile(
                  leading: Artwork(item.artUri?.toString(), size: 40),
                  title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(item.artist ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _PlayPause(player),
                      IconButton(tooltip: 'Next', icon: const Icon(Icons.skip_next), onPressed: player.skipToNext),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _PlayPause extends StatelessWidget {
  const _PlayPause(this.player, {this.size = 24});
  final Player player;
  final double size;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PlaybackState>(
      stream: player.playbackState,
      builder: (_, snap) {
        final state = snap.data;
        final busy = state?.processingState == AudioProcessingState.loading ||
            state?.processingState == AudioProcessingState.buffering;
        if (busy && state?.playing == true) {
          return SizedBox.square(
            dimension: size + 24,
            child: const Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        final playing = state?.playing ?? false;
        return IconButton(
          tooltip: playing ? 'Pause' : 'Play',
          iconSize: size,
          icon: Icon(playing ? Icons.pause : Icons.play_arrow),
          onPressed: playing ? player.pause : player.play,
        );
      },
    );
  }
}

class NowPlayingScreen extends ConsumerWidget {
  const NowPlayingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Now playing')),
      body: StreamBuilder<MediaItem?>(
        stream: player.mediaItem,
        builder: (context, snap) {
          final item = snap.data;
          if (item == null) return const MessageView(icon: Icons.music_off, title: 'Nothing playing');
          return Column(
            children: [
              const SizedBox(height: 16),
              Artwork(item.artUri?.toString(), size: 240),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
                child: Column(
                  children: [
                    Text(item.title, style: text.titleLarge, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 4),
                    Text(item.artist ?? '', style: text.bodyLarge, textAlign: TextAlign.center),
                    // Rebuilt with each track, so favorite/add-to-playlist act on the current one.
                    if (player.current case final track?) TrackMenu(track),
                  ],
                ),
              ),
              _Seeker(player: player, duration: item.duration),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(tooltip: 'Previous', iconSize: 36, icon: const Icon(Icons.skip_previous), onPressed: player.skipToPrevious),
                  _PlayPause(player, size: 48),
                  IconButton(tooltip: 'Next', iconSize: 36, icon: const Icon(Icons.skip_next), onPressed: player.skipToNext),
                ],
              ),
              const Divider(height: 32),
              Expanded(child: _Queue(player: player)),
            ],
          );
        },
      ),
    );
  }
}

class _Seeker extends StatefulWidget {
  const _Seeker({required this.player, required this.duration});
  final Player player;
  final Duration? duration;

  @override
  State<_Seeker> createState() => _SeekerState();
}

class _SeekerState extends State<_Seeker> {
  double? _dragging; // milliseconds, while the thumb is held
  late final _ticks = _position(widget.player); // once, so a rebuild doesn't reset it to 0:00

  @override
  Widget build(BuildContext context) {
    final total = widget.duration?.inMilliseconds ?? 0;
    return StreamBuilder<Duration>(
      stream: _ticks,
      builder: (context, snap) {
        final at = _dragging ?? (snap.data?.inMilliseconds ?? 0).toDouble();
        final value = total > 0 ? at.clamp(0, total).toDouble() : 0.0;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            children: [
              Slider(
                max: total > 0 ? total.toDouble() : 1,
                value: value,
                onChanged: total > 0 ? (v) => setState(() => _dragging = v) : null,
                onChangeEnd: (v) {
                  widget.player.seek(Duration(milliseconds: v.round()));
                  setState(() => _dragging = null);
                },
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(formatDuration(Duration(milliseconds: value.round()))),
                    Text(total > 0 ? formatDuration(Duration(milliseconds: total)) : '--:--'),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Queue extends StatelessWidget {
  const _Queue({required this.player});
  final Player player;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<MediaItem>>(
      stream: player.queue,
      builder: (context, snap) {
        final items = snap.data ?? const [];
        final current = player.playbackState.value.queueIndex;
        return ListView.builder(
          itemCount: items.length,
          itemBuilder: (_, i) => ListTile(
            selected: i == current,
            leading: Artwork(items[i].artUri?.toString(), size: 40),
            title: Text(items[i].title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(items[i].artist ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () => player.skipToQueueItem(i),
          ),
        );
      },
    );
  }
}
