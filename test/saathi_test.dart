import 'package:Bloomee/screens/widgets/saathi_blob.dart';
import 'package:Bloomee/services/ai/saathi.dart';
import 'package:Bloomee/services/recommendations/song_card.dart';
import 'package:Bloomee/src/rust/api/plugin/models.dart';
import 'package:flutter_test/flutter_test.dart';

Track _track(String title, String artist) => Track(
      id: 'x::$title',
      title: title,
      artists: [ArtistSummary(id: artist, name: artist)],
      thumbnail: const Artwork(url: '', layout: ImageLayout.square),
      isExplicit: false,
    );

void main() {
  test('the phone fills in the name the AI never sees', () {
    expect(fillName('Hey {name}! Bye {name}.', 'Arnav Jaiswal'),
        'Hey Arnav! Bye Arnav.');
    expect(fillName('Hey {name}!', ''), 'Hey friend!');
    expect(fillName('Hey {name}!', null), 'Hey friend!');
  });

  test('very low messages always bring the helpline', () {
    for (final s in [
      'I want to die',
      'thinking about suicide',
      'yaar marna chahta hoon',
      'jeene ka mann nahi karta',
    ]) {
      expect(soundsVeryLow(s), isTrue, reason: s);
    }
    for (final s in ['this song is killer', 'I am sad today', 'dance hard']) {
      expect(soundsVeryLow(s), isFalse, reason: s);
    }
  });

  test('chat, memory and mixes survive a save', () {
    final mix = SaathiMix.fromJson({
      'title': 'Beast mode',
      'moods': ['dance'],
      'fromPlaylists': ['Gym'],
      'songs': [
        {'title': 'Brown Munde', 'artist': 'AP Dhillon'}
      ],
    });
    final s = SaathiState()
      ..consent = true
      ..left = true
      ..memory = ['gym in the evening']
      ..chat = [
        SaathiMsg(true, 'hype me up'),
        SaathiMsg(false, 'Say less', mix: mix, helpline: true)..reported = true,
        SaathiMsg(false, 'Hey {name}!', local: true),
      ];
    final back = SaathiState.fromJson(s.toJson());
    expect(back.consent, isTrue);
    expect(back.left, isTrue);
    expect(back.memory, ['gym in the evening']);
    expect(back.chat.map((m) => m.mine), [true, false, false]);
    expect(back.chat[1].mix!.songs.single.artist, 'AP Dhillon');
    expect(back.chat[1].mix!.fromPlaylists, ['Gym']);
    expect(back.chat[1].helpline && back.chat[1].reported, isTrue);
    expect(back.chat[2].local, isTrue);
    // Later turns remind the AI what it played.
    expect(back.chat[1].forAi, contains('Brown Munde — AP Dhillon'));
  });

  test('the greeting fits the time and the song playing', () {
    final night = Saathi.greeting(
        _track('Kesariya', 'Arijit Singh'), DateTime(2026, 11, 22, 2, 14));
    expect(night, contains('2 a.m. and Arijit Singh again'));
    expect(night, contains('{name}'));
    expect(Saathi.greeting(null, DateTime(2026, 11, 22, 9)),
        contains('Good morning'));
  });

  test("India's date rolls over at Indian midnight", () {
    expect(indiaDay(DateTime.utc(2026, 11, 21, 18, 29)), '2026-11-21');
    expect(indiaDay(DateTime.utc(2026, 11, 21, 18, 31)), '2026-11-22');
  });

  test('AI mood tags replace the title-word guess', () {
    final reader = SongCardReader(
      songKey: (t) => t.title.toLowerCase(),
      aiMoods: (k) => k == 'happy song' ? {Mood.sad, Mood.calm} : null,
    );
    expect(reader.read(_track('Happy Song', 'X')).moods, {Mood.sad, Mood.calm});
    // No AI tag: the title words still count.
    expect(reader.read(_track('Happy Day', 'X')).moods, contains(Mood.happy));
  });

  test('blob colour picks the main mood', () {
    expect(MoodTags.mainMood({Mood.cozy, Mood.sad}), Mood.sad);
    expect(MoodTags.mainMood({}), isNull);
    expect(moodColors(Mood.sad), isNot(moodColors(null)));
  });

  test('"play X" is played at once; vague asks go to the AI', () {
    expect(playRequest('play Kesariya'), (title: 'Kesariya', artist: ''));
    expect(playRequest('Play Tum Hi Ho by Arijit Singh!'),
        (title: 'Tum Hi Ho', artist: 'Arijit Singh'));
    expect(playRequest('please play the song "Channa Mereya"'),
        (title: 'Channa Mereya', artist: ''));
    expect(playRequest('Kesariya bajao'), (title: 'Kesariya', artist: ''));
    expect(playRequest('tera hone laga hoon chala do'),
        (title: 'tera hone laga hoon', artist: ''));
    for (final vague in [
      'play something',
      'play some romantic songs',
      'play music',
      'play my playlist',
      'kuch bhi bajao',
      'hindi gaane chalao',
      'roast my taste',
      'I am sad',
    ]) {
      expect(playRequest(vague), isNull, reason: vague);
    }
  });

  test('video asks are told apart from plain "play"', () {
    expect(videoRequest('Play the video of pyari amaanat'),
        (title: 'pyari amaanat', artist: ''));
    expect(videoRequest('play the video of aadat by honey singh'),
        (title: 'aadat', artist: 'honey singh'));
    expect(videoRequest('show me the music video of Kesariya'),
        (title: 'Kesariya', artist: ''));
    expect(videoRequest('watch Kesariya video'), (title: 'Kesariya', artist: ''));
    expect(videoRequest('aadat ka video dikhao'), (title: 'aadat', artist: ''));
    expect(videoRequest('play Kesariya'), isNull, reason: 'just the song');
    expect(videoRequest('roast my taste'), isNull);
  });
}
