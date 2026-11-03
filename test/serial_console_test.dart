import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openwrt_flasher/screens/home_screen.dart';
import 'package:openwrt_flasher/services/serial_service.dart';

/// Stands in for an adapter: the console path is exercised without a serial
/// library to load or a board to talk to.
class _FakeSerialService extends SerialService {
  /// Everything the UI sent, so a quick-action button can be checked by the
  /// bytes it puts on the wire rather than by its label.
  final List<String> writes = [];

  @override
  List<String> getAvailablePorts() => const ['/dev/cu.fake0'];

  @override
  Future<bool> connect(String portName, {int baudRate = 115200}) async => true;

  @override
  void write(String data) => writes.add(data);

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

  SelectableText consoleWidget(WidgetTester tester) =>
      tester.widget<SelectableText>(
        find.descendant(
          of: consoleView,
          matching: find.byType(SelectableText),
        ),
      );

  String consoleText(WidgetTester tester) {
    final widget = consoleWidget(tester);
    return widget.data ?? widget.textSpan!.toPlainText();
  }

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

  testWidgets('a bootloader menu is drawn, not printed as escape codes',
      (tester) async {
    await openRecovery(tester, surface: const Size(1600, 1200));

    await send(
      tester,
      'Hit any key to stop autoboot:  0 \r\n'
      '\x1b[?25l\x1b[2J\x1b[1;1H\x1b[2K\x1b[2;1H  *** U-Boot Boot Menu ***'
      '\x1b[0K\x1b[4;1H     \x1b[7m1. Startup system (Default)\x1b[0m'
      '\x1b[5;1H     2. Upgrade firmware'
      '\x1b[10;1H  Hit any key to stop autoboot:  3 '
      '\x1b[10;1H\x1b[2K  Hit any key to stop autoboot:  2 ',
    );
    await tester.pump(flushInterval);

    final text = consoleText(tester);
    expect(text, isNot(contains('\x1b')));
    expect(text, isNot(contains('[2J')));
    expect(text, contains('\n     1. Startup system (Default)\n'));
    expect(text, contains('autoboot:  2'));
    expect(text, isNot(contains('autoboot:  3')));

    final span = consoleWidget(tester).textSpan!;
    final selected = span.children!
        .cast<TextSpan>()
        .firstWhere((child) => child.style?.backgroundColor != null);
    expect(selected.text, '1. Startup system (Default)');
  });

  testWidgets('Reset all disconnects and clears the recovery session',
      (tester) async {
    await openRecovery(tester, surface: const Size(1600, 20000));
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    serial.writes.clear();
    await send(tester, 'U-Boot 2023.07\r\n');
    await tester.pump(flushInterval);
    expect(consoleText(tester), contains('U-Boot'));

    await tester.tap(find.byTooltip('Reset all'));
    await tester.pumpAndSettle();
    // Asks first: nothing is cleared until confirmed.
    expect(consoleText(tester), contains('U-Boot'));
    await tester.tap(find.widgetWithText(FilledButton, 'Reset all'));
    await tester.pumpAndSettle();

    expect(consoleText(tester), startsWith('No output yet'));
    expect(find.text('Connect'), findsOneWidget);
    expect(find.text('Disconnect'), findsNothing);
  });

  testWidgets('arrows and Enter send what a terminal sends', (tester) async {
    await openRecovery(tester, surface: const Size(1600, 20000));
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    serial.writes.clear();

    await tester.tap(find.byIcon(Icons.arrow_downward));
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.tap(find.widgetWithText(OutlinedButton, 'Enter'));
    await tester.pump();

    expect(
      serial.writes,
      ['\x1b[B', '\x1b[A', '\r'],
      reason: 'U-Boot\'s boot menu selects on a carriage return, not \\n',
    );
  });

  testWidgets('Reset config leaves the current prompt before sending reset',
      (tester) async {
    await openRecovery(tester, surface: const Size(1600, 20000));
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    serial.writes.clear();

    await tester.tap(find.widgetWithText(OutlinedButton, 'Reset config'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Reset config'));
    await tester.pump();
    expect(serial.writes, ['\x03'],
        reason: 'a one-key prompt must not swallow the "r" of reset');

    await tester.pump(const Duration(milliseconds: 300));
    expect(serial.writes, ['\x03', 'reset\n']);
  });

  testWidgets('the load address prompt is accepted automatically',
      (tester) async {
    await openRecovery(tester, surface: const Size(1600, 20000));
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    serial.writes.clear();

    // Split across chunks, as a serial read may deliver it.
    await send(tester, '*** Loading image ***\r\n\r\nInput load ');
    await send(tester, 'address: 0x83000000');
    expect(serial.writes, isEmpty);

    await tester.pump(const Duration(milliseconds: 200));
    expect(serial.writes, ['\r']);

    // Later output that is not the prompt is left alone.
    await send(tester, '\r\n\r\nAvailable load methods:\r\n');
    await tester.pump(const Duration(milliseconds: 200));
    expect(serial.writes, ['\r']);
  });

  testWidgets('Connect sends Enter to wake the console', (tester) async {
    await openRecovery(tester, surface: const Size(1600, 20000));
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(serial.writes, ['\r']);
  });

  testWidgets('the quick actions send the numbers the guide names',
      (tester) async {
    // Tall enough that the whole guide is laid out next to the console panel,
    // so the prose and the button it names can be compared.
    await openRecovery(tester, surface: const Size(1600, 20000));
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    serial.writes.clear();

    await tester.tap(find.widgetWithText(OutlinedButton, '0. TFTP Client'));
    await tester.tap(find.widgetWithText(OutlinedButton, '4. Load image'));
    await tester.pump();

    expect(
      serial.writes,
      ['0\n', '4\n'],
      reason: 'TFTP Client is the menu\'s 0 entry, not 1',
    );
    expect(
      find.textContaining('click the "0. TFTP Client" button'),
      findsOneWidget,
      reason: 'the guide names the button by its exact label, so renaming one '
          'without the other fails here',
    );
  });
}
