import 'package:Bloomee/services/ai/how_to.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const cases = {
    'How do I download a song?': 'download',
    'gaana download kaise karu': 'download',
    'can i listen offline': 'download',
    'how to download only on wifi': 'wifi',
    'mobile data bachana hai, kya karu': 'wifi',
    'How do I bring my Spotify playlist?': 'spotify',
    'spotify ki playlist kaise laaun': 'spotify',
    'how do i watch the music video': 'video',
    'video kaise dekhu?': 'video',
    'how do I stop a song from being suggested': 'never',
    'ye gaana suggest mat karo, kaise': 'never',
    'how to switch account': 'account',
    'dusra gmail kaise lagau': 'account',
    'how do I update JARX?': 'update',
    'update kaise karu': 'update',
    'how do i report a problem': 'report',
    'is there a game?': 'game',
    'how do I play the game': 'game',
    'game kaise khelte hain': 'game',
    'where is the floppy game?': 'game',
    'how do i beat my high score': 'game',
    'how can I control music on my other phone': 'remote',
    'dusre phone ka gaana kaise control karu': 'remote',
    'can i pause my sister phone from here?': 'remote',
    'app kaam nahi kar raha, kya karu': 'report',
  };
  cases.forEach((ask, id) {
    test(ask, () => expect(howToFor(ask)?.id, id));
  });

  test('commands and chat are not how-tos', () {
    for (final t in [
      'play the video of Kesariya',
      'Kesariya ka video dikhao',
      'download kesariya',
      "I'm sad",
      'how are you',
      'play something romantic',
    ]) {
      expect(howToFor(t), isNull, reason: t);
    }
  });

  test('every clip is listed in pubspec assets folder', () {
    for (final h in howTos.values) {
      if (h.clip != null) expect(h.clip, startsWith('assets/faq/'));
    }
  });
}
