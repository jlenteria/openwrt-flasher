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
  });

  testWidgets('recovery offers the default firmware downloads',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 30000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app());

    await tester.tap(find.text('Recovery'));
    await tester.pumpAndSettle();

    expect(find.text('Download Required Firmware'), findsOneWidget);
    expect(find.text('Default firmware (ZR-2660)'), findsOneWidget);
    expect(find.text('Example upgrade firmware (FlareWifi)'), findsOneWidget);
    expect(find.text('Upgrade Firmware (sysupgrade)'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Download'), findsNWidgets(2));
  });

  testWidgets('the U-Boot file prompt offers the default firmware name',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 30000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app());

    await tester.tap(find.text('Recovery'));
    await tester.pumpAndSettle();

    expect(find.text('default-firmware.bin'), findsOneWidget);
    expect(find.textContaining('run loaded data now? (Y/n)'), findsOneWidget);
    expect(
      find.widgetWithText(OutlinedButton, 'Send filename'),
      findsOneWidget,
      reason: 'the filename is sent from the console, not the guide',
    );
    expect(find.widgetWithText(OutlinedButton, 'Y. Run image'), findsOneWidget);
    expect(
      find.widgetWithText(OutlinedButton, 'Accept default'),
      findsNothing,
      reason: 'the guide must not duplicate the console buttons',
    );
    expect(find.textContaining('Hit any key to stop autoboot'), findsOneWidget);
    expect(find.text('Reset config'), findsOneWidget);
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

  testWidgets('erases the configuration unless the user opts in',
      (tester) async {
    await tester.pumpWidget(app());

    final keepTile = find.widgetWithText(
      SwitchListTile,
      'Keep the router configuration',
    );
    await tester.dragUntilVisible(
      keepTile,
      find.byType(ListView).first,
      const Offset(0, -240),
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<SwitchListTile>(keepTile).value,
      isFalse,
      reason: 'sysupgrade must run with -n by default',
    );

    final backupTile = find.widgetWithText(
      SwitchListTile,
      'Download a configuration backup first',
    );
    final backup = tester.widget<SwitchListTile>(backupTile);
    expect(backup.value, isTrue);
    expect(
      backup.onChanged,
      isNotNull,
      reason: 'the backup is most useful when settings are erased',
    );
  });

  testWidgets('advertises no drag-and-drop that is not implemented',
      (tester) async {
    await tester.pumpWidget(app());
    expect(find.textContaining('drag-and-drop'), findsNothing);
  });

  testWidgets('the Flash tab reaches the router only at the LAN gateway',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app());

    expect(find.text('Search again'), findsOneWidget);
    expect(find.textContaining('default gateway'), findsWidgets);
    expect(find.text('Find more devices'), findsNothing);
    expect(find.text('Router IP address'), findsNothing);
  });

  testWidgets('restoring a backup needs an identified router and a file',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 8000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app());

    final restoreButton = find.widgetWithText(FilledButton, 'Restore backup');
    expect(
      find.textContaining('Restore a configuration backup'),
      findsOneWidget,
    );
    expect(
      tester.widget<FilledButton>(restoreButton).onPressed,
      isNull,
      reason: 'nothing may be uploaded before the router is identified',
    );
    expect(find.textContaining('Identify the router first'), findsOneWidget);
    expect(find.text('No backup selected'), findsOneWidget);
  });
}
