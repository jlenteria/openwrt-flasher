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
    this.interfaceName,
  });

  final String localIp;
  final int prefixLength;

  /// The OS interface name (`en5`, `eth0`, `Ethernet`), used to ask the OS for
  /// that interface's default gateway. Null when the caller did not supply it.
  final String? interfaceName;

  /// Where the answer came from, for display when it is a guess.
  final String source;

  /// True when the only usable interface is Wi-Fi. Flashing is expected over an
  /// Ethernet cable, so this is surfaced before anything is written.
  final bool isWireless;
}

class DiscoveryOutcome {
  const DiscoveryOutcome({
    required this.network,
    required this.candidates,
    this.warning,
    this.gateway,
  });
  final LocalNetwork? network;
  final List<RouterCandidate> candidates;
  final String? warning;

  /// The LAN interface's default gateway, when the OS reports one. On home
  /// networks this is the router itself.
  final String? gateway;
}

/// Finds candidate devices on the LAN. It never claims a device *is* the
/// router: only an SSH read of `/tmp/sysinfo/board_name` establishes identity.
class RouterDiscoveryService {
  static const gatewayProbeTimeout = Duration(seconds: 2);
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
      interfaceName: chosen.name,
    );
  }

  /// The default gateway configured on the LAN interface. macOS, Linux and
  /// Windows keep this per interface, so it is asked for by interface name:
  /// the system-wide default route may belong to Wi-Fi, which is never used.
  Future<String?> defaultGateway(LocalNetwork network) async {
    final interfaceName = network.interfaceName;
    if (interfaceName == null) return null;
    try {
      if (Platform.isMacOS) return await _macGateway(interfaceName);
      if (Platform.isLinux) return await _linuxGateway(interfaceName);
      if (Platform.isWindows) return await _windowsGateway(network.localIp);
    } catch (_) {}
    return null;
  }

  Future<String?> _macGateway(String interfaceName) async {
    // DHCP option 3 for that interface. `networksetup`/`netstat` are only a
    // fallback: their default route is the primary service, not this one.
    final dhcp = await Process.run(
      '/usr/sbin/ipconfig',
      ['getoption', interfaceName, 'router'],
    );
    if (dhcp.exitCode == 0) {
      final value = '${dhcp.stdout}'.trim();
      if (isIPv4(value)) return value;
    }
    final netstat = await Process.run('/usr/sbin/netstat', ['-rn', '-f', 'inet']);
    if (netstat.exitCode != 0) return null;
    for (final line in '${netstat.stdout}'.split('\n')) {
      final fields = line.trim().split(RegExp(r'\s+'));
      if (fields.length >= 4 &&
          fields[0] == 'default' &&
          fields[3] == interfaceName &&
          isIPv4(fields[1])) {
        return fields[1];
      }
    }
    // A manually configured service has no DHCP lease and is not the primary
    // default route, but System Settings still stores its router.
    return _macServiceRouter(interfaceName);
  }

  Future<String?> _macServiceRouter(String interfaceName) async {
    final order = await Process.run(
      '/usr/sbin/networksetup',
      ['-listnetworkserviceorder'],
    );
    if (order.exitCode != 0) return null;
    final header = RegExp(r'^\((?:\d+|\*)\)\s+(.+)$');
    final device = RegExp('Device:\\s*${RegExp.escape(interfaceName)}\\)');
    String? current;
    String? service;
    for (final line in '${order.stdout}'.split('\n')) {
      final trimmed = line.trim();
      final match = header.firstMatch(trimmed);
      if (match != null) {
        current = match.group(1)!.trim();
      } else if (current != null && device.hasMatch(trimmed)) {
        service = current;
        break;
      }
    }
    if (service == null) return null;

    final info = await Process.run(
      '/usr/sbin/networksetup',
      ['-getinfo', service],
    );
    if (info.exitCode != 0) return null;
    for (final line in '${info.stdout}'.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.startsWith('Router:')) {
        final value = trimmed.substring('Router:'.length).trim();
        if (isIPv4(value)) return value;
      }
    }
    return null;
  }

  Future<String?> _linuxGateway(String interfaceName) async {
    // GUI launches often have a PATH without sbin, where `ip` usually lives.
    for (final command in const ['ip', '/usr/sbin/ip', '/sbin/ip']) {
      ProcessResult route;
      try {
        route = await Process.run(
          command,
          ['route', 'show', 'default', 'dev', interfaceName],
        );
      } catch (_) {
        continue;
      }
      if (route.exitCode != 0) continue;
      for (final line in '${route.stdout}'.split('\n')) {
        final fields = line.trim().split(RegExp(r'\s+'));
        final via = fields.indexOf('via');
        if (via >= 0 && via + 1 < fields.length && isIPv4(fields[via + 1])) {
          return fields[via + 1];
        }
      }
    }
    return null;
  }

  Future<String?> _windowsGateway(String localIp) async {
    // route print columns: destination, netmask, gateway, interface IP, metric.
    final route = await Process.run('route', ['print', '-4']);
    if (route.exitCode != 0) return null;
    for (final line in '${route.stdout}'.split('\n')) {
      final fields = line.trim().split(RegExp(r'\s+'));
      if (fields.length >= 5 &&
          fields[0] == '0.0.0.0' &&
          fields[1] == '0.0.0.0' &&
          fields[3] == localIp &&
          isIPv4(fields[2])) {
        return fields[2];
      }
    }
    return null;
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

  static bool _isLinkLocal(String ip) => ip.startsWith('169.254.');

  /// Probes the default gateway of the wired LAN, which is the router on a
  /// normal network. There is no subnet sweep and no manual address: the
  /// gateway is the only address the app talks to.
  Future<DiscoveryOutcome> probeGateways() async {
    final network = await localNetwork();
    if (network == null) {
      return const DiscoveryOutcome(
        network: null,
        candidates: [],
        warning: 'Could not determine an IPv4 address for the Ethernet '
            'interface. Connect the router with a cable.',
      );
    }
    final gateway = await defaultGateway(network);
    if (gateway == null || gateway == network.localIp) {
      return DiscoveryOutcome(
        network: network,
        candidates: const [],
        warning: network.isWireless
            ? 'This computer is connected over Wi-Fi (${network.source}). Plug '
                'the router into an Ethernet port and search again — flashing '
                'over Wi-Fi is not supported.'
            : 'The Ethernet interface has no default gateway. Set it to DHCP '
                'so the router can hand out an address, then search again.',
      );
    }
    final candidate = await _probe(gateway, gatewayProbeTimeout);
    return DiscoveryOutcome(
      network: network,
      candidates: candidate == null ? const [] : [candidate],
      gateway: gateway,
      warning: candidate == null
          ? 'The LAN gateway $gateway did not answer on SSH or with a LuCI '
              'page. Check that the router is on and connected to this '
              'computer.'
          : null,
    );
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
