import 'package:Bloomee/screens/widgets/edge_glow.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the edge glow fades in and out, then removes itself',
      (tester) async {
    var done = false;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: EdgeGlow(onDone: () => done = true))));
    expect(EdgeGlowPainter(0, 44).opacity, 0);
    expect(EdgeGlowPainter(0.5, 44).opacity, 1);
    expect(EdgeGlowPainter(1, 44).opacity, 0);
    await tester.pump(const Duration(milliseconds: 1300));
    expect(done, isFalse);
    await tester.pump(const Duration(milliseconds: 1400));
    expect(done, isTrue, reason: 'gone after ~2.6 s');
  });
}
