import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:openwrt_flasher/services/http_server_service.dart';

void main() {
  test('reports a missing firmware folder instead of starting silently',
      () async {
    final missing = Directory.systemTemp.createTempSync('openwrt-flasher-');
    final path = missing.path;
    missing.deleteSync();

    final service = HttpServerService();
    final port = await service.start(path);
    expect(port, isNull);
    expect(service.lastError, contains('does not exist'));
    expect(service.lastError, contains(path));
  });

  test('reports why the port could not be bound', () async {
    final folder = Directory.systemTemp.createTempSync('openwrt-flasher-');
    addTearDown(() => folder.deleteSync(recursive: true));

    // Port 0 asks the OS for a free port, so the test does not collide with
    // the app (which holds 8080 while it is running) or any other process.
    final first = HttpServerService();
    final port = await first.start(folder.path, port: 0);
    expect(port, isNotNull);
    addTearDown(first.dispose);

    final second = HttpServerService();
    addTearDown(second.dispose);
    expect(await second.start(folder.path, port: port!), isNull);
    expect(second.lastError, isNotNull);
  });
}
