import 'dart:convert';
import 'dart:io';

enum FirmwareRole { defaultFirmware, upgradeFirmware }

/// A firmware image the app can fetch without making the user hunt for a file.
///
/// The default image boots OpenWrt in RAM (initramfs) for recovery. The upgrade
/// image is the example FlareWifi firmware installed permanently afterwards.
class DefaultFirmwareImage {
  const DefaultFirmwareImage({
    required this.role,
    required this.label,
    required this.details,
    required this.fileId,
    required this.fileName,
  });

  final FirmwareRole role;
  final String label;
  final String details;

  /// Google Drive file id from the shared link.
  final String fileId;

  /// Local name used on disk, chosen so the TFTP server URL stays readable.
  final String fileName;

  bool get isUpgrade => role == FirmwareRole.upgradeFirmware;

  String get downloadUrl => FirmwareDownloadService.driveDownloadUrl(fileId);
}

class FirmwareDownloadException implements Exception {
  const FirmwareDownloadException(this.message);

  final String message;

  @override
  String toString() => message;
}

class FirmwareDownloadService {
  static const defaultImages = [
    DefaultFirmwareImage(
      role: FirmwareRole.defaultFirmware,
      label: 'ZR-2660',
      details: 'Initramfs image for the ZR-2660 board',
      fileId: '1ku6Hk5ivIF9N0-1fua4DaQcfKOsYFPM5',
      fileName: 'default-firmware.bin',
    ),
    DefaultFirmwareImage(
      role: FirmwareRole.upgradeFirmware,
      label: 'FlareWifi',
      details: 'Example upgrade image; verify it matches this board before installing',
      fileId: '1qFELcvKvQ1JpzjsqxVIzVdHrpfT9sgqQ',
      fileName: 'flarewifi-firmware.bin',
    ),
  ];

  static List<DefaultFirmwareImage> get defaultFirmwareImages =>
      defaultImages.where((image) => !image.isUpgrade).toList();

  static List<DefaultFirmwareImage> get upgradeFirmwareImages =>
      defaultImages.where((image) => image.isUpgrade).toList();

  static String driveDownloadUrl(String fileId) =>
      'https://drive.google.com/uc?export=download&id=$fileId';

  /// Downloads [image] into [directory], replacing any previous copy.
  Future<File> downloadDefaultImage(
    DefaultFirmwareImage image,
    String directory, {
    void Function(int received, int? total)? onProgress,
  }) {
    return downloadDriveFile(
      image.fileId,
      directory,
      image.fileName,
      onProgress: onProgress,
    );
  }

  Future<File> downloadDriveFile(
    String fileId,
    String directory,
    String fileName, {
    void Function(int received, int? total)? onProgress,
  }) async {
    final folder = Directory(directory);
    if (!await folder.exists()) {
      await folder.create(recursive: true);
    }
    final target = File('$directory${Platform.pathSeparator}$fileName');
    final partial = File('${target.path}.part');

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);
    try {
      final first = await _get(client, Uri.parse(driveDownloadUrl(fileId)));
      var response = first.response;
      final cookies = first.cookies;

      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw FirmwareDownloadException(
          'Google Drive answered HTTP ${response.statusCode}.',
        );
      }

      if (_isHtml(response)) {
        final html = await utf8.decoder.bind(response).join();
        final confirm = _confirmUri(html);
        if (confirm == null) {
          throw const FirmwareDownloadException(
            'Google Drive returned a web page instead of the file. It may be '
            'private, deleted, or over its download quota.',
          );
        }
        final retry = await _get(client, confirm, cookies: cookies);
        response = retry.response;
        if (response.statusCode != HttpStatus.ok) {
          await response.drain<void>();
          throw FirmwareDownloadException(
            'Google Drive answered HTTP ${response.statusCode} for the '
            'confirmed download.',
          );
        }
      }

      final total = response.contentLength > 0 ? response.contentLength : null;
      var received = 0;
      final sink = partial.openWrite();
      try {
        await for (final chunk
            in response.timeout(const Duration(seconds: 60))) {
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, total);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }

      if (received == 0) {
        throw const FirmwareDownloadException(
          'The download was empty. The Drive link may have expired.',
        );
      }
      if (total != null && received != total) {
        throw FirmwareDownloadException(
          'The download stopped after $received of $total bytes.',
        );
      }

      if (await target.exists()) {
        await target.delete();
      }
      return partial.rename(target.path);
    } catch (error) {
      try {
        if (await partial.exists()) await partial.delete();
      } catch (_) {}
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  static Future<({HttpClientResponse response, List<String> cookies})> _get(
    HttpClient client,
    Uri uri, {
    List<String> cookies = const [],
  }) async {
    final request = await client.getUrl(uri);
    request.followRedirects = true;
    request.headers.set(HttpHeaders.userAgentHeader, 'openwrt-flasher');
    if (cookies.isNotEmpty) {
      request.headers.set(HttpHeaders.cookieHeader, cookies.join('; '));
    }
    final response = await request.close();
    final received = <String>[];
    response.headers.forEach((name, values) {
      if (name.toLowerCase() != HttpHeaders.setCookieHeader) return;
      for (final value in values) {
        received.add(value.split(';').first);
      }
    });
    return (response: response, cookies: received);
  }

  static bool _isHtml(HttpClientResponse response) {
    final type = response.headers.contentType?.mimeType ?? '';
    return type == 'text/html';
  }

  /// Large Drive files answer with an interstitial form that carries a confirm
  /// token (and lately a uuid); submitting the same form is what actually
  /// starts the download.
  static Uri? _confirmUri(String html) {
    final form = RegExp(
      r'<form[^>]*\baction="([^"]+)"',
      caseSensitive: false,
    ).firstMatch(html);
    if (form == null) return null;
    var base = Uri.parse(_unescape(form.group(1)!));
    final fields = <String, String>{};
    for (final input
        in RegExp(r'<input\b[^>]*>', caseSensitive: false).allMatches(html)) {
      final tag = input.group(0)!;
      final name = _attribute(tag, 'name');
      final value = _attribute(tag, 'value');
      if (name != null && value != null) fields[name] = _unescape(value);
    }
    if (fields.isEmpty) return base;
    base = base.replace(
      queryParameters: {...base.queryParameters, ...fields},
    );
    return base;
  }

  static String? _attribute(String tag, String name) {
    final match = RegExp(
      '\\b$name="([^"]*)"',
      caseSensitive: false,
    ).firstMatch(tag);
    return match?.group(1);
  }

  static String _unescape(String value) => value
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'");
}
