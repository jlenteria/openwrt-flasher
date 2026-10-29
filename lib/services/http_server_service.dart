import 'dart:async';
import 'dart:io';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_static/shelf_static.dart';

class HttpServerService {
  HttpServer? _server;

  bool get isRunning => _server != null;
  int? get port => _server?.port;

  /// Serves [directory] on every IPv4 interface. Returns the bound port, or
  /// null when the server could not start.
  Future<int?> start(String directory, {int port = 8080}) async {
    try {
      if (_server != null) {
        await stop();
      }
      final handler = createStaticHandler(
        directory,
        defaultDocument: null,
        listDirectories: true,
      );
      _server = await shelf_io.serve(handler, InternetAddress.anyIPv4, port);
      return _server!.port;
    } catch (e) {
      return null;
    }
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  void dispose() {
    stop();
  }

  /// IPv4 addresses of this computer, for telling the user which address the
  /// board can reach.
  static Future<List<String>> localAddresses() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      return [
        for (final interface in interfaces)
          for (final address in interface.addresses)
            if (!address.address.startsWith('169.254.'))
              '${address.address} (${interface.name})',
      ];
    } catch (_) {
      return const [];
    }
  }
}
