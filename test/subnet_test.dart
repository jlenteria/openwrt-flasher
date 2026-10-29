import 'package:flutter_test/flutter_test.dart';

import 'package:openwrt_flasher/services/router_discovery_service.dart';

void main() {
  group('netmask to prefix', () {
    test('reads dotted masks', () {
      expect(RouterDiscoveryService.prefixFromMask('255.255.255.0'), 24);
      expect(RouterDiscoveryService.prefixFromMask('255.255.254.0'), 23);
      expect(RouterDiscoveryService.prefixFromMask('255.255.255.128'), 25);
      expect(RouterDiscoveryService.prefixFromMask('255.255.255.252'), 30);
      expect(RouterDiscoveryService.prefixFromMask('255.255.0.0'), 16);
    });

    test('reads CIDR and rejects nonsense', () {
      expect(RouterDiscoveryService.prefixFromMask('/24'), 24);
      expect(RouterDiscoveryService.prefixFromMask(null), isNull);
      expect(RouterDiscoveryService.prefixFromMask(''), isNull);
      expect(RouterDiscoveryService.prefixFromMask('255.255.1.0'), isNull,
          reason: 'a non-contiguous mask has no prefix length');
      expect(RouterDiscoveryService.prefixFromMask('banana'), isNull);
    });
  });

  group('subnet sizing', () {
    test('uses the real mask, not the first three octets', () {
      final network = LocalNetwork(
        localIp: '10.20.30.40',
        prefixLength: 24,
        source: 'test',
      );
      expect(network.networkAddress, '10.20.30.0');
      expect(network.hostCount, 254);
      expect(network.isWiderThanClassC, isFalse);
    });

    test('a /23 is a different network than the /24 the address looks like',
        () {
      final network = LocalNetwork(
        localIp: '192.168.10.55',
        prefixLength: 23,
        source: 'test',
      );
      expect(network.networkAddress, '192.168.10.0');
      expect(network.hostCount, 510);
      expect(network.firstHost, '192.168.10.1');
      expect(network.lastHost, '192.168.11.254');
      final hosts = network.hosts(limit: 600);
      expect(hosts.length, 510);
      expect(hosts.first, '192.168.10.1');
      expect(hosts.last, '192.168.11.254',
          reason: 'the sweep must cross the third octet, not stop at .10.254');
    });

    test('sweeps are capped', () {
      final network = LocalNetwork(
        localIp: '192.168.1.9',
        prefixLength: 24,
        source: 'test',
      );
      expect(network.hosts(limit: 20).length, 20);
      expect(network.hosts(limit: 20).last, '192.168.1.20');
    });

    test('a wide prefix refuses to sweep', () {
      final network = LocalNetwork(
        localIp: '10.0.0.5',
        prefixLength: 8,
        source: 'test',
      );
      expect(network.isWiderThanClassC, isTrue);
      expect(network.hostCount, 16777214);
      expect(network.hosts(limit: 1024).length, 1024);
    });
  });
}
