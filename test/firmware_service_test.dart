import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openwrt_flasher/models/firmware_info.dart';
import 'package:openwrt_flasher/models/router_info.dart';
import 'package:openwrt_flasher/services/firmware_service.dart';

/// Builds a ustar header the way tar does: fixed-width fields, magic at 257.
Uint8List _tarHeader({required String name, required int contentSize}) {
  final header = Uint8List(512);
  void put(int offset, String value, int width) {
    final bytes = latin1.encode(value);
    final take = math.min(width, bytes.length);
    header.setRange(offset, offset + take, bytes, 0);
  }

  put(0, name, 100);
  put(100, '0000644', 8);
  put(108, '0000000', 8);
  put(116, '0000000', 8);
  put(124, contentSize.toRadixString(8).padLeft(11, '0'), 12);
  put(136, '0000000000', 12);
  put(148, '        ', 8);
  put(156, '0', 1);
  put(257, 'ustar', 6);
  put(263, '00', 2);
  return header;
}

/// A head-shaped sysupgrade image plus enough filler to clear the minimum
/// size, so the classification logic is what is under test.
Uint8List _sysupgradeImage({required String entryName, int filler = 0xA5}) {
  const contentSize = 1024 * 1024;
  final header = _tarHeader(name: entryName, contentSize: contentSize);
  final body = Uint8List(contentSize);
  for (var i = 0; i < body.length; i++) {
    body[i] = (i * 37 + filler) % 256;
  }
  return Uint8List.fromList([...header, ...body]);
}

/// No tar magic, no OpenWrt string: an image that cannot be checked at all.
Uint8List _opaqueImage() {
  const size = 1024 * 1024 + 4096;
  final bytes = Uint8List(size);
  for (var i = 0; i < size; i++) {
    bytes[i] = (i * 37 + 11) % 256;
  }
  return bytes;
}

const boardName = 'glinet,gl-mt3000';

RouterInfo _router({String board = boardName, String model = 'GL.iNet GL-MT3000'}) =>
    RouterInfo(
      ip: '192.168.1.1',
      boardName: board,
      model: model,
      firmwareVersion: '23.05.3',
      compatIds: const ['mediatek,mt7622'],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late FirmwareService service;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('openwrt_flasher_test');
    service = FirmwareService();
  });

  tearDown(() => dir.deleteSync(recursive: true));

  Future<File> write(String name, List<int> bytes) async {
    final file = File('${dir.path}/$name');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  test('a tar image naming this board is matched, and hashed correctly',
      () async {
    final image = _sysupgradeImage(
      entryName: 'openwrt-mediatek-generic-$boardName-v1.3.0-squashfs-sysupgrade.bin',
    );
    final file = await write('image.bin', image);

    final info = await service.validateFirmware(file.path, router: _router());

    expect(info.status, FirmwareStatus.matched);
    expect(info.detail, contains(boardName));
    expect(info.version, '1.3.0');
    expect(
      info.sha256,
      sha256.convert(image).toString(),
      reason: 'the chunked hasher must agree with a one-shot hash',
    );
  });

  test('the identifier search crosses chunk boundaries', () async {
    // Board name placed well past the 1 MB chunk edge so a naive per-chunk
    // scan would miss it.
    final image = _sysupgradeImage(
      entryName: 'openwrt-mediatek-v1.3.0-squashfs-sysupgrade.bin',
    );
    const marker = 'zz$boardName-zz';
    final patched = Uint8List.fromList(image);
    patched.setRange(1024 * 1024 - 8, 1024 * 1024 - 8 + marker.length,
        latin1.encode(marker));
    final file = await write('edge.bin', patched);

    final info = await service.validateFirmware(file.path, router: _router());
    expect(info.status, FirmwareStatus.matched);
  });

  test('a tar image for other hardware is blocked', () async {
    final file = await write(
      'other.bin',
      _sysupgradeImage(
        entryName:
            'openwrt-ath79-generic-tplink_archer-c7-v2-v1.3.0-squashfs-sysupgrade.bin',
      ),
    );

    final info = await service.validateFirmware(file.path, router: _router());

    expect(info.status, FirmwareStatus.mismatched);
    expect(info.isValid, isTrue);
    expect(info.isConfirmedForDevice, isFalse);
    expect(info.detail, contains('other hardware'));
  });

  test('an image with no device metadata cannot be verified', () async {
    final file = await write('opaque.bin', _opaqueImage());

    final info = await service.validateFirmware(file.path, router: _router());

    expect(info.status, FirmwareStatus.unverifiable);
    expect(info.needsAcknowledgement, isTrue);
    expect(info.isConfirmedForDevice, isFalse);
  });

  test('a fragment that is far too small is rejected', () async {
    final file = await write('tiny.bin', List.filled(4096, 0x41));

    final info = await service.validateFirmware(file.path, router: _router());

    expect(info.status, FirmwareStatus.invalid);
    expect(info.detail, contains('smaller'));
  });

  test('an unexpected extension is rejected', () async {
    final file = await write('firmware.txt', _opaqueImage());

    final info = await service.validateFirmware(file.path, router: _router());

    expect(info.status, FirmwareStatus.invalid);
    expect(info.detail, contains('.bin'));
  });

  test('nothing is judged without a confirmed device identity', () async {
    final file = await write(
      'image.bin',
      _sysupgradeImage(entryName: 'openwrt-$boardName-v1.3.0.bin'),
    );

    final info = await service.validateFirmware(file.path);

    expect(info.status, FirmwareStatus.invalid);
    expect(info.detail, contains('Identify the router'));
  });

  test('a .img file is accepted, not rejected on its extension', () async {
    final file = await write(
      'image.img',
      _sysupgradeImage(entryName: 'openwrt-mediatek-$boardName-v1.3.0-sysupgrade.img'),
    );

    final info = await service.validateFirmware(file.path, router: _router());

    expect(info.status, FirmwareStatus.matched);
  });

  test('NAND .tar and FIT .itb sysupgrade images are accepted', () async {
    for (final name in ['image.tar', 'image.itb']) {
      final file = await write(
        name,
        _sysupgradeImage(entryName: 'openwrt-$boardName-squashfs-sysupgrade'),
      );

      final info = await service.validateFirmware(file.path, router: _router());

      expect(info.status, FirmwareStatus.matched, reason: name);
    }
  });

  test('an initramfs image is refused for sysupgrade', () async {
    final file = await write(
      'openwrt-$boardName-initramfs-kernel.bin',
      _sysupgradeImage(entryName: 'openwrt-$boardName-initramfs'),
    );

    final info = await service.validateFirmware(file.path, router: _router());

    expect(info.status, FirmwareStatus.invalid);
    expect(info.detail, contains('initramfs'));
  });
}
