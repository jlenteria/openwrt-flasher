import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openwrt_flasher/models/support_info.dart';
import 'package:openwrt_flasher/screens/home_screen.dart';

/// Markdown hard-wraps its prose and Dart hard-wraps the literals in
/// [SupportInfo], so the only difference between the two is newline vs space.
String _normalize(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();

void main() {
  Widget app() => MaterialApp(
        title: 'OpenWrt Flasher',
        home: const HomeScreen(autoDiscover: false, autoDiscoverSerial: false),
        debugShowCheckedModeBanner: false,
      );

  Future<void> openSupport(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app());

    await tester.tap(find.byIcon(Icons.info_outline));
    await tester.pumpAndSettle();
    expect(find.text('About OpenWrt Flasher'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Support'));
    await tester.pumpAndSettle();
  }

  testWidgets('About opens the support page instead of stacking dialogs',
      (tester) async {
    await openSupport(tester);

    expect(find.text(SupportInfo.title), findsOneWidget);
    expect(
      find.text('About OpenWrt Flasher'),
      findsNothing,
      reason: 'Support replaces About, the same way Licenses does',
    );

    for (final sentence in SupportInfo.sentences) {
      expect(find.text(sentence), findsOneWidget);
    }
    expect(find.text('Close'), findsOneWidget);
  });

  testWidgets('the QR really decodes', (tester) async {
    await openSupport(tester);

    expect(
      find.image(const AssetImage(SupportInfo.qrAsset)),
      findsOneWidget,
      reason: 'the app must show the same file docs/SUPPORT.md embeds',
    );
    // About has no Image and the support page has exactly one, so a second
    // qr_code_2 icon would mean errorBuilder fell back instead of decoding.
    expect(find.byType(Image), findsOneWidget);
    expect(find.byIcon(Icons.qr_code_2), findsOneWidget);
  });

  test('the app, docs/SUPPORT.md and the README word the ask identically', () {
    for (final path in ['docs/SUPPORT.md', 'README.md']) {
      final file = File(path);
      expect(
        file.existsSync(),
        isTrue,
        reason: 'flutter test runs from the package root',
      );
      final text = _normalize(file.readAsStringSync());
      for (final sentence in SupportInfo.sentences) {
        expect(
          text,
          contains(_normalize(sentence)),
          reason: '$path and the app must ask for the same thing',
        );
      }
      expect(
        text,
        contains('banks/bpi.jpg'),
        reason: '$path must still show the QR the app bundles',
      );
    }
  });
}
