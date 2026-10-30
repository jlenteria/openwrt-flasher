import 'package:flutter_test/flutter_test.dart';

import 'package:openwrt_flasher/services/hostkey_store.dart';
import 'package:openwrt_flasher/services/ssh_service.dart';

void main() {
  test('waitForBoot gives up at the deadline when nothing answers', () async {
    final service = SSHService(
      hostKeys: HostKeyStore(),
      onUntrustedHostKey: (_) async => false,
    );

    final started = DateTime.now();
    await expectLater(
      service.waitForBoot(
        // TEST-NET-1: reserved for documentation, so nothing answers.
        hosts: const ['192.0.2.1'],
        username: 'root',
        passwords: const [''],
        timeout: const Duration(milliseconds: 500),
      ),
      throwsA(isA<SSHOperationException>()),
    );
    expect(
      DateTime.now().difference(started),
      lessThan(const Duration(seconds: 5)),
      reason: 'the wait must honour its deadline, not drift past it',
    );
  });
}
