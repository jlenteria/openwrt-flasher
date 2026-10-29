import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openwrt_flasher/screens/home_screen.dart';

void main() {
  // autoDiscover is off: a real LAN probe would leave sockets and timers
  // pending at the end of the test.
  Widget app() => MaterialApp(
        title: 'OpenWrt Flasher',
        home: const HomeScreen(autoDiscover: false, autoDiscoverSerial: false),
        debugShowCheckedModeBanner: false,
      );

  testWidgets('loads without touching the network', (tester) async {
    await tester.pumpWidget(app());

    expect(find.text('OpenWrt Flasher'), findsOneWidget);
    expect(find.text('Not searched yet.'), findsOneWidget);
  });

  testWidgets('flashing is blocked until the router is identified',
      (tester) async {
    await tester.pumpWidget(app());

    // Both live at the end of a long ListView, so they are not laid out until
    // they are scrolled into the test viewport.
    final flashButton = find.byKey(HomeScreen.flashButtonKey);
    await tester.dragUntilVisible(
      flashButton,
      find.byType(ListView),
      const Offset(0, -240),
    );
    await tester.pumpAndSettle();

    final button = tester.widget<FilledButton>(flashButton);
    expect(button.onPressed, isNull);
    expect(
      find.text('Identify the router over SSH first.'),
      findsOneWidget,
      reason: 'the UI must say what is missing, not just disable the button',
    );
  });

  testWidgets('the recovery guide is for any OpenWrt board', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app());

    await tester.tap(find.text('Recovery'));
    await tester.pumpAndSettle();

    expect(find.textContaining('OpenWrt Board Recovery'), findsOneWidget);

    await tester.dragUntilVisible(
      find.text('Wiring'),
      find.byType(ListView).last,
      const Offset(0, -240),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    expect(find.image(const AssetImage('assets/images/uart_board.png')), findsOneWidget);
    // The images must actually decode, not fall back to placeholder icons.
    expect(find.byIcon(Icons.usb), findsNothing);
    expect(find.byIcon(Icons.memory), findsNothing);
    expect(find.textContaining(RegExp('zrouter|flarewifi', caseSensitive: false)),
        findsNothing);
  });

  group('the recovery guide matches the OS', () {
    // Text that may only ever appear in one OS's guide.
    const exclusive = {
      HostOs.windows: ['Device Manager', 'Tftpd64', 'netsh interface'],
      HostOs.macos: ['/dev/cu.', 'launchctl', 'ifconfig en5', 'networksetup'],
      HostOs.linux: ['/dev/ttyUSB', 'tftpd-hpa', 'ip addr', 'dialout'],
    };

    for (final os in HostOs.values) {
      testWidgets(os.label, (tester) async {
        tester.view.physicalSize = const Size(1000, 30000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(MaterialApp(
          home: HomeScreen(
            autoDiscover: false,
            autoDiscoverSerial: false,
            hostOs: os,
          ),
        ));
        await tester.tap(find.text('Recovery'));
        await tester.pumpAndSettle();

        final text = [
          ...tester.widgetList<Text>(find.byType(Text)).map((t) => t.data ?? ''),
          ...tester
              .widgetList<SelectableText>(find.byType(SelectableText))
              .map((t) => t.data ?? ''),
        ].join('\n');

        expect(text, contains('(${os.label})'));
        for (final entry in exclusive.entries) {
          for (final phrase in entry.value) {
            expect(
              text.contains(phrase),
              entry.key == os,
              reason: '"$phrase" belongs to the ${entry.key.label} guide only',
            );
          }
        }
        expect(text, isNot(contains(' Mac ')), skip: os == HostOs.macos);
      });
    }
  });

  testWidgets('advertises no drag-and-drop that is not implemented',
      (tester) async {
    await tester.pumpWidget(app());
    expect(find.textContaining('drag-and-drop'), findsNothing);
  });

  testWidgets('an address you type in offers the host key recovery path',
      (tester) async {
    await tester.pumpWidget(app());

    await tester.enterText(
      find.byType(TextField).first,
      '192.168.5.1',
    );
    await tester.pump();
    await tester.tap(find.text('Use'));
    await tester.pumpAndSettle();

    // The pin store has no other way to forget a stale or wrong key.
    expect(find.textContaining('Forget pinned host key'), findsOneWidget);
  });

  testWidgets('a gateway with a zero octet is not rejected', (tester) async {
    await tester.pumpWidget(app());

    // 10.0.0.1 is an ordinary router address; an earlier validator refused any
    // address containing a 0.
    await tester.enterText(find.byType(TextField).first, '10.0.0.1');
    await tester.pump();
    await tester.tap(find.text('Use'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(ListTile, '10.0.0.1'), findsOneWidget);
    expect(find.textContaining('Enter a full IPv4 address'), findsNothing);
  });
}
