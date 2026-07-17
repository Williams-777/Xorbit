import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xorbit/widgets/reusable/orbital_loading_screen.dart';

void main() {
  testWidgets('OrbitalLoadingScreen shows loading text', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: OrbitalLoadingScreen(),
        ),
      ),
    );

    expect(find.text('Starting Xorbit...'), findsOneWidget);
  });
}
