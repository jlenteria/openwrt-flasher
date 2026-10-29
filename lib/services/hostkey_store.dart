import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// A host key offered by an SSH server during the transport handshake.
class HostKeyOffer {
  const HostKeyOffer({
    required this.host,
    required this.keyType,
    required this.fingerprint,
  });

  final String host;
  final String keyType;

  /// Already formatted as `SHA256:<base64>`, the same form OpenSSH prints.
  final String fingerprint;

  @override
  String toString() => '$keyType $fingerprint';
}

/// Trust-on-first-use store for router SSH host keys.
///
/// Without this, dartssh2 accepts any host key silently and a device on the
/// LAN can impersonate the router and capture the root password.
class HostKeyStore {
  static const _fileName = 'known_hosts.json';

  Map<String, String>? _cache;

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File(dir.path + Platform.pathSeparator + _fileName);
  }

  Future<Map<String, String>> _load() async {
    final cached = _cache;
    if (cached != null) return cached;
    Map<String, String> loaded = {};
    try {
      final file = await _file();
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) {
          loaded = {
            for (final entry in decoded.entries)
              entry.key.toString(): entry.value.toString(),
          };
        }
      }
    } catch (_) {
      loaded = {};
    }
    _cache = loaded;
    return loaded;
  }

  /// Returns the pinned fingerprint for [host], or null if it has never been
  /// approved.
  Future<String?> pinnedFingerprint(String host) async {
    return (await _load())[host];
  }

  Future<bool> isTrusted(String host, String fingerprint) async {
    return await pinnedFingerprint(host) == fingerprint;
  }

  Future<void> pin(String host, String fingerprint) async {
    final map = await _load();
    if (map[host] == fingerprint) return;
    map[host] = fingerprint;
    await _save(map);
  }

  Future<void> unpin(String host) async {
    final map = await _load();
    if (map.remove(host) != null) await _save(map);
  }

  Future<void> _save(Map<String, String> map) async {
    try {
      final file = await _file();
      await file.writeAsString(jsonEncode(map), flush: true);
    } catch (_) {
      // A lost pin only costs the user a re-approval prompt on next launch.
    }
  }
}
