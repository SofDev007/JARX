// Settings › Report a problem: what the user writes goes to the owner's
// admin page, with the JARX version (request header) and phone model.

import 'package:Bloomee/core/theme/app_theme.dart';
import 'package:Bloomee/services/account/account.dart';
import 'package:flutter/material.dart';

class ReportProblemView extends StatefulWidget {
  const ReportProblemView({super.key});

  @override
  State<ReportProblemView> createState() => _ReportProblemViewState();
}

class _ReportProblemViewState extends State<ReportProblemView> {
  final _text = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _text.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    final res = await Account.instance.api('POST', '/report',
        body: {'text': text, 'device': await Account.deviceName()});
    if (!mounted) return;
    setState(() => _sending = false);
    final msg = switch (res?.statusCode) {
      200 => 'Sent. Thanks, the developer will look into it.',
      429 => "You've sent 5 today. Try again tomorrow.",
      _ => "Couldn't send it. Check your internet and try again.",
    };
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    if (res?.statusCode == 200) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Default_Theme.themeColor,
      appBar: AppBar(
        backgroundColor: Default_Theme.themeColor,
        surfaceTintColor: Colors.transparent,
        iconTheme: const IconThemeData(color: Default_Theme.primaryColor1),
        title: const Text('Report a problem',
            style: TextStyle(
                color: Default_Theme.primaryColor1,
                fontWeight: FontWeight.w700)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          Text(
              'Tell us what went wrong and what you were doing when it '
              'happened. Your JARX version and phone model are sent with it.',
              style: TextStyle(
                  color: Default_Theme.primaryColor1.withValues(alpha: 0.7),
                  height: 1.4)),
          const SizedBox(height: 16),
          TextField(
            controller: _text,
            autofocus: true,
            minLines: 5,
            maxLines: 10,
            maxLength: 2000,
            onChanged: (_) => setState(() {}),
            style: const TextStyle(color: Default_Theme.primaryColor1),
            decoration: InputDecoration(
              hintText: 'Example: songs skip after a few seconds on mobile data',
              hintStyle: TextStyle(
                  color: Default_Theme.primaryColor1.withValues(alpha: 0.35)),
              counterStyle: TextStyle(
                  color: Default_Theme.primaryColor1.withValues(alpha: 0.4)),
              filled: true,
              fillColor: Default_Theme.primaryColor1.withValues(alpha: 0.04),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed:
                _text.text.trim().isEmpty || _sending ? null : _send,
            style: FilledButton.styleFrom(
                backgroundColor: Default_Theme.accentColor2,
                minimumSize: const Size.fromHeight(48)),
            icon: _sending
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.send_rounded),
            label: Text(_sending ? 'Sending…' : 'Send'),
          ),
        ],
      ),
    );
  }
}
