import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../models/router_info.dart';
import 'hostkey_store.dart';

/// Anything that prevents us from continuing a flash with certainty.
class SSHOperationException implements Exception {
  const SSHOperationException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// A remote command together with how it terminated.
///
/// The distinction between "the router said no" and "we never got an answer"
/// is the whole point: every safety check must fail closed on the latter.
class RemoteCommand {
  const RemoteCommand._({
    required this.executed,
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.failure,
  });

  factory RemoteCommand.completed({
    required int? exitCode,
    required String stdout,
    required String stderr,
  }) => RemoteCommand._(
    executed: true,
    exitCode: exitCode,
    stdout: stdout,
    stderr: stderr,
    failure: null,
  );

  factory RemoteCommand.notRun(String reason) => RemoteCommand._(
    executed: false,
    exitCode: null,
    stdout: '',
    stderr: '',
    failure: reason,
  );

  /// False when the command never reached the router, or the answer was lost.
  final bool executed;

  /// Null when the server closed the channel before reporting a status.
  final int? exitCode;
  final String stdout;
  final String stderr;
  final String? failure;

  bool get succeeded => executed && exitCode == 0;
  String get output => stdout.trim();
  String get combined => ('$stdout $stderr').trim();

  String get summary {
    if (!executed) return failure ?? 'the command never ran';
    if (combined.isNotEmpty) return combined;
    return exitCode == null ? 'no output and no exit status' : 'no output';
  }
}

class SSHService {
  SSHService({required this.hostKeys, required this.onUntrustedHostKey});

  static const socketTimeout = Duration(seconds: 8);
  static const handshakeTimeout = Duration(seconds: 12);
  static const authTimeout = Duration(seconds: 15);
  static const commandTimeout = Duration(seconds: 25);
  static const hashTimeout = Duration(minutes: 3);
  static const uploadIdleTimeout = Duration(seconds: 40);
  static const uploadOverallTimeout = Duration(minutes: 20);
  static const remoteFirmwarePath = '/tmp/openwrt-flasher-sysupgrade.bin';
  static const remoteBackupPath = '/tmp/openwrt-flasher-config-backup.tar.gz';

  /// Deliberately excludes space, quotes, `$`, backticks, `;`, `|` and `&`.
  static final RegExp _safeRemotePath = RegExp(r'^[A-Za-z0-9._/@+:-]+$');
  static final RegExp _sha256Hex = RegExp(r'^[0-9a-f]{64}$');

  final HostKeyStore hostKeys;

  /// Called when the server presents a host key we have not pinned. Return
  /// true to accept and pin it, false to abort the connection.
  final Future<bool> Function(HostKeyOffer offer) onUntrustedHostKey;

  SSHClient? _client;
  SSHSession? _activeUpload;
  Timer? _idleWatchdog;
  bool _cancelRequested = false;
  bool _hostKeyRejected = false;
  String? _stallReason;
  String? _upgradeProbeTool;

  /// Wraps a remote path for the shell after rejecting anything that could
  /// break out of the quoting.
  static String quotePath(String path, {String label = 'path'}) {
    if (path.isEmpty ||
        path.contains('..') ||
        !_safeRemotePath.hasMatch(path)) {
      throw SSHOperationException(
        'Refusing to use the $label "$path": only letters, digits and '
        '. _ / @ + : - are accepted, so that the value cannot break out of '
        'shell quoting.',
      );
    }
    return "'$path'";
  }

  /// Throws unless the command reached the router and exited 0. "Unknown" is
  /// treated as failure everywhere.
  static RemoteCommand require(RemoteCommand result, String action) {
    if (!result.executed) {
      throw SSHOperationException(
        '$action could not be performed: ${result.summary}',
      );
    }
    if (result.exitCode == null) {
      throw SSHOperationException(
        '$action could not be confirmed: the router closed the connection '
        'before reporting an exit status.',
      );
    }
    if (result.exitCode != 0) {
      throw SSHOperationException(
        '$action failed (exit ${result.exitCode}): ${result.summary}',
      );
    }
    return result;
  }

  Future<void> connect(String host, String username, String password) async {
    await disconnect();
    if (username.isEmpty) {
      throw const SSHOperationException('Enter a username.');
    }
    _hostKeyRejected = false;
    // Knowledge about which probe tools exist belongs to the device we are
    // about to talk to, not to this object.
    _upgradeProbeTool = null;
    SSHSocket? socket;
    SSHClient? client;
    try {
      socket = await SSHSocket.connect(host, 22, timeout: socketTimeout);
      client = SSHClient(
        socket,
        username: username,
        handshakeTimeout: handshakeTimeout,
        authTimeout: authTimeout,
        onPasswordRequest: () => password,
        onVerifyHostKey: (keyType, fingerprint) async {
          final shown = utf8.decode(fingerprint, allowMalformed: true);
          if (await hostKeys.isTrusted(host, shown)) return true;
          final accepted = await onUntrustedHostKey(
            HostKeyOffer(host: host, keyType: keyType, fingerprint: shown),
          );
          if (!accepted) {
            _hostKeyRejected = true;
            return false;
          }
          await hostKeys.pin(host, shown);
          return true;
        },
      );
      // dartssh2 only knows whether the password worked once this resolves.
      await client.authenticated;
      _client = client;
    } on SSHAuthError catch (error) {
      client?.close();
      socket?.destroy();
      throw SSHOperationException(
        'Login failed for $username@$host (${error.runtimeType}). '
        'Check the username and password.',
      );
    } catch (error) {
      client?.close();
      socket?.destroy();
      if (_hostKeyRejected) {
        throw SSHOperationException(
          'Connection stopped: you did not approve the host key for $host. '
          'If the router was re-flashed, its host key legitimately changed — '
          'use "Forget pinned host key" beside the router address and retry.',
        );
      }
      throw SSHOperationException(
        'Cannot open an SSH session on $host: $error',
      );
    }
  }

  Future<RemoteCommand> exec(String command, {Duration? timeout}) async {
    final client = _client;
    if (client == null) {
      return RemoteCommand.notRun('not connected to the router');
    }
    if (client.isClosed) {
      return RemoteCommand.notRun('the SSH connection has been closed');
    }
    try {
      final result = await client
          .runWithResult(command, stdout: true, stderr: true)
          .timeout(timeout ?? commandTimeout);
      return RemoteCommand.completed(
        exitCode: result.exitCode,
        stdout: utf8.decode(result.stdout, allowMalformed: true),
        stderr: utf8.decode(result.stderr, allowMalformed: true),
      );
    } on TimeoutException {
      return RemoteCommand.notRun(
        'the router did not answer within '
        '${(timeout ?? commandTimeout).inSeconds}s',
      );
    } catch (error) {
      return RemoteCommand.notRun('$error');
    }
  }

  /// Reads the device identity over SSH. Only an OpenWrt-family device with a
  /// readable board name and a working `sysupgrade` is accepted.
  Future<RouterInfo> identify(String host) async {
    final probe = await exec('test -r /tmp/sysinfo/board_name');
    if (!probe.executed) {
      throw SSHOperationException('Cannot probe the router: ${probe.summary}');
    }
    if (!probe.succeeded) {
      throw const SSHOperationException(
        'This device has no readable /tmp/sysinfo/board_name, so it is not an '
        'OpenWrt-family router. Refusing to flash.',
      );
    }

    final board = require(
      await exec('cat /tmp/sysinfo/board_name'),
      'Reading /tmp/sysinfo/board_name',
    );
    final boardName = board.output;
    if (boardName.isEmpty || boardName.contains('\n')) {
      throw SSHOperationException(
        'This device does not report a single board name ("$boardName"), so '
        'image compatibility cannot be established. Refusing to flash.',
      );
    }

    final sysupgrade = await exec('command -v sysupgrade');
    if (!sysupgrade.executed) {
      throw SSHOperationException(
        'Cannot probe the router: ${sysupgrade.summary}',
      );
    }
    if (!sysupgrade.succeeded || sysupgrade.output.isEmpty) {
      throw const SSHOperationException(
        'sysupgrade is not available on this device, so it is not a supported '
        'OpenWrt target. Refusing to flash.',
      );
    }

    final model = await exec('cat /tmp/sysinfo/model');
    final compat = await exec("tr '\\0' '\\n' < /proc/device-tree/compatible");
    final release = await exec('cat /etc/openwrt_release');
    final versionFile = await exec('cat /etc/openwrt_version');
    final hostname = await exec('uname -n');

    final compatIds = compat.succeeded
        ? compat.stdout
              .split('\n')
              .map((id) => id.trim())
              .where((id) => id.length > 3)
              .toList()
        : <String>[];

    return RouterInfo(
      ip: host,
      boardName: boardName,
      model: model.succeeded && model.output.isNotEmpty
          ? model.output
          : boardName,
      firmwareVersion: _parseVersion(release.output, versionFile.output),
      hostname: hostname.succeeded ? hostname.output : '',
      compatIds: compatIds,
    );
  }

  static String _parseVersion(String release, String versionFile) {
    final described = RegExp(
      r"DISTRIB_DESCRIPTION='([^']*)'",
    ).firstMatch(release)?.group(1);
    for (final candidate in [versionFile, described ?? '', release]) {
      final match = RegExp(r'\d+\.\d+(?:\.\d+)?').firstMatch(candidate);
      if (match != null) return match.group(0)!;
    }
    return 'unknown';
  }

  /// Free kilobytes on the filesystem holding [path]. Throws when it cannot be
  /// determined, because "unknown" must not be read as "enough".
  Future<int> freeSpaceKb(String path) async {
    final result = require(
      await exec('df -k ${quotePath(path, label: 'mount path')}'),
      'Checking free space',
    );
    final lines = result.stdout
        .trim()
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .toList();
    if (lines.isEmpty) {
      throw SSHOperationException('df returned nothing for $path.');
    }
    final fields = lines.last.trim().split(RegExp(r'\s+'));
    if (fields.length < 4) {
      throw SSHOperationException('Cannot parse df output: "${lines.last}"');
    }
    final kb = int.tryParse(fields[3].replaceAll(RegExp(r'[^0-9]'), ''));
    if (kb == null) {
      throw SSHOperationException(
        'Cannot parse free space from "${lines.last}".',
      );
    }
    return kb;
  }

  Future<String> remoteSha256(String path) async {
    final result = require(
      await exec(
        'sha256sum ${quotePath(path, label: 'remote path')}',
        timeout: hashTimeout,
      ),
      'Hashing the uploaded image on the router',
    );
    final hash = result.output.split(RegExp(r'\s+')).first.toLowerCase();
    if (!_sha256Hex.hasMatch(hash)) {
      throw SSHOperationException(
        'sha256sum on this device returned "$hash", which is not a SHA-256 '
        'digest, so the upload cannot be verified. Refusing to flash.',
      );
    }
    return hash;
  }

  /// True when an upgrade is already running. Throws when the device cannot
  /// answer, rather than assuming it is idle.
  ///
  /// Uses pgrep/pidof rather than `ps | grep`, which matches the very shell
  /// running the check and so reports a permanent false positive.
  Future<bool> isUpgradeInProgress() async {
    if (_upgradeProbeTool == null) {
      final probe = await exec(
        'if command -v pgrep >/dev/null 2>&1; then echo pgrep; '
        'elif command -v pidof >/dev/null 2>&1; then echo pidof; '
        'else exit 1; fi',
      );
      if (!probe.executed) {
        throw SSHOperationException(
          'Cannot check whether an upgrade is running: ${probe.summary}',
        );
      }
      final tool = probe.output;
      if (tool != 'pgrep' && tool != 'pidof') {
        throw const SSHOperationException(
          'This device has neither pgrep nor pidof, so a running upgrade '
          'cannot be detected. Refusing to flash.',
        );
      }
      _upgradeProbeTool = tool == 'pgrep'
          ? 'pgrep -x sysupgrade'
          : 'pidof sysupgrade';
    }

    final result = await exec('$_upgradeProbeTool 2>/dev/null');
    if (!result.executed) {
      throw SSHOperationException(
        'Cannot check whether an upgrade is running: ${result.summary}',
      );
    }
    return result.exitCode == 0 && result.output.isNotEmpty;
  }

  /// Streams the local file to the router over the SSH session channel.
  ///
  /// Deliberately not SFTP: a router can accept SSH commands and still have no
  /// SFTP subsystem (Dropbear without openssh-sftp-server), and dartssh2 then
  /// waits for a handshake that never comes. `cat > file` only needs the shell
  /// every supported OpenWrt device already provides. An idle transfer is
  /// aborted rather than hanging, cancellation kills the channel at any stage,
  /// and a partial file is always removed.
  Future<void> uploadFirmware(
    String localPath,
    String remotePath,
    void Function(double progress) onProgress,
  ) async {
    final client = _client;
    if (client == null) {
      throw const SSHOperationException('Not connected to the router.');
    }
    if (client.isClosed) {
      throw const SSHOperationException(
        'The SSH connection closed before upload.',
      );
    }
    _cancelRequested = false;
    _stallReason = null;

    final quotedRemote = quotePath(remotePath, label: 'remote path');
    final partPath = '$remotePath.part';
    final quotedPart = quotePath(partPath, label: 'remote path');

    final file = File(localPath);
    if (!await file.exists()) {
      throw SSHOperationException('Firmware file is missing: $localPath');
    }
    final fileSize = await file.length();
    if (fileSize == 0) {
      throw const SSHOperationException('The selected firmware file is empty.');
    }

    final neededKb = (fileSize / 1024).ceil() + 10240;
    final freeKb = await freeSpaceKb('/tmp');
    if (freeKb < neededKb) {
      throw SSHOperationException(
        'Not enough room in /tmp: ${freeKb}kB free, about ${neededKb}kB needed. '
        'Writing to a full tmpfs can crash the router mid-flash.',
      );
    }
    if (_cancelRequested) {
      throw const SSHOperationException(
        'Upload cancelled. The partial image was deleted and nothing was '
        'flashed.',
      );
    }

    SSHSession? session;
    final errorText = StringBuffer();
    try {
      try {
        session = await client
            .execute('cat > $quotedPart')
            .timeout(const Duration(seconds: 15));
      } on TimeoutException {
        throw const SSHOperationException(
          'The router did not start the upload within 15s. Nothing was flashed.',
        );
      } on Object catch (error) {
        throw SSHOperationException(
          'The router refused to start the upload: $error',
        );
      }
      _activeUpload = session;
      // Both pipes must be drained or the channel stalls once its window fills.
      session.stdout.listen((_) {}, onError: (_) {});
      session.stderr.listen((data) {
        if (errorText.length < 4096) {
          errorText.write(utf8.decode(data, allowMalformed: true));
        }
      }, onError: (_) {});

      var sent = 0;
      var lastShownPercent = -1;
      _armIdleWatchdog();

      final stream = file
          .openRead()
          .map<Uint8List>(
            (chunk) => chunk is Uint8List ? chunk : Uint8List.fromList(chunk),
          )
          .transform(
            StreamTransformer<Uint8List, Uint8List>.fromHandlers(
              handleData: (chunk, sink) {
                sent += chunk.length;
                _lastProgressAt = DateTime.now();
                final percent = (sent / fileSize * 100).clamp(0, 100).toInt();
                if (percent != lastShownPercent) {
                  lastShownPercent = percent;
                  onProgress((sent / fileSize).clamp(0.0, 1.0));
                }
                sink.add(chunk);
              },
            ),
          );

      try {
        // Backpressure comes from the SSH channel window, so this only runs
        // ahead of the router by at most one window.
        await session.stdin.addStream(stream).timeout(uploadOverallTimeout);
      } on TimeoutException {
        throw SSHOperationException(
          'Upload exceeded ${uploadOverallTimeout.inMinutes} minutes.',
        );
      } on Object catch (error) {
        if (_cancelRequested) {
          throw const SSHOperationException(
            'Upload cancelled. The partial image was deleted and nothing was '
            'flashed.',
          );
        }
        if (_stallReason != null) {
          throw SSHOperationException(
            '$_stallReason $sent of $fileSize bytes had been sent.',
          );
        }
        throw SSHOperationException('The upload was interrupted: $error');
      }
      try {
        await session.stdin.close().timeout(const Duration(seconds: 15));
      } on TimeoutException {
        // The exit status below still decides whether anything was written.
      } catch (_) {
        // A destroyed channel (cancel or stall) is reported below.
      }

      final exitCode = await session.waitForExit(
        timeout: const Duration(seconds: 60),
      );
      if (_cancelRequested) {
        throw const SSHOperationException(
          'Upload cancelled. The partial image was deleted and nothing was '
          'flashed.',
        );
      }
      if (_stallReason != null) {
        throw SSHOperationException(
          '$_stallReason $sent of $fileSize bytes had been sent.',
        );
      }
      if (exitCode == null) {
        throw const SSHOperationException(
          'The router never reported that the upload finished, so the image '
          'cannot be trusted. Nothing was flashed.',
        );
      }
      if (exitCode != 0) {
        final detail = errorText.toString().trim();
        throw SSHOperationException(
          'The router refused the upload (exit $exitCode)'
          '${detail.isEmpty ? '.' : ': $detail'}',
        );
      }
      if (sent != fileSize) {
        throw SSHOperationException(
          'Upload ended after $sent of $fileSize bytes.',
        );
      }

      require(await exec('sync'), 'Flushing the uploaded image to disk');
      require(
        await exec('mv $quotedPart $quotedRemote'),
        'Moving the uploaded image into place',
      );
      await exec('sync');
    } finally {
      _cancelIdleWatchdog();
      _activeUpload = null;
      try {
        session?.close();
      } catch (_) {}
      // Never leave a truncated image that could be mistaken for a good one.
      await exec('rm -f $quotedPart');
    }
  }

  DateTime? _lastProgressAt;

  void _armIdleWatchdog() {
    _lastProgressAt = DateTime.now();
    _cancelIdleWatchdog();
    _idleWatchdog = Timer.periodic(const Duration(seconds: 5), (timer) {
      final last = _lastProgressAt;
      if (last != null && DateTime.now().difference(last) < uploadIdleTimeout) {
        return;
      }
      timer.cancel();
      _stallReason =
          'Upload made no progress for ${uploadIdleTimeout.inSeconds}s.';
      _abortActiveUpload();
    });
  }

  void _cancelIdleWatchdog() {
    _idleWatchdog?.cancel();
    _idleWatchdog = null;
  }

  /// Tears down the in-flight upload channel, unblocking any pending write.
  void _abortActiveUpload() {
    final session = _activeUpload;
    _activeUpload = null;
    try {
      session?.channel.destroy();
    } catch (_) {}
  }

  /// Requests cancellation of an in-flight upload.
  Future<void> cancelUpload() async {
    _cancelRequested = true;
    _abortActiveUpload();
  }

  /// Runs `sysupgrade -T`, treating a missing or unreported status as a
  /// failure. This is the last gate before the router is written to.
  Future<void> verifyFirmware(String remotePath) async {
    final result = await exec(
      'sysupgrade -T ${quotePath(remotePath, label: 'remote path')} 2>&1',
      timeout: const Duration(minutes: 2),
    );
    if (!result.executed) {
      throw SSHOperationException(
        'The compatibility test never ran, so the image is unverified: '
        '${result.summary}',
      );
    }
    if (result.exitCode == null) {
      throw SSHOperationException(
        'The compatibility test reported no exit status, so it proved nothing. '
        'Output: ${result.summary}',
      );
    }
    final lower = result.combined.toLowerCase();
    for (final marker in const [
      'invalid',
      'not supported',
      'unsupported',
      'bad image',
      'check failed',
    ]) {
      if (lower.contains(marker)) {
        throw SSHOperationException(
          'The router rejected this image ("$marker"): ${result.summary}',
        );
      }
    }
    if (result.exitCode != 0) {
      throw SSHOperationException(
        'sysupgrade -T exited ${result.exitCode}, so the router does not '
        'accept this image: ${result.summary}',
      );
    }
  }

  /// Returns the router's saved configuration, or null when the device declines
  /// to produce one. A failure to even ask is an error, not a silent skip.
  Future<List<int>?> createConfigBackup() async {
    final quoted = quotePath(remoteBackupPath, label: 'remote path');
    final result = await exec(
      'sysupgrade -b $quoted 2>&1',
      timeout: const Duration(minutes: 2),
    );
    if (!result.executed || result.exitCode == null) {
      throw SSHOperationException(
        'Could not ask the router for a configuration backup: ${result.summary}',
      );
    }

    final exists = await exec('test -s $quoted');
    if (!exists.executed) {
      throw SSHOperationException(
        'Could not confirm the backup file: ${exists.summary}',
      );
    }
    if (!exists.succeeded) {
      await exec('rm -f $quoted');
      return null;
    }

    // Read it back over the command channel for the same reason the upload
    // uses it: SFTP is optional on OpenWrt, the shell is not.
    try {
      return await _readRemoteBytes(quoted, label: 'configuration backup');
    } finally {
      await exec('rm -f $quoted');
    }
  }

  Future<Uint8List> _readRemoteBytes(
    String quotedPath, {
    required String label,
  }) async {
    final client = _client;
    if (client == null) {
      throw const SSHOperationException('Not connected to the router.');
    }
    final SSHRunResult result;
    try {
      result = await client
          .runWithResult('cat $quotedPath', stdout: true, stderr: true)
          .timeout(const Duration(minutes: 2));
    } on TimeoutException {
      throw SSHOperationException(
        'Reading the $label from the router did not finish within 2 minutes.',
      );
    } on Object catch (error) {
      throw SSHOperationException(
        'Reading the $label from the router failed: $error',
      );
    }
    if (result.exitCode != 0) {
      final detail = utf8.decode(result.stderr, allowMalformed: true).trim();
      throw SSHOperationException(
        'Reading the $label from the router failed '
        '${result.exitCode == null ? 'without an exit status' : '(exit ${result.exitCode})'}'
        '${detail.isEmpty ? '.' : ': $detail'}',
      );
    }
    return result.stdout;
  }

  /// Issues the flash. Deliberately returns nothing useful: a successful
  /// sysupgrade tears down the SSH session, so silence here is not evidence of
  /// success. Only [waitForBoot] can establish that.
  Future<void> flashFirmware(
    String remotePath, {
    required bool keepSettings,
  }) async {
    final quoted = quotePath(remotePath, label: 'remote path');
    if (await isUpgradeInProgress()) {
      throw const SSHOperationException(
        'An upgrade is already running on the router. Nothing was flashed.',
      );
    }
    await exec('sync');
    // -n discards /etc; the caller must put that choice in front of the user.
    final command =
        'sysupgrade ${keepSettings ? '' : '-n '}$quoted '
        '</dev/null >/tmp/openwrt-flasher.log 2>&1 &';
    final result = await exec(command, timeout: const Duration(seconds: 30));
    if (result.executed && result.exitCode != null && result.exitCode != 0) {
      throw SSHOperationException(
        'sysupgrade could not be started (exit ${result.exitCode}): '
        '${result.summary}',
      );
    }
    // A dropped channel, a timeout, or no status is what a flash that really
    // started looks like. The outcome is decided by waitForBoot.
  }

  /// A value that changes on every boot, from
  /// `/proc/sys/kernel/random/boot_id`. Null when the kernel does not expose
  /// it, in which case a restart cannot be proven and is not required.
  Future<String?> bootId() async {
    try {
      final result = await exec('cat /proc/sys/kernel/random/boot_id');
      if (!result.executed || !result.succeeded) return null;
      final id = result.output.trim();
      return id.isEmpty ? null : id;
    } catch (_) {
      return null;
    }
  }

  /// Waits, with a time limit, for the router to come back and re-reads its
  /// identity. This is the only evidence that a flash really worked.
  ///
  /// Every host in [hosts] is probed each cycle, because erasing the
  /// configuration usually moves the router to its stock address. A session is
  /// only accepted when it reports [expectedBoard] (when given).
  ///
  /// [previousBootId] is the boot id read before `sysupgrade` was issued. When
  /// the router still reports it, the old system is answering while the image
  /// is being written, so that session is not a confirmation.
  ///
  /// [passwords] are tried in order on each attempt: a flash that erased the
  /// configuration leaves stock OpenWrt with no root password at all.
  ///
  /// [shouldStop] is polled between attempts so the user can stop waiting
  /// without treating the flash as failed.
  Future<RouterInfo> waitForBoot({
    required List<String> hosts,
    required String username,
    required List<String> passwords,
    String? expectedBoard,
    String? previousBootId,
    bool Function()? shouldStop,
    Duration timeout = const Duration(minutes: 3),
    void Function(String status)? onStatus,
  }) async {
    final deadline = DateTime.now().add(timeout);
    Object? lastError;
    var sawOpenPort = false;
    var settled = false;

    bool stopped() => shouldStop?.call() ?? false;

    while (DateTime.now().isBefore(deadline)) {
      if (stopped()) {
        throw const SSHOperationException(
          'You stopped waiting before the router confirmed the flash.',
        );
      }
      final reachable = await _reachableHosts(hosts);
      if (reachable.isEmpty) {
        await Future<void>.delayed(const Duration(seconds: 3));
        continue;
      }
      sawOpenPort = true;
      if (!settled) {
        // First boot can restart dropbear; give it a moment before a session.
        onStatus?.call('Router is back online, confirming the new firmware...');
        await Future<void>.delayed(const Duration(seconds: 5));
        settled = true;
        if (stopped()) {
          throw const SSHOperationException(
            'You stopped waiting before the router confirmed the flash.',
          );
        }
      }
      for (final host in reachable) {
        for (final password in passwords) {
          if (stopped()) {
            throw const SSHOperationException(
              'You stopped waiting before the router confirmed the flash.',
            );
          }
          try {
            await connect(host, username, password);
            final info = await identify(host);
            if (expectedBoard == null || info.boardName == expectedBoard) {
              // A device that still runs the pre-flash boot is the old system
              // answering while sysupgrade writes the image. Confirming it
              // would report success before anything has restarted.
              if (previousBootId != null) {
                final currentBootId = await bootId();
                if (currentBootId != null && currentBootId == previousBootId) {
                  lastError = SSHOperationException(
                    'The router at $host has not restarted since the flash was '
                    'issued.',
                  );
                  await disconnect();
                  break;
                }
              }
              return info;
            }
            lastError = SSHOperationException(
              'The device at $host reports board "${info.boardName}".',
            );
            await disconnect();
          } catch (error) {
            lastError = error;
            await disconnect();
          }
        }
      }
      onStatus?.call('Waiting for the router to finish booting...');
      await Future<void>.delayed(const Duration(seconds: 5));
    }

    if (!sawOpenPort) {
      throw SSHOperationException(
        'The router did not accept SSH connections on '
        '${hosts.join(', ')} within ${timeout.inMinutes} minutes. It may still '
        'be booting, or the flash may have failed. Check the router before '
        'retrying.',
      );
    }
    throw SSHOperationException(
      'The router answered on port 22 but a session could not be confirmed'
      '${expectedBoard == null ? '' : ' as "$expectedBoard"'} within '
      '${timeout.inMinutes} minutes: $lastError',
    );
  }

  /// Probes port 22 on every host concurrently and returns the reachable ones.
  Future<List<String>> _reachableHosts(List<String> hosts) async {
    final results = await Future.wait(
      hosts.map((host) async {
        Socket? probe;
        try {
          probe = await Socket.connect(
            host,
            22,
            timeout: const Duration(seconds: 3),
          );
          return host;
        } catch (_) {
          return null;
        } finally {
          probe?.destroy();
        }
      }),
    );
    return [for (final host in results) ?host];
  }

  Future<void> disconnect() async {
    _cancelIdleWatchdog();
    _abortActiveUpload();
    final client = _client;
    _client = null;
    try {
      client?.close();
    } catch (_) {}
  }
}
