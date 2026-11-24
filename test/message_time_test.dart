import 'package:Bloomee/screens/screen/saathi_chat.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Jarvix message times', () {
    final now = DateTime(2026, 11, 24, 18, 0);
    expect(messageTime(DateTime(2026, 11, 24, 9, 5), now), '9:05 am');
    expect(messageTime(DateTime(2026, 11, 23, 22, 42), now),
        'Yesterday, 10:42 pm');
    expect(messageTime(DateTime(2026, 11, 21, 13, 0), now), '21 Nov, 1:00 pm');
    expect(messageTime(DateTime(2025, 12, 31, 13, 0), now),
        '31 Dec 2025, 1:00 pm');
    expect(messageTime(DateTime.fromMillisecondsSinceEpoch(0), now), '');
  });
}
