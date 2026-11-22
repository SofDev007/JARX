import 'package:Bloomee/screens/screen/explore_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// The Home photo: long-press opens the account switcher (build 43).
void main() {
  testWidgets('long-press the photo: accounts sheet', (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: Center(child: ProfileButton()))));
    await tester.pump();

    await tester.longPress(find.byType(ProfileButton));
    await tester.pumpAndSettle();
    expect(find.text('Accounts on this phone'), findsOneWidget);
    expect(find.text('Add another account'), findsOneWidget);
  });
}
