// The player's device bar ("THIS PHONE · realme 5 Pro", or the Bluetooth
// headphones' name) and the "Playing on" sheet it opens. The sheet keeps a
// place for the user's other devices (cross-device control comes later).

import 'dart:async';
import 'dart:io';

import 'package:Bloomee/core/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Where the sound goes: [kind] is bluetooth, wired, usb or phone.
class AudioOutput {
  const AudioOutput(this.kind, this.name, this.phone);
  final String kind, name, phone;

  static const _channel = MethodChannel('jarx/app');

  static Future<AudioOutput> now() async {
    if (!Platform.isAndroid) {
      return const AudioOutput('phone', 'This device', 'This device');
    }
    try {
      final m = await _channel.invokeMapMethod<String, String>('audioOutput');
      return AudioOutput(
          m?['kind'] ?? 'phone', m?['name'] ?? 'This phone', m?['phone'] ?? '');
    } catch (_) {
      return const AudioOutput('phone', 'This phone', '');
    }
  }

  static Future<void> openPicker() async {
    try {
      await _channel.invokeMethod('outputPicker');
    } catch (_) {}
  }

  bool get onPhone => kind == 'phone';

  IconData get icon => switch (kind) {
        'bluetooth' => Icons.bluetooth_audio_rounded,
        'wired' || 'usb' => Icons.headphones_rounded,
        _ => Icons.speaker_rounded,
      };

  @override
  bool operator ==(Object o) =>
      o is AudioOutput && o.kind == kind && o.name == name && o.phone == phone;

  @override
  int get hashCode => Object.hash(kind, name, phone);
}

/// Bottom of the player: the speaker icon and where the music plays.
class DeviceBar extends StatefulWidget {
  const DeviceBar({super.key});

  @override
  State<DeviceBar> createState() => _DeviceBarState();
}

class _DeviceBarState extends State<DeviceBar> with WidgetsBindingObserver {
  AudioOutput? _out;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
    // ponytail: polls every 3 s while the player is open; an Android
    // AudioDeviceCallback would push changes if this ever costs too much.
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) _refresh();
  }

  @override
  void dispose() {
    _poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _refresh() async {
    final out = await AudioOutput.now();
    if (mounted && out != _out) setState(() => _out = out);
  }

  @override
  Widget build(BuildContext context) {
    final out = _out;
    final label = out == null
        ? ''
        : out.onPhone
            ? 'THIS PHONE'
            : out.name.toUpperCase();
    final sub = out == null
        ? ''
        : out.onPhone
            ? out.name
            : out.phone;
    return Semantics(
      button: true,
      label: 'Playing on $label. Show devices',
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () async {
          await showDevicesSheet(context);
          _refresh();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          child: Row(children: [
            Icon(out?.icon ?? Icons.speaker_rounded,
                color: Default_Theme.accentColor2, size: 20),
            const SizedBox(width: 8),
            // Fills the bar: the devices icon sits at the right edge.
            Expanded(
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(
                      text: label,
                      style: const TextStyle(
                          color: Default_Theme.accentColor2,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.6)),
                  if (sub.isNotEmpty)
                    TextSpan(
                        text: '  ·  $sub',
                        style: TextStyle(
                            color: Default_Theme.primaryColor2
                                .withValues(alpha: 0.55),
                            fontSize: 11.5)),
                ]),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.devices_rounded,
                size: 20,
                color: Default_Theme.primaryColor1.withValues(alpha: 0.8)),
          ]),
        ),
      ),
    );
  }
}

/// "Playing on": the current output, the phone's speaker, Android's
/// output picker, and (later) the user's other devices.
Future<void> showDevicesSheet(BuildContext context) async {
  final out = await AudioOutput.now();
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: const Color(0xFF1B1022),
    showDragHandle: true,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Playing on',
                style: TextStyle(
                    color: Default_Theme.primaryColor1,
                    fontSize: 20,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 14),
            _NowCard(out),
            const _Section('ON THIS PHONE'),
            if (!out.onPhone)
              _Row(
                icon: Icons.smartphone_rounded,
                title: 'Phone speaker',
                sub: out.phone,
                note: 'Disconnect ${out.name} to switch back',
              ),
            _Row(
              icon: Icons.bluetooth_rounded,
              title: 'Switch speaker or headphones',
              sub: "Opens Android's Bluetooth and output picker",
              onTap: () {
                Navigator.pop(context);
                AudioOutput.openPicker();
              },
            ),
            const _Section('YOUR OTHER DEVICES'),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF4A3D52), width: 1.5),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Control JARX on your other phones',
                      style: TextStyle(
                          color: Default_Theme.primaryColor1,
                          fontSize: 14,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(
                      'Phones signed in to your account will show here, so you '
                      'can play and pause on them from this one. Coming in a '
                      'later update.',
                      style: TextStyle(
                          color: Default_Theme.primaryColor2
                              .withValues(alpha: 0.6),
                          fontSize: 12.5,
                          height: 1.45)),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _NowCard extends StatelessWidget {
  const _NowCard(this.out);
  final AudioOutput out;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: Default_Theme.accentColor2.withValues(alpha: 0.12),
          border: Border.all(
              color: Default_Theme.accentColor2.withValues(alpha: 0.45)),
        ),
        child: Row(children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: Default_Theme.accentColor2.withValues(alpha: 0.2),
            ),
            child: Icon(out.onPhone ? Icons.smartphone_rounded : out.icon,
                color: Default_Theme.accentColor2),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(out.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Default_Theme.primaryColor1,
                        fontSize: 15,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(
                    switch (out.kind) {
                      'bluetooth' => 'Bluetooth · on ${out.phone}',
                      'wired' => 'Headphones · on ${out.phone}',
                      'usb' => 'USB · on ${out.phone}',
                      _ => 'This phone · speaker',
                    },
                    style: const TextStyle(
                        color: Default_Theme.accentColor2, fontSize: 12)),
              ],
            ),
          ),
          const Icon(Icons.graphic_eq_rounded,
              color: Default_Theme.accentColor2),
        ]),
      );
}

class _Section extends StatelessWidget {
  const _Section(this.label);
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 6),
        child: Text(label,
            style: TextStyle(
                color: Default_Theme.primaryColor2.withValues(alpha: 0.55),
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1)),
      );
}

class _Row extends StatelessWidget {
  const _Row(
      {required this.icon,
      required this.title,
      required this.sub,
      this.note,
      this.onTap});
  final IconData icon;
  final String title, sub;
  final String? note;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          child: Row(children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: Colors.white.withValues(alpha: 0.06),
              ),
              child: Icon(icon, color: Default_Theme.primaryColor1, size: 21),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          color: Default_Theme.primaryColor1,
                          fontSize: 14,
                          fontWeight: FontWeight.w600)),
                  Text(note ?? sub,
                      style: TextStyle(
                          color:
                              Default_Theme.primaryColor2.withValues(alpha: 0.6),
                          fontSize: 12)),
                ],
              ),
            ),
          ]),
        ),
      );
}
