import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:network_info_plus/network_info_plus.dart';

import '../models/router_info.dart';

/// The subnet the PC is currently attached to.
class LocalNetwork {
  const LocalNetwork({
    required this.localIp,
    required this.prefixLength,
    required this.source,
  });

  final String localIp;
  final int prefixLength;

  /// Where the answer came from, for display when it is a guess.
  final String source;

  List<int> get _octets => localIp.split('.').map(int.parse).toList();

  int get _mask {
    if (prefixLength <= 0) return 0;
    return (0xFFFFFFFF << (32 - prefixLength)) & 0xFFFFFFFF;
  }

  int get _networkRaw {
    final octets = _octets;
    final raw =
        (octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3];
    return raw & _mask;
  }

  String _dotted(int value) => '${(value >> 24) & 0xFF}.'
      '${(value >> 16) & 0xFF}.${(value >> 8) & 0xFF}.${value & 0xFF}';

  String get networkAddress => _dotted(_networkRaw);

  /// The conventional first usable address of this network.
  String get firstHost => _dotted(_networkRaw + 1);

  /// The conventional last usable address of this network.
  String get lastHost {
    final broadcast = _networkRaw | (~_mask & 0xFFFFFFFF);
    return _dotted(broadcast - 1);
  }

  /// The address a sweep would start from, honouring the real mask rather than
  /// assuming the /24 the local address looks like.
  List<String> hosts({int limit = 1024}) {
    final count = hostCount < limit ? hostCount : limit;
    return [for (var i = 1; i <= count; i++) _dotted(_networkRaw + i)];
  }

  int get hostCount {
    if (prefixLength >= 31) return 1;
    final usable = (1 << (32 - prefixLength)) - 2;
    return usable < 1 ? 1 : usable;
  }

  bool get isWiderThanClassC => prefixLength < 24;
}

class DiscoveryOutcome {
  const DiscoveryOutcome({required this.network, required this.candidates, this.warning});
  final LocalNetwork? network;
  final List<RouterCandidate> candidates;
  final String? warning;
}

/// Finds candidate devices on the LAN. It never claims a device *is* the
/// router: only an SSH read of `/tmp/sysinfo/board_name` establishes identity.
class RouterDiscoveryService {
  static const gatewayProbeTimeout = Duration(seconds: 2);
  static const scanConcurrency = 24;
  static const defaultPrefixLength = 24;

  final NetworkInfo _networkInfo = NetworkInfo();

  /// Determines the local IPv4 address and, when the OS tells us, its prefix.
  Future<LocalNetwork?> localNetwork() async {
    String? ip;
    String? mask;
    var source = 'Wi-Fi interface';
    try {
      ip = await _networkInfo.getWifiIP();
      mask = await _networkInfo.getWifiSubmask();
    } catch (_) {
      // Not every desktop platform can answer the Wi-Fi query; fall through.
    }
    if (ip == null || !isIPv4(ip)) {
      final fallback = await _firstSiteLocalIPv4();
      if (fallback == null) return null;
      ip = fallback;
      source = 'default interface (no Wi-Fi information available)';
    }
    final prefix = prefixFromMask(mask) ?? defaultPrefixLength;
    return LocalNetwork(localIp: ip, prefixLength: prefix, source: source);
  }

  static bool isIPv4(String value) {
    final parts = value.split('.');
    if (parts.length != 4) return false;
    return parts.every((part) {
      final n = int.tryParse(part);
      return n != null && n >= 0 && n <= 255;
    });
  }

  static int? prefixFromMask(String? mask) {
    if (mask == null || mask.isEmpty) return null;
    if (mask.contains('/')) {
      final bits = int.tryParse(mask.split('/').last);
      return bits != null && bits > 0 && bits <= 32 ? bits : null;
    }
    if (!isIPv4(mask)) return null;
    var bits = 0;
    var seenHostBits = false;
    for (final octet in mask.split('.').map(int.parse)) {
      for (var shift = 7; shift >= 0; shift--) {
        final on = (octet >> shift) & 1 == 1;
        if (on) {
          if (seenHostBits) return null;
          bits++;
        } else {
          seenHostBits = true;
        }
      }
    }
    return bits == 0 ? null : bits;
  }

  Future<String?> _firstSiteLocalIPv4() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          final value = address.address;
          if (isIPv4(value) && !_isLinkLocal(value)) return value;
        }
      }
    } catch (_) {}
    return null;
  }

  static bool _isLinkLocal(String ip) => ip.startsWith('169.254.');

  /// Probes the usual gateway positions first. Cheap, and usually conclusive.
  Future<DiscoveryOutcome> probeGateways() async {
    final network = await localNetwork();
    if (network == null) {
      return const DiscoveryOutcome(
        network: null,
        candidates: [],
        warning: 'Could not determine this computer\'s IPv4 address. Is it on '
            'the same network as the router?',
      );
    }
    final base = network.localIp.split('.').take(3).join('.');
    final probeHosts = <String>{
      for (final offset in const ['1', '254', '100', '2', '20', '10'])
        '$base.$offset',
      // With a wider mask the gateway need not sit in the local /24 at all.
      if (network.isWiderThanClassC) network.firstHost,
      if (network.isWiderThanClassC) network.lastHost,
    }.toList();

    final found = await _probeAll(probeHosts);
    return DiscoveryOutcome(
      network: network,
      candidates: found,
      warning: found.isEmpty
          ? 'Nothing answered on the usual gateway addresses of $base.0/'
              '${network.prefixLength}. You can scan the whole subnet, or type '
              'the router address in by hand.'
          : null,
    );
  }

  /// Sweeps the subnet. This touches every host on the network, so the caller
  /// has to ask the user first, and the range is capped.
  Future<DiscoveryOutcome> scanSubnet({
    int hostLimit = scanConcurrency * 44,
    bool Function()? shouldContinue,
    void Function(int probed, int total)? onProgress,
  }) async {
    final network = await localNetwork();
    if (network == null) {
      return const DiscoveryOutcome(
        network: null,
        candidates: [],
        warning: 'Could not determine this computer\'s IPv4 address.',
      );
    }
    if (network.isWiderThanClassC) {
      return DiscoveryOutcome(
        network: network,
        candidates: [],
        warning: 'The local prefix is /${network.prefixLength}, which is too '
            'large to sweep safely. Enter the router address manually.',
      );
    }
    final hosts = network.hosts(limit: hostLimit);
    final found = await _probeAll(
      hosts,
      shouldContinue: shouldContinue,
      onProgress: onProgress,
    );
    return DiscoveryOutcome(
      network: network,
      candidates: found,
      warning: found.isEmpty ? 'Swept ${hosts.length} addresses, no match.' : null,
    );
  }

  Future<List<RouterCandidate>> _probeAll(
    List<String> hosts, {
    bool Function()? shouldContinue,
    void Function(int probed, int total)? onProgress,
    Duration timeout = gatewayProbeTimeout,
  }) async {
    final results = <RouterCandidate>[];
    for (var index = 0; index < hosts.length; index += scanConcurrency) {
      if (shouldContinue != null && !shouldContinue()) break;
      final batch = hosts.sublist(
        index,
        index + scanConcurrency > hosts.length ? hosts.length : index + scanConcurrency,
      );
      final settled = await Future.wait(
        batch.map<Future<RouterCandidate?>>((host) => _probe(host, timeout)),
      );
      for (final candidate in settled) {
        if (candidate != null) results.add(candidate);
      }
      onProgress?.call(index + batch.length, hosts.length);
    }
    results.sort((a, b) => _comparable(a.ip).compareTo(_comparable(b.ip)));
    return results;
  }

  int _comparable(String ip) {
    final parts = ip.split('.').map(int.parse).toList();
    return (parts[2] << 8) | parts[3];
  }

  Future<RouterCandidate?> _probe(String ip, Duration timeout) async {
    final banner = await _sshBanner(ip, timeout);
    if (banner != null) {
      return RouterCandidate(ip: ip, hint: 'ssh', banner: banner);
    }
    final luci = await _luciBanner(ip, timeout);
    if (luci != null) {
      return RouterCandidate(ip: ip, hint: 'luci', banner: luci);
    }
    return null;
  }

  /// Connects and reads the version string. A port that accepts a TCP
  /// connection but never speaks SSH is not a candidate.
  Future<String?> _sshBanner(String ip, Duration timeout) async {
    Socket? socket;
    try {
      socket = await Socket.connect(ip, 22, timeout: timeout);
      final firstChunk = await socket
          .firstWhere((chunk) => chunk.isNotEmpty)
          .timeout(timeout);
      final line = utf8
          .decode(firstChunk, allowMalformed: true)
          .split('\r\n')
          .first
          .trim();
      return line.startsWith('SSH-') ? line : 'SSH (no banner)';
    } catch (_) {
      return null;
    } finally {
      socket?.destroy();
    }
  }

  Future<String?> _luciBanner(String ip, Duration timeout) async {
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..autoUncompress = false;
    try {
      final request = await client
          .getUrl(Uri.parse('http://$ip/cgi-bin/luci/'))
          .timeout(timeout);
      final response = await request.close().timeout(timeout);
      final body = await response
          .transform(utf8.decoder)
          .take(16)
          .join()
          .timeout(timeout, onTimeout: () => '');
      await response.drain<void>();
      final lower = body.toLowerCase();
      if (lower.contains('luci') || lower.contains('openwrt')) {
        return 'LuCI web interface (HTTP ${response.statusCode})';
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }
}
