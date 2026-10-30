import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/router_info.dart';

/// The subnet the PC is currently attached to.
class LocalNetwork {
  const LocalNetwork({
    required this.localIp,
    required this.prefixLength,
    required this.source,
    this.isWireless = false,
  });

  final String localIp;
  final int prefixLength;

  /// Where the answer came from, for display when it is a guess.
  final String source;

  /// True when the only usable interface is Wi-Fi. Flashing is expected over an
  /// Ethernet cable, so this is surfaced before anything is written.
  final bool isWireless;

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

  /// Determines the IPv4 address of the wired LAN interface the router is on.
  ///
  /// Wi-Fi is deliberately not consulted. The router is expected on an Ethernet
  /// cable, and the Wi-Fi address usually belongs to a different subnet and a
  /// different router, which is why discovery used to point at the wrong place.
  ///
  /// dart:io does not expose netmasks, so the stock OpenWrt /24 is assumed.
  Future<LocalNetwork?> localNetwork() async {
    final candidates = await _siteLocalIPv4s();
    if (candidates.isEmpty) return null;
    final wifiDevices = await _wifiDeviceNames();

    bool wireless(String name) =>
        _looksWireless(name) || wifiDevices.contains(name);

    final physical = candidates.where((c) => !_isVirtual(c.name)).toList();
    final wired = physical.where((c) => !wireless(c.name)).toList();
    final chosen = wired.isNotEmpty
        ? wired.first
        : (physical.isNotEmpty ? physical.first : candidates.first);
    final onWifi = wireless(chosen.name);
    return LocalNetwork(
      localIp: chosen.ip,
      prefixLength: defaultPrefixLength,
      source: onWifi ? 'Wi-Fi (${chosen.name})' : 'Ethernet (${chosen.name})',
      isWireless: onWifi,
    );
  }

  Future<List<({String name, String ip})>> _siteLocalIPv4s() async {
    final result = <({String name, String ip})>[];
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          final value = address.address;
          if (isIPv4(value) && !_isLinkLocal(value)) {
            result.add((name: interface.name, ip: value));
          }
        }
      }
    } catch (_) {}
    return result;
  }

  /// macOS names both media `en0`/`en5`, so the hardware port list is the only
  /// way to tell Wi-Fi from Ethernet there.
  Future<Set<String>> _wifiDeviceNames() async {
    if (!Platform.isMacOS) return const {};
    try {
      final result = await Process.run(
        '/usr/sbin/networksetup',
        const ['-listallhardwareports'],
      );
      if (result.exitCode != 0) return const {};
      final devices = <String>{};
      var inWifiPort = false;
      for (final line in '${result.stdout}'.split('\n')) {
        final trimmed = line.trim();
        if (trimmed.startsWith('Hardware Port:')) {
          inWifiPort = trimmed.toLowerCase().contains('wi-fi');
        } else if (inWifiPort && trimmed.startsWith('Device:')) {
          devices.add(trimmed.substring('Device:'.length).trim());
          inWifiPort = false;
        }
      }
      return devices;
    } catch (_) {
      return const {};
    }
  }

  static bool _looksWireless(String name) {
    final n = name.toLowerCase();
    return n.contains('wi-fi') ||
        n.contains('wifi') ||
        n.contains('wireless') ||
        n.contains('wlan') ||
        n.startsWith('wl');
  }

  /// Tunnels, bridges and container interfaces are never the router's LAN.
  static bool _isVirtual(String name) {
    final n = name.toLowerCase();
    return n.startsWith('utun') ||
        n.startsWith('awdl') ||
        n.startsWith('llw') ||
        n.startsWith('bridge') ||
        n.startsWith('vmnet') ||
        n.startsWith('docker') ||
        n.startsWith('veth') ||
        n.startsWith('virbr') ||
        n.startsWith('tailscale') ||
        n.startsWith('tun') ||
        n.startsWith('tap') ||
        n.startsWith('zt');
  }

  static bool isIPv4(String value) {
    final parts = value.split('.');
    if (parts.length != 4) return false;
    return parts.every((part) {
      final n = int.tryParse(part);
      return n != null && n >= 0 && n <= 255;
    });
  }

  /// The addresses a router may answer on after a flash. The pre-flash address
  /// comes first; erasing the configuration usually returns OpenWrt to its
  /// stock address, which need not be the one it had before.
  static List<String> rebootHosts(String originalIp) {
    final hosts = <String>[originalIp];
    for (final candidate in const [
      '192.168.1.1',
      '10.0.0.1',
      '192.168.0.1',
      '192.168.8.1',
    ]) {
      if (!hosts.contains(candidate)) hosts.add(candidate);
    }
    return hosts;
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
          ? (network.isWireless
              ? 'This computer is connected over Wi-Fi ($base.0/'
                  '${network.prefixLength}). Plug the router into an Ethernet '
                  'port and search again — flashing over Wi-Fi is not '
                  'supported.'
              : 'Nothing answered on the usual gateway addresses of $base.0/'
                  '${network.prefixLength}. You can scan the whole subnet, or '
                  'type the router address in by hand.')
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
    if (network.isWireless) {
      return DiscoveryOutcome(
        network: network,
        candidates: [],
        warning: 'This computer is connected over Wi-Fi. Connect the router '
            'with an Ethernet cable and search again — sweeping or flashing '
            'over Wi-Fi is not supported.',
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
