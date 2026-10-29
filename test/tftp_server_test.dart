import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:openwrt_flasher/services/tftp_server_service.dart';

/// Minimal TFTP client: sends a read request and collects DATA blocks.
Future<({Uint8List? data, String? error, Map<String, String> oack})> _download(
  int serverPort,
  String name, {
  Map<String, String> options = const {},
}) async {
  final socket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  final request = BytesBuilder()
    ..add([0, 1])
    ..add(name.codeUnits)
    ..addByte(0)
    ..add('octet'.codeUnits)
    ..addByte(0);
  options.forEach((key, value) {
    request
      ..add(key.codeUnits)
      ..addByte(0)
      ..add(value.codeUnits)
      ..addByte(0);
  });
  socket.send(request.toBytes(), InternetAddress.loopbackIPv4, serverPort);

  final received = BytesBuilder();
  final oack = <String, String>{};
  final done = Completer<String?>();
  var blockSize = 512;
  var expected = 1;
  socket.listen((event) {
    if (event != RawSocketEvent.read) return;
    final datagram = socket.receive();
    if (datagram == null) return;
    final d = datagram.data;
    final opcode = (d[0] << 8) | d[1];
    if (opcode == 5) {
      done.complete(String.fromCharCodes(d.sublist(4).takeWhile((b) => b != 0)));
      return;
    }
    if (opcode == 6) {
      final fields = TftpServerService.parseRequestFields(d.sublist(2));
      for (var i = 0; i + 1 < fields.length; i += 2) {
        oack[fields[i]] = fields[i + 1];
      }
      blockSize = int.tryParse(oack['blksize'] ?? '') ?? blockSize;
      socket.send([0, 4, 0, 0], datagram.address, datagram.port);
      return;
    }
    if (opcode != 3) return;
    final block = (d[2] << 8) | d[3];
    if (block == (expected & 0xFFFF)) {
      received.add(d.sublist(4));
      expected++;
    }
    socket.send([0, 4, d[2], d[3]], datagram.address, datagram.port);
    if (d.length - 4 < blockSize && !done.isCompleted) done.complete(null);
  });

  final error = await done.future.timeout(const Duration(seconds: 30));
  socket.close();
  return (
    data: error == null ? received.toBytes() : null,
    error: error,
    oack: oack,
  );
}

void main() {
  late Directory dir;
  late TftpServerService server;
  late int port;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('openwrt_flasher_tftp');
    server = TftpServerService();
    // An unprivileged port: the protocol is identical on 69.
    await server.start(dir.path, port: 0);
    port = server.port!;
  });

  tearDown(() async {
    await server.stop();
    dir.deleteSync(recursive: true);
  });

  Uint8List pattern(int size) =>
      Uint8List.fromList([for (var i = 0; i < size; i++) (i * 31 + 7) & 0xFF]);

  test('serves a file with the default 512-byte blocks', () async {
    final content = pattern(512 * 3 + 100);
    File('${dir.path}/initramfs.bin').writeAsBytesSync(content);

    final result = await _download(port, 'initramfs.bin');

    expect(result.error, isNull);
    expect(result.data, content);
  });

  test('ends with an empty block when the size is a block multiple', () async {
    final content = pattern(512 * 2);
    File('${dir.path}/exact.bin').writeAsBytesSync(content);

    final result = await _download(port, 'exact.bin');

    expect(result.data, content);
  });

  test('negotiates blksize and tsize', () async {
    final content = pattern(5000);
    File('${dir.path}/image.itb').writeAsBytesSync(content);

    final result = await _download(
      port,
      'image.itb',
      options: {'blksize': '1468', 'tsize': '0'},
    );

    expect(result.oack['blksize'], '1468');
    expect(result.oack['tsize'], '5000');
    expect(result.data, content);
  });

  test('block numbers roll over on images larger than 65535 blocks', () async {
    final content = pattern(8 * 65536 + 3);
    File('${dir.path}/big.bin').writeAsBytesSync(content);

    final result = await _download(port, 'big.bin', options: {'blksize': '8'});

    expect(result.data, content);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('matches the name case-insensitively and ignores directories', () async {
    final content = pattern(700);
    File('${dir.path}/Recovery.BIN').writeAsBytesSync(content);

    final result = await _download(port, '/tftpboot/recovery.bin');

    expect(result.data, content);
  });

  test('never serves anything outside the folder', () async {
    final outside = File('${dir.parent.path}/outside-${dir.hashCode}.bin')
      ..writeAsBytesSync(pattern(10));
    addTearDown(() => outside.deleteSync());

    final result = await _download(port, '../${outside.uri.pathSegments.last}');

    // Only the base name is honoured, and it does not exist inside the folder.
    expect(result.error, 'File not found');
  });

  test('logs requests for missing files so the name can be read', () async {
    final lines = <String>[];
    final sub = server.log.listen(lines.add);
    addTearDown(sub.cancel);

    final result = await _download(port, 'C0A80101.img');

    expect(result.error, 'File not found');
    await Future<void>.delayed(Duration.zero);
    expect(lines.join('\n'), contains('"C0A80101.img"'));
  });

  test('refuses uploads', () async {
    final socket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(socket.close);
    final reply = Completer<int>();
    socket.listen((event) {
      final d = socket.receive();
      if (d != null && !reply.isCompleted) reply.complete((d.data[0] << 8) | d.data[1]);
    });
    socket.send(
      [0, 2, ...'x.bin'.codeUnits, 0, ...'octet'.codeUnits, 0],
      InternetAddress.loopbackIPv4,
      port,
    );

    expect(await reply.future.timeout(const Duration(seconds: 5)), 5);
  });
}
