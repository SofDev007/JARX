// Settings › Jarvix: the switch (turning it on by hand lights the screen's
// edges), what Jarvix can do, and what it keeps about you.

import 'package:Bloomee/core/theme/app_theme.dart';
import 'package:Bloomee/screens/screen/home_views/setting_views/setting_shared_widgets.dart';
import 'package:Bloomee/screens/screen/saathi_chat.dart';
import 'package:Bloomee/screens/widgets/edge_glow.dart';
import 'package:Bloomee/screens/widgets/saathi_blob.dart';
import 'package:Bloomee/services/ai/saathi.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class JarvixSettingView extends StatefulWidget {
  const JarvixSettingView({super.key});

  @override
  State<JarvixSettingView> createState() => _JarvixSettingViewState();
}

class _JarvixSettingViewState extends State<JarvixSettingView> {
  final saathi = Saathi.instance;

  @override
  void initState() {
    super.initState();
    saathi.load().then((_) => mounted ? setState(() {}) : null);
  }

  Future<void> _switch(bool on) async {
    await saathi.setOn(on);
    if (!mounted) return;
    setState(() {});
    if (on) {
      HapticFeedback.mediumImpact();
      showEdgeGlow(context); // only when turned on by hand, here
    }
  }

  Future<void> _clearChat() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: Default_Theme.themeColor,
        title: const Text('Clear the chat?',
            style: TextStyle(color: Colors.white, fontSize: 18)),
        content: Text(
            'Your messages with $saathiName go. What it remembers about '
            'your taste stays (you can edit that separately).',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.7))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Keep it',
                  style: TextStyle(color: Default_Theme.primaryColor1))),
          TextButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Clear',
                  style: TextStyle(
                      color: Default_Theme.accentColor2,
                      fontWeight: FontWeight.bold))),
        ],
      ),
    );
    if (ok == true) {
      await saathi.clearChat();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Chat cleared')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final on = !saathi.state.off;
    return Scaffold(
      backgroundColor: Default_Theme.themeColor,
      appBar: AppBar(
        backgroundColor: Default_Theme.themeColor,
        surfaceTintColor: Colors.transparent,
        iconTheme: const IconThemeData(color: Default_Theme.primaryColor1),
        title: const Text(saathiName,
            style: TextStyle(
                color: Default_Theme.primaryColor1,
                fontWeight: FontWeight.w700)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
        children: [
          Center(
            child: Column(children: [
              AnimatedOpacity(
                duration: const Duration(milliseconds: 300),
                opacity: on ? 1 : 0.35,
                child: SaathiBlob(
                    size: 84,
                    colors: moodColors(null),
                    state: on ? BlobState.paused : BlobState.offline),
              ),
              const SizedBox(height: 10),
              const Text(saathiName,
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.w800)),
              const Text(saathiFullForm,
                  style: TextStyle(
                      color: Colors.white54,
                      fontSize: 13,
                      fontStyle: FontStyle.italic)),
              const SizedBox(height: 6),
              Text('Your music buddy inside JARX.',
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.7),
                      fontSize: 14)),
            ]),
          ),
          const SizedBox(height: 20),
          const SettingSectionHeader(label: saathiName),
          SettingCard(children: [
            SettingToggleTile(
              icon: Icons.auto_awesome_rounded,
              title: saathiName,
              subtitle: on
                  ? 'On: the blob is on Home and Library'
                  : 'Off: no blob and no chats',
              value: on,
              onChanged: _switch,
            ),
            if (on) ...[
              const SettingDivider(),
              SettingNavTile(
                icon: Icons.chat_bubble_rounded,
                title: 'Talk to $saathiName',
                subtitle: 'Open the chat',
                onTap: () => openSaathiChat(context),
              ),
              const SettingDivider(),
              SettingToggleTile(
                icon: Icons.bedtime_rounded,
                title: 'Nap for today',
                subtitle: 'Hide the blob until tomorrow',
                value: saathi.nappingToday,
                onChanged: (v) async {
                  v ? await saathi.nap() : await saathi.wake();
                  if (mounted) setState(() {});
                },
              ),
            ],
          ]),
          const SizedBox(height: 24),
          const SettingSectionHeader(label: 'What $saathiName can do'),
          const SettingCard(children: [
            _Can('🎧', 'Make a mix for any mood',
                '"I\'m sad", "hype me up", "old is gold"'),
            _Can('▶️', 'Play one song at once',
                '"play Kesariya": from your playlist if it\'s there'),
            _Can('🎬', 'Show a music video', '"show me the video of Aadat"'),
            _Can('🧭', 'Show you around JARX',
                '"how do I download songs?", step by step'),
            _Can('😄', 'Roast your taste', 'in Hinglish too'),
          ]),
          const SizedBox(height: 24),
          const SettingSectionHeader(label: 'Your data'),
          SettingCard(children: [
            SettingNavTile(
              icon: Icons.psychology_rounded,
              title: 'What $saathiName remembers',
              subtitle: 'See, edit or delete its notes about your taste',
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const JarvixMemoryPage())),
            ),
            const SettingDivider(),
            SettingNavTile(
              icon: Icons.lock_rounded,
              title: 'Privacy',
              subtitle: 'What is sent, and what stays on this phone',
              onTap: () => showModalBottomSheet(
                  context: context,
                  backgroundColor: const Color(0xFF1A111B),
                  isScrollControlled: true,
                  builder: (_) => const JarvixPrivacySheet()),
            ),
            const SettingDivider(),
            SettingDestructiveTile(
              icon: Icons.delete_sweep_rounded,
              title: 'Clear chat',
              subtitle: 'Delete your messages with $saathiName',
              onTap: _clearChat,
            ),
          ]),
          const SizedBox(height: 16),
          Text(
              'Up to 100 chats a day, back at midnight (India time). Each '
              'account on this phone has its own $saathiName chat. Your name '
              'never leaves the phone.',
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.45),
                  fontSize: 12.5,
                  height: 1.45)),
        ],
      ),
    );
  }
}

/// One thing Jarvix can do, with an example.
class _Can extends StatelessWidget {
  const _Can(this.emoji, this.title, this.example);
  final String emoji, title, example;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(emoji, style: const TextStyle(fontSize: 20)),
          const SizedBox(width: 12),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style: const TextStyle(
                      color: Default_Theme.primaryColor1,
                      fontSize: 15,
                      fontWeight: FontWeight.w600)),
              Text(example,
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.55),
                      fontSize: 12.5)),
            ]),
          ),
        ]),
      );
}
