// Remote control between the phones signed in to one account. While JARX
// runs and is signed in, this phone keeps a WebSocket to the server
// (GET /remote, relayed by server/src/remote.js), tells it what it's playing
// whenever that changes, and does what another phone asks: play, pause,
// next, previous. The devices sheet lists the other phones.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show min;

import 'package:Bloomee/screens/widgets/snackbar.dart';
import 'package:Bloomee/services/account/account.dart';
import 'package:Bloomee/services/bloomee_player.dart';
import 'package:flutter/foundation.dart';

class RemoteDevice {
  const RemoteDevice(
      {required this.id,
      required this.name,
      this.title = '',
      this.artist = '',
      this.art = '',
      this.playing = false});

  factory RemoteDevice.fromJson(Map<String, dynamic> j) {
    final s = j['state'] is Map ? j['state'] as Map : const {};
    String str(Object? v) => v is String ? v : '';
    return RemoteDevice(
        id: str(j['id']),
        name: str(j['name']).isEmpty ? 'Phone' : str(j['name']),
        title: str(s['title']),
        artist: str(s['artist']),
        art: str(s['art']),
        playing: s['playing'] == true);
  }

  final String id, name, title, artist, art;
  final bool playing;
}

class RemoteControl {
  RemoteControl._();
  static final instance = RemoteControl._();

  /// The other phones of this account that have JARX open.
  final devices = ValueNotifier<List<RemoteDevice>>(const []);

  BloomeeMusicPlayer? _player;
  final _subs = <StreamSubscription<Object?>>[];
  WebSocket? _ws;
  String? _myId;
  String _lastSent = '';
  Timer? _retryTimer;
  int _retries = 0;
  bool _on = false;

  void start(BloomeeMusicPlayer player) {
    if (_on) return;
    _on = true;
    _player = player;
    _subs
      ..add(player.mediaItem.listen((_) => _sendState()))
      ..add(player.playbackState
          .map((s) => s.playing)
          .distinct()
          .listen((_) => _sendState()));
    _connect();
  }

  void stop() {
    _on = false;
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _retryTimer?.cancel();
    _ws?.close();
    _ws = null;
    devices.value = const [];
  }

  /// Reconnect now instead of waiting for the next retry (the devices sheet
  /// opened).
  void wake() {
    if (!_on || _ws != null) return;
    _retryTimer?.cancel();
    _connect();
  }

  /// Ask [to] to play, pause, go to the next or the previous song.
  void send(RemoteDevice to, String cmd) =>
      _ws?.add(jsonEncode({'t': 'cmd', 'to': to.id, 'cmd': cmd}));

  bool _connecting = false;
  Future<void> _connect() async {
    if (!_on || _ws != null || _connecting) return;
    _connecting = true;
    final ws = await Account.instance.socket('/remote');
    _connecting = false;
    if (!_on) {
      ws?.close();
      return;
    }
    if (ws == null) return _retryLater();
    _ws = ws..pingInterval = const Duration(seconds: 45);
    _retries = 0;
    _lastSent = '';
    ws.listen(_onMessage,
        onDone: () => _lost(ws), onError: (_) => _lost(ws), cancelOnError: true);
  }

  void _lost(WebSocket ws) {
    if (_ws != ws) return;
    _ws = null;
    devices.value = const [];
    _retryLater();
  }

  // 5 s, 10 s, 20 s … then every 5 minutes.
  void _retryLater() {
    if (!_on) return;
    _retryTimer?.cancel();
    _retryTimer = Timer(
        Duration(seconds: min(300, 5 << min(_retries++, 6))), _connect);
  }

  void _onMessage(dynamic raw) {
    final Map<String, dynamic> m;
    try {
      m = jsonDecode(raw as String) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (m['t']) {
      case 'hello':
        _myId = m['id'] as String?;
        _sendState();
      case 'devices':
        devices.value = [
          for (final d in (m['devices'] as List? ?? const []))
            if (d is Map<String, dynamic> && d['id'] != _myId)
              RemoteDevice.fromJson(d)
        ];
      case 'cmd':
        _run(m['cmd'] as String?, m['from'] as String? ?? 'Your other phone');
    }
  }

  void _run(String? cmd, String from) {
    final p = _player;
    if (p == null) return;
    switch (cmd) {
      case 'play':
        p.play();
      case 'pause':
        p.pause();
        SnackbarService.showMessage('Paused from $from');
      case 'next':
        p.skipToNext();
      case 'prev':
        p.skipToPrevious();
    }
  }

  void _sendState() {
    final ws = _ws, p = _player;
    if (ws == null || _myId == null || p == null) return;
    final item = p.mediaItem.value;
    final art = item?.artUri?.toString() ?? '';
    final msg = jsonEncode({
      't': 'state',
      'state': {
        'title': item?.title ?? '',
        'artist': item?.artist ?? '',
        // A downloaded song's cover is a file on this phone: no use there.
        'art': art.startsWith('http') ? art : '',
        'playing': p.playbackState.value.playing,
      }
    });
    if (msg == _lastSent) return;
    _lastSent = msg;
    ws.add(msg);
  }
}
