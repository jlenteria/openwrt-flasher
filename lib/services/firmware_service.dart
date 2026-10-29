import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show compute;

import '../models/firmware_info.dart';
import '../models/router_info.dart';

/// Reads a local firmware image without ever holding it whole in memory, and
/// without blocking the UI: hashing and scanning both run in an isolate.
class FirmwareService {
  static const minimumImageBytes = 1024 * 1024;
  /// OpenWrt sysupgrade images ship as .bin on most targets, .itb on FIT
  /// targets, .tar on NAND targets and .img/.img.gz on x86 and SBCs.
  static const acceptedExtensions = {'bin', 'img', 'itb', 'tar', 'gz'};

  Future<String> computeSha256(String filePath) =>
      compute(_sha256OfLocalFile, filePath);

  /// [router] must be an identity confirmed over SSH. Compatibility is decided
  /// by whether the image actually names this device, not by file size.
  Future<FirmwareInfo> validateFirmware(
    String filePath, {
    RouterInfo? router,
  }) async {
    final fileName = _baseName(filePath);
    final extension = fileName.contains('.')
        ? fileName.split('.').last.toLowerCase()
        : '';

    if (!acceptedExtensions.contains(extension)) {
      return _invalid(
        filePath,
        fileName,
        'Expected a sysupgrade image ending in '
        '${acceptedExtensions.map((e) => '.$e').join(', ')}, got "$fileName".',
      );
    }

    if (fileName.toLowerCase().contains('initramfs')) {
      return _invalid(
        filePath,
        fileName,
        'This is an initramfs image: it only boots from RAM and is not meant '
        'for sysupgrade. Use it from the Recovery tab, then flash the matching '
        '"sysupgrade" image here.',
      );
    }

    final file = File(filePath);
    if (!await file.exists()) {
      return _invalid(filePath, fileName, 'The file cannot be read: $filePath');
    }
    final fileSize = await file.length();
    if (fileSize == 0) {
      return _invalid(filePath, fileName, 'The file is empty.');
    }
    if (fileSize < minimumImageBytes) {
      return _invalid(
        filePath,
        fileName,
        'At ${(fileSize / 1024 / 1024).toStringAsFixed(2)} MB this is smaller '
        'than any sysupgrade image we support '
        '(${minimumImageBytes ~/ 1024 ~/ 1024} MB minimum). A kernel or rootfs '
        'fragment alone will brick the router.',
      );
    }

    if (router == null) {
      return _invalid(
        filePath,
        fileName,
        'Identify the router over SSH first — an image can only be judged '
        'against a real board name.',
      );
    }

    final hash = await compute(_sha256OfLocalFile, filePath);
    final scan = await compute(
      _scanImageFile,
      _ScanRequest(filePath: filePath, deviceIds: router.identifiers),
    );

    final version = _versionOf(fileName, scan);
    final ids = router.identifiers;

    if (scan.matchedIds.isNotEmpty) {
      return FirmwareInfo(
        fileName: fileName,
        filePath: filePath,
        fileSize: fileSize,
        version: version,
        status: FirmwareStatus.matched,
        model: router.boardName,
        sha256: hash,
        supportedDevices: scan.declaredDevices,
        detail: 'The image names this device: '
            '${scan.matchedIds.map((id) => '"$id"').join(', ')}.',
      );
    }

    if (scan.isTar || scan.mentionsOpenWrt) {
      return FirmwareInfo(
        fileName: fileName,
        filePath: filePath,
        fileSize: fileSize,
        version: version,
        status: FirmwareStatus.mismatched,
        model: router.boardName,
        sha256: hash,
        supportedDevices: scan.declaredDevices,
        detail: 'This looks like an image for other hardware. It names '
            '${scan.declaredDevices.isEmpty ? 'no device at all' : scan.declaredDevices.take(4).join(', ')} '
            'and never mentions ${router.boardName} '
            '(looking for: ${ids.join(', ')}).',
      );
    }

    return FirmwareInfo(
      fileName: fileName,
      filePath: filePath,
      fileSize: fileSize,
      version: version,
      status: FirmwareStatus.unverifiable,
      model: router.boardName,
      sha256: hash,
      supportedDevices: scan.declaredDevices,
      detail: 'This image carries no device metadata, so nothing here can '
          'confirm it is for ${router.boardName}. You have to be sure of its '
          'provenance before flashing.',
    );
  }

  static FirmwareInfo _invalid(String filePath, String fileName, String detail) {
    return FirmwareInfo(
      fileName: fileName,
      filePath: filePath,
      fileSize: 0,
      version: 'unknown',
      status: FirmwareStatus.invalid,
      detail: detail,
    );
  }

  static String _baseName(String path) {
    final separator = path.lastIndexOf(Platform.pathSeparator);
    if (separator < 0) return path.split('/').last.split('\\').last;
    return path.substring(separator + 1);
  }

  static String _versionOf(String fileName, _ImageScan scan) {
    final fromName = RegExp(r'v?(\d+\.\d+\.\d+)').firstMatch(fileName)?.group(1);
    if (fromName != null) return fromName;
    final fromImage = RegExp(r'\d+\.\d+(?:\.\d+)?').firstMatch(scan.versionHint);
    return fromImage?.group(0) ?? 'unknown';
  }
}

/// SHA-256 of a local file, chunked. Top-level so it can run in an isolate.
String _sha256OfLocalFile(String path) {
  final output = _DigestCollector();
  final sink = sha256.startChunkedConversion(output);
  final raf = File(path).openSync();
  try {
    final buffer = Uint8List(1024 * 1024);
    while (true) {
      final read = raf.readIntoSync(buffer);
      if (read == 0) break;
      sink.add(Uint8List.sublistView(buffer, 0, read));
    }
    sink.close();
  } finally {
    raf.closeSync();
  }
  return output.digest.toString();
}

class _DigestCollector implements Sink<Digest> {
  late Digest digest;
  @override
  void add(Digest data) => digest = data;
  @override
  void close() {}
}

class _ScanRequest {
  const _ScanRequest({required this.filePath, required this.deviceIds});
  final String filePath;
  final List<String> deviceIds;
}

class _ImageScan {
  _ImageScan({
    required this.isTar,
    required this.mentionsOpenWrt,
    required this.matchedIds,
    required this.declaredDevices,
    required this.versionHint,
  });

  final bool isTar;
  final bool mentionsOpenWrt;
  final List<String> matchedIds;
  final List<String> declaredDevices;
  final String versionHint;
}

const _imageScanChunk = 1024 * 1024;
const _imageScanOverlap = 512;

/// Reads the tar metadata at the head of the image and then sweeps the whole
/// file for the router's identifiers. Runs in an isolate.
_ImageScan _scanImageFile(_ScanRequest request) {
  final raf = File(request.filePath).openSync();
  final matched = <String>{};
  final declared = <String>{};
  var mentionsOpenWrt = false;
  var isTar = false;
  final versionParts = <String>[];

  try {
    final size = raf.lengthSync();
    final headLength = math.min(64 * 1024, size).toInt();
    final head = Uint8List(headLength);
    raf.setPositionSync(0);
    raf.readIntoSync(head);

    final entries = _readTarEntries(head);
    if (entries.isNotEmpty) {
      isTar = true;
      declared.addAll(entries.where(_looksLikeDeviceName));
      for (final entry in entries) {
        if (entry.toLowerCase().contains('openwrt')) mentionsOpenWrt = true;
        final numbers = RegExp(r'\d+\.\d+(?:\.\d+)?').firstMatch(entry);
        if (numbers != null) versionParts.add(numbers.group(0)!);
      }
    }

    // The compat/control blocks inside the tar header region name the devices
    // an image supports; surface those strings for the mismatch message.
    for (final token in _printableRuns(head)) {
      if (token.length < 8 || token.length > 80) continue;
      if (!RegExp(r'[A-Za-z]').hasMatch(token)) continue;
      if (!RegExp(r'[0-9_-]').hasMatch(token)) continue;
      declared.add(token);
      final numbers = RegExp(r'\d+\.\d+(?:\.\d+)?').firstMatch(token);
      if (numbers != null) versionParts.add(numbers.group(0)!);
    }

    // Whole-file sweep for identifiers, with overlap so a string spanning a
    // chunk boundary is still found.
    final patterns = <String, List<int>>{};
    for (final id in request.deviceIds) {
      final bytes = utf8.encode(id.toLowerCase());
      if (bytes.isNotEmpty) patterns[id] = bytes;
    }
    final openWrtNeedle = utf8.encode('openwrt');

    raf.setPositionSync(0);
    final buffer = Uint8List(_imageScanChunk + _imageScanOverlap);
    var carry = 0;
    while (true) {
      final read = raf.readIntoSync(
        buffer,
        carry,
        math.min(buffer.length, carry + _imageScanChunk),
      );
      if (read == 0) break;
      final used = carry + read;
      final window = Uint8List.sublistView(buffer, 0, used);
      final lowered = _toAsciiLower(window);
      for (final entry in patterns.entries) {
        if (_contains(lowered, _toAsciiLower(entry.value))) {
          matched.add(entry.key);
        }
      }
      if (!mentionsOpenWrt && _contains(lowered, openWrtNeedle)) {
        mentionsOpenWrt = true;
      }
      carry = math.min(used, _imageScanOverlap).toInt();
      if (carry > 0) buffer.setRange(0, carry, window.sublist(used - carry));
      if (used <= _imageScanOverlap) break;
    }
  } finally {
    raf.closeSync();
  }

  return _ImageScan(
    isTar: isTar,
    mentionsOpenWrt: mentionsOpenWrt,
    matchedIds: matched.toList()..sort(),
    declaredDevices: declared.take(12).toList()..sort(),
    versionHint: versionParts.isEmpty ? '' : versionParts.first,
  );
}

Uint8List _toAsciiLower(List<int> input) {
  final output = Uint8List(input.length);
  for (var i = 0; i < input.length; i++) {
    final byte = input[i];
    output[i] = byte >= 65 && byte <= 90 ? byte + 32 : byte;
  }
  return output;
}

bool _contains(List<int> haystack, List<int> needle) {
  if (needle.isEmpty || needle.length > haystack.length) return false;
  outer:
  for (var start = 0; start <= haystack.length - needle.length; start++) {
    for (var i = 0; i < needle.length; i++) {
      if (haystack[start + i] != needle[i]) continue outer;
    }
    return true;
  }
  return false;
}

bool _looksLikeDeviceName(String entry) {
  final lower = entry.toLowerCase();
  return lower.contains('openwrt') ||
      lower.contains('sysupgrade') ||
      lower.contains('squashfs') ||
      lower.contains('support');
}

/// Parses ustar headers from the start of the image and returns the entry
/// names, following the same rules GNU tar uses for the prefix field.
List<String> _readTarEntries(Uint8List head) {
  final names = <String>[];
  var offset = 0;
  while (offset + 512 <= head.length) {
    final magic = _ascii(head, offset + 257, 6);
    if (!magic.startsWith('ustar')) break;
    final name = _asciiString(head, offset, 100);
    final prefix = _asciiString(head, offset + 345, 155);
    final sizeField = _asciiString(head, offset + 124, 12);
    final size = int.tryParse(sizeField.trim().split(' ').first, radix: 8) ?? -1;
    if (name.isEmpty && size <= 0) break;
    final full = prefix.isEmpty ? name : '$prefix/$name';
    if (full.isNotEmpty) names.add(full);
    if (size < 0) break;
    offset += 512 + ((size + 511) ~/ 512) * 512;
  }
  return names;
}

String _ascii(Uint8List bytes, int start, int length) {
  if (start < 0 || start + length > bytes.length) return '';
  return latin1.decode(Uint8List.sublistView(bytes, start, start + length));
}

/// Reads a NUL-terminated fixed-width tar string field.
String _asciiString(Uint8List bytes, int start, int length) {
  if (start < 0 || start + length > bytes.length) return '';
  var end = start;
  while (end < start + length && bytes[end] != 0) {
    end++;
  }
  return latin1.decode(Uint8List.sublistView(bytes, start, end)).trim();
}

/// Runs of printable ASCII long enough to be a filename or metadata token.
List<String> _printableRuns(List<int> bytes, {int minimum = 6}) {
  final runs = <String>{};
  final builder = StringBuffer();
  for (final byte in bytes) {
    if (byte >= 0x20 && byte <= 0x7E) {
      builder.writeCharCode(byte);
    } else {
      if (builder.length >= minimum) runs.add(builder.toString());
      builder.clear();
    }
  }
  if (builder.length >= minimum) runs.add(builder.toString());
  return runs.toList();
}
