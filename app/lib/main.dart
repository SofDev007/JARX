import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api.dart';
import 'db.dart';
import 'library.dart';
import 'now_playing.dart';
import 'player.dart';
import 'search.dart';
import 'widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final cache = Cache();
  final api = Api(cache);
  final player = await AudioService.init(
    builder: () => Player(api, cache),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.jaiswal.jarx.playback',
      androidNotificationChannelName: 'Playback',
      // Android 12+ won't restart a foreground service from the background, which bites when
      // resuming after a long pause. Staying in the foreground while paused sidesteps it.
      // (No such restriction on Android 10-11, so this only matters on newer phones.)
      androidStopForegroundOnPause: false,
    ),
  );
  await player.restore();
  runApp(
    ProviderScope(
      overrides: [apiProvider.overrideWithValue(api), playerProvider.overrideWithValue(player)],
      retry: (_, _) => null, // show an error instead of quietly re-hitting the backend
      child: const JarxApp(),
    ),
  );
}

class JarxApp extends StatelessWidget {
  const JarxApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'JARX',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xFF7C4DFF), brightness: Brightness.dark),
      home: token.isEmpty
          ? const Scaffold(
              body: MessageView(
                icon: Icons.key_off,
                title: 'Built without a token',
                body: 'Build with --dart-define-from-file=.env (see app/README.md).',
              ),
            )
          : const Shell(),
    );
  }
}

class Shell extends ConsumerStatefulWidget {
  const Shell({super.key});

  @override
  ConsumerState<Shell> createState() => _ShellState();
}

class _ShellState extends ConsumerState<Shell> {
  int _tab = 0;
  late final StreamSubscription<String> _errors;

  @override
  void initState() {
    super.initState();
    _errors = ref.read(playerProvider).errors.listen((message) {
      if (mounted) toast(context, message);
    });
  }

  @override
  void dispose() {
    _errors.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _tab, children: const [SearchScreen(), LibraryScreen()]),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const MiniPlayer(),
          NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            destinations: const [
              NavigationDestination(icon: Icon(Icons.search), label: 'Search'),
              NavigationDestination(icon: Icon(Icons.library_music_outlined), selectedIcon: Icon(Icons.library_music), label: 'Library'),
            ],
          ),
        ],
      ),
    );
  }
}
