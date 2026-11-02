import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openwrt_flasher/screens/home_screen.dart';
import 'package:openwrt_flasher/services/serial_service.dart';

/// Stands in for an adapter: the console path is exercised without a serial
/// library to load or a board to talk to.
class _FakeSerialService extends SerialService {
  @override
  List<String> getAvailablePorts() => const ['/dev/cu.fake0'];

  @override
  Future<bool> connect(String portName, {int baudRate = 115200}) async => true;

  @override
  void disconnect() {}

  @override
  void dispose() {}
}

void main() {
  const flushInterval = Duration(milliseconds: 120);
  const tailBytes = 64 * 1024;

  late _FakeSerialService serial;
  setUp(() => serial = _FakeSerialService());

  Future<void> openRecovery(
    WidgetTester tester, {
    required Size surface,
  }) async {
    tester.view.physicalSize = surface;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: HomeScreen(
        autoDiscover: false,
        hostOs: HostOs.macos,
        serialService: serial,
      ),
    ));
    await tester.tap(find.text('Recovery'));
    await tester.pumpAndSettle();
  }

  // The console is the only scrolled view with an explicit controller, so it is
  // the one that can be told apart from the guide list.
  final consoleView = find.byWidgetPredicate(
    (widget) => widget is SingleChildScrollView && widget.controller != null,
  );

  String consoleText(WidgetTester tester) =>
      tester
          .widget<SelectableText>(
            find.descendant(
              of: consoleView,
              matching: find.byType(SelectableText),
            ),
          )
          .data!;

  ScrollPosition consolePosition(WidgetTester tester) =>
      tester.widget<SingleChildScrollView>(consoleView).controller!.position;

  Future<void> send(WidgetTester tester, String chunk) async {
    serial.emitData(chunk);
    // The broadcast stream delivers on a microtask; the flush timer stays armed
    // until the window elapses.
    await tester.pump();
  }

  testWidgets('serial output only reaches the console, not the guide',
      (tester) async {
    await openRecovery(tester, surface: const Size(1600, 20000));

    final wiringBefore = tester.widget<Text>(find.text('Wiring'));
    await send(tester, 'OpenWrt (snpu) 23.05\n');
    await tester.pump(flushInterval);

    expect(consoleText(tester), contains('OpenWrt (snpu) 23.05'));
    expect(
      identical(wiringBefore, tester.widget<Text>(find.text('Wiring'))),
      isTrue,
      reason: 'a serial burst must not rebuild the cached guide cards',
    );
  });

  testWidgets('a burst is coalesced into one bounded update', (tester) async {
    await openRecovery(tester, surface: const Size(1600, 1200));
    expect(consoleText(tester), startsWith('No output yet'));

    // Nothing is shown until the flush window closes, however much arrived.
    for (var i = 0; i < 40; i++) {
      await send(tester, 'boot line $i\n' * 80);
    }
    expect(consoleText(tester), startsWith('No output yet'));

    await tester.pump(flushInterval);

    final text = consoleText(tester);
    expect(text.length, lessThanOrEqualTo(tailBytes));
    expect(text, endsWith('boot line 39\n'));
    expect(
      find.textContaining('older output was dropped'),
      findsOneWidget,
      reason: 'the user has to know the beginning of the log is gone',
    );
  });

  testWidgets('the console follows the newest line while pinned',
      (tester) async {
    await openRecovery(tester, surface: const Size(1600, 1200));

    for (var i = 0; i < 60; i++) {
      await send(tester, 'spam $i\n' * 400);
      await tester.pump(flushInterval);
    }
    await tester.pumpAndSettle();

    final position = consolePosition(tester);
    expect(position.maxScrollExtent, greaterThan(position.viewportDimension));
    expect(
      position.pixels,
      position.maxScrollExtent,
      reason: 'a burst must not break the follow: it is measured before layout',
    );
  });

  testWidgets('scrolling up unsticks the console', (tester) async {
    await openRecovery(tester, surface: const Size(1600, 1200));
    for (var i = 0; i < 20; i++) {
      await send(tester, 'old $i\n' * 400);
      await tester.pump(flushInterval);
    }
    await tester.pumpAndSettle();
    expect(consolePosition(tester).pixels,
        consolePosition(tester).maxScrollExtent);

    // Reading history, so the next flush has to leave the viewport alone.
    consolePosition(tester).jumpTo(0.0);
    await tester.pump();

    await send(tester, 'new\n' * 400);
    await tester.pump(flushInterval);
    await tester.pump();

    final position = consolePosition(tester);
    expect(position.pixels, 0.0);
    expect(position.maxScrollExtent, greaterThan(position.pixels));
  });

  testWidgets('Clear empties the console and the drop notice', (tester) async {
    await openRecovery(tester, surface: const Size(1600, 1200));
    for (var i = 0; i < 40; i++) {
      await send(tester, 'flood $i\n' * 80);
    }
    await tester.pump(flushInterval);
    expect(consoleText(tester), contains('flood 39'));

    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();

    expect(consoleText(tester), startsWith('No output yet'));
    expect(find.textContaining('older output was dropped'), findsNothing);
  });
}
