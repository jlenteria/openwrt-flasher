import 'package:flutter_test/flutter_test.dart';

import 'package:openwrt_flasher/services/router_discovery_service.dart';

void main() {
  group('post-flash addresses', () {
    test('probes the old address first, then the stock ones', () {
      expect(
        RouterDiscoveryService.rebootHosts('10.0.0.1'),
        ['10.0.0.1', '192.168.1.1', '192.168.0.1', '192.168.8.1'],
      );
    });

    test('keeps an unusual address and never repeats one', () {
      final hosts = RouterDiscoveryService.rebootHosts('192.168.8.1');
      expect(hosts.first, '192.168.8.1');
      expect(hosts.toSet().length, hosts.length);
    });
  });
}
