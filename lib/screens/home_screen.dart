import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';

import '../models/firmware_info.dart';
import '../models/router_info.dart';
import '../services/firmware_download_service.dart';
import '../services/firmware_service.dart';
import '../services/hostkey_store.dart';
import '../services/router_discovery_service.dart';
import '../services/ssh_service.dart';
import '../services/serial_service.dart';
import '../services/http_server_service.dart';

/// The desktop OS the recovery guide is written for.
enum HostOs {
  windows('Windows', 'Windows PC'),
  macos('macOS', 'Mac'),
  linux('Linux', 'Linux PC');

  const HostOs(this.label, this.machine);
  final String label;

  /// How the guide refers to the user's computer.
  final String machine;

  static HostOs get current => Platform.isWindows
      ? HostOs.windows
      : (Platform.isMacOS ? HostOs.macos : HostOs.linux);
}

enum FlashStep {
  idle(''),
  connect('Connect'),
  upload('Upload'),
  checksum('Checksum'),
  backup('Backup config'),
  compatTest('Compatibility test'),
  install('Install'),
  rebootWait('Reboot + confirm');

  const FlashStep(this.label);
  final String label;
}

enum CheckOutcome { passed, warning, failed }

class CheckRow {
  const CheckRow(this.name, this.outcome, this.detail);
  final String name;
  final CheckOutcome outcome;
  final String detail;
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    this.autoDiscover = true,
    this.autoDiscoverSerial = true,
    this.hostOs,
  });

  /// Overrides the detected OS so each platform's guide can be tested.
  final HostOs? hostOs;

  /// Exposed so a test can assert the flash cannot be pressed while blocked.
  static const Key flashButtonKey = ValueKey('flash-firmware-button');

  /// Kept off in tests, where a real LAN probe would leave timers pending.
  final bool autoDiscover;

  /// Kept off in tests, where libserialport native libs may not be present.
  final bool autoDiscoverSerial;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final HostKeyStore _hostKeys = HostKeyStore();
  late final SSHService _ssh = SSHService(
    hostKeys: _hostKeys,
    onUntrustedHostKey: _approveHostKey,
  );
  final RouterDiscoveryService _discovery = RouterDiscoveryService();
  final FirmwareService _firmwareService = FirmwareService();
  final FirmwareDownloadService _firmwareDownloads = FirmwareDownloadService();
  final SerialService _serialService = SerialService();
  final HttpServerService _httpServerService = HttpServerService();

  final TextEditingController _usernameController =
      TextEditingController(text: 'root');
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _manualIpController = TextEditingController();

  // Recovery state
  String _selectedSerialPort = '';
  List<String> _availablePorts = [];
  bool _serialConnected = false;
  final StringBuffer _consoleBuffer = StringBuffer();
  final ScrollController _consoleScrollController = ScrollController();
  StreamSubscription<String>? _serialSub;
  String _recoveryStatus = 'Not connected';
  String? _openwrtInitramfsPath;
  String? _sysupgradeImagePath;
  bool _downloadingDefault = false;
  String? _initramfsDownloadStatus;
  String? _upgradeDownloadStatus;
  // Each OS's own TFTP server serves a different folder by default.
  late String _tftpDir = switch (_os) {
    HostOs.windows => r'C:\tftp',
    HostOs.macos => '/private/tftpboot',
    HostOs.linux => '/srv/tftp',
  };
  late final TextEditingController _tftpDirController =
      TextEditingController(text: _tftpDir);
  final TextEditingController _consoleInputController = TextEditingController();
  bool _httpServerRunning = false;
  String? _httpServerUrl;
  String? _httpServerMessage;
  bool _httpServerError = false;

  LocalNetwork? _network;
  List<RouterCandidate> _candidates = [];
  String? _selectedIp;
  RouterInfo? _router;
  String _discoveryStatus = 'Not searched yet.';
  bool _discoveryBusy = false;
  bool _sweepCancelled = false;

  String? _firmwarePath;
  FirmwareInfo? _firmware;
  bool _ackUnverified = false;
  bool _firmwareBusy = false;

  bool _keepSettings = false;
  bool _backupConfig = true;

  List<CheckRow> _checks = [];
  bool _preflightOk = false;

  bool _flashing = false;
  bool _installStarted = false;
  bool _cancelRequested = false;

  /// Set when the user walks away from the progress screen. The flash future
  /// is still unwinding at that point, so every later UI write is dropped.
  bool _flowAbandoned = false;
  FlashStep _step = FlashStep.idle;
  double _progress = 0;
  String _status = '';
  String? _flashError;
  RouterInfo? _verifiedAfter;
  String? _backupFile;

  /// True once `sysupgrade` has been started. From then on the image is
  /// written even if the router cannot be re-identified, so a confirmation
  /// timeout is reported as "installed but unconfirmed", never as a failure.
  bool _flashIssued = false;
  String? _confirmationNote;
  bool _skipConfirmation = false;
  final TextEditingController _confirmIpController = TextEditingController();
  bool _confirming = false;
  String? _confirmError;

  /// The version the router reported before we wrote to it, for the result
  /// screen. Never a placeholder.
  String? _versionBefore;

  /// The router's boot id before the flash. A confirmation that still reports
  /// it describes the old system, not the new firmware.
  String? _bootIdBefore;

  @override
  void initState() {
    super.initState();
    _passwordController.addListener(_invalidateChecks);
    _usernameController.addListener(_invalidateChecks);
    if (widget.autoDiscoverSerial) {
      _refreshSerialPorts();
    }
    _serialSub = _serialService.dataStream.listen((data) {
      _runOnUi(() {
        _consoleBuffer.write(data);
        // Auto-scroll
        Future.delayed(const Duration(milliseconds: 50), () {
          if (_consoleScrollController.hasClients) {
            _consoleScrollController.animateTo(
              _consoleScrollController.position.maxScrollExtent,
              duration: const Duration(milliseconds: 100),
              curve: Curves.easeOut,
            );
          }
        });
      });
    });
    if (widget.autoDiscover) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _probeGateways());
    }
  }

  @override
  void dispose() {
    _passwordController.removeListener(_invalidateChecks);
    _usernameController.removeListener(_invalidateChecks);
    _ssh.disconnect();
    _serialSub?.cancel();
    _serialService.dispose();
    _httpServerService.dispose();
    _passwordController.dispose();
    _usernameController.dispose();
    _manualIpController.dispose();
    _confirmIpController.dispose();
    _consoleScrollController.dispose();
    _tftpDirController.dispose();
    _consoleInputController.dispose();
    super.dispose();
  }

  void _refreshSerialPorts() {
    _runOnUi(() {
      _availablePorts = _serialService.getAvailablePorts();
      if (_availablePorts.isNotEmpty && _selectedSerialPort.isEmpty) {
        _selectedSerialPort = _availablePorts.first;
      }
    });
  }

  Future<void> _connectSerial() async {
    if (_selectedSerialPort.isEmpty) {
      _showErrorToast('Choose a serial port first.');
      return;
    }
    _runOnUi(() => _recoveryStatus = 'Connecting...');
    final success = await _serialService.connect(_selectedSerialPort);
    _runOnUi(() {
      _serialConnected = success;
      _recoveryStatus = success ? 'Connected to $_selectedSerialPort' : 'Failed to connect';
    });
    if (!success) {
      _showErrorToast(
        'Could not open $_selectedSerialPort: '
        '${_serialService.lastError ?? 'unknown error'}. Check that the USB '
        'serial adapter is plugged in and not used by another program.',
      );
    }
  }

  void _disconnectSerial() {
    _serialService.disconnect();
    _runOnUi(() {
      _serialConnected = false;
      _recoveryStatus = 'Disconnected';
    });
  }

  void _sendSerial(String data) {
    _serialService.write(data);
  }

  void _clearConsole() {
    _runOnUi(() {
      _consoleBuffer.clear();
    });
  }

  Future<void> _pickOpenWrtInitramfs() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['bin', 'img', 'gz'],
    );
    final path = result?.files.single.path;
    if (path != null) {
      _runOnUi(() => _openwrtInitramfsPath = path);
    }
  }

  Future<void> _pickSysupgradeImage() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['bin', 'img'],
    );
    final path = result?.files.single.path;
    if (path != null) {
      _runOnUi(() => _sysupgradeImagePath = path);
    }
  }

  Future<void> _downloadDefaultImage(DefaultFirmwareImage image) async {
    if (_downloadingDefault) return;
    final directory = _tftpDir;
    _setDownloadStatus(image, 'Downloading ${image.label}...');
    _runOnUi(() => _downloadingDefault = true);
    var lastPercent = -1;
    try {
      final file = await _firmwareDownloads.downloadDefaultImage(
        image,
        directory,
        onProgress: (received, total) {
          final percent = total == null ? null : received * 100 ~/ total;
          if (percent == lastPercent) return;
          lastPercent = percent ?? -1;
          _setDownloadStatus(
            image,
            percent == null
                ? 'Downloading ${image.label}: ${_formatBytes(received)}'
                : 'Downloading ${image.label}: $percent%',
          );
        },
      );
      final role = image.isUpgrade ? 'upgrade' : 'default';
      final message = 'Saved ${_basename(file.path)} to $directory and selected '
          'it as the $role firmware.';
      _runOnUi(() {
        if (image.isUpgrade) {
          _sysupgradeImagePath = file.path;
          _upgradeDownloadStatus = message;
        } else {
          _openwrtInitramfsPath = file.path;
          _initramfsDownloadStatus = message;
        }
        _recoveryStatus = message;
      });
    } catch (e) {
      _setDownloadStatus(image, 'Download failed: $e');
      _showErrorToast(
        'Could not download the ${image.label} firmware: $e If $directory is '
        'not writable, run the command in step 1 first or pick another folder '
        'in step 4.',
      );
    } finally {
      _runOnUi(() => _downloadingDefault = false);
    }
  }

  void _setDownloadStatus(DefaultFirmwareImage image, String message) {
    _runOnUi(() {
      if (image.isUpgrade) {
        _upgradeDownloadStatus = message;
      } else {
        _initramfsDownloadStatus = message;
      }
    });
  }

  static String _formatBytes(int bytes) => bytes >= 1024 * 1024
      ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB'
      : '${(bytes / 1024).toStringAsFixed(0)} KB';

  Future<void> _copyToTftp() async {
    try {
      final dir = Directory(_tftpDir);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      for (final path in [_openwrtInitramfsPath, _sysupgradeImagePath]) {
        if (path == null) continue;
        final target = '$_tftpDir${Platform.pathSeparator}${_basename(path)}';
        // A default download already lives in this folder.
        if (File(path).absolute.path == File(target).absolute.path) continue;
        await File(path).copy(target);
      }
      _runOnUi(() => _recoveryStatus = 'Files copied to $_tftpDir');
    } catch (e) {
      _runOnUi(() => _recoveryStatus = 'Error copying files: $e');
      _showErrorToast('Could not copy the files to $_tftpDir: $e');
    }
  }

  Future<void> _startHttpServer() async {
    if (_httpServerRunning) {
      await _httpServerService.stop();
      _runOnUi(() {
        _httpServerRunning = false;
        _httpServerUrl = null;
        _httpServerError = false;
        _httpServerMessage = 'HTTP server stopped.';
        _recoveryStatus = 'HTTP server stopped';
      });
      return;
    }
    _runOnUi(() {
      _httpServerError = false;
      _httpServerMessage = 'Starting the HTTP server in $_tftpDir...';
    });
    final directory = _tftpDir;
    final port = await _httpServerService.start(directory);
    final url = port == null ? null : 'http://192.168.1.2:$port';
    final error = _httpServerService.lastError;
    _runOnUi(() {
      _httpServerRunning = url != null;
      _httpServerUrl = url;
      _httpServerError = url == null;
      _httpServerMessage = url != null
          ? 'HTTP server is running at $url, serving $directory.'
          : 'Could not start the HTTP server: '
              '${error ?? 'unknown error'}. Make sure the folder exists and '
              'no other program is using the port.';
      _recoveryStatus =
          url != null ? 'HTTP server running at $url' : 'Failed to start server';
    });
    if (url == null) {
      _showErrorToast(
        'Could not start the HTTP server'
        '${error == null ? '' : ': $error'}'
        '. Make sure the folder exists and no other program is using the port.',
      );
    }
  }

  // -------------------------------------------------------------- state rules

  /// Any change that affects what we proved about the router invalidates the
  /// safety checks, so a green light can never describe a different setup.
  void _invalidateChecks() {
    if (!_preflightOk && _checks.isEmpty) return;
    _runOnUi(() {
      _preflightOk = false;
      _checks = [];
    });
  }

  void _runOnUi(void Function() mutate) {
    if (!mounted) return;
    setState(mutate);
  }

  void _showErrorToast(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.error_outline, color: Colors.white),
              const SizedBox(width: 12),
              Expanded(child: Text(message)),
            ],
          ),
          backgroundColor: Theme.of(context).colorScheme.error,
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.all(16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          showCloseIcon: true,
          closeIconColor: Colors.white,
          duration: const Duration(seconds: 8),
        ),
      );
  }

  static String _shortHash(String value) =>
      value.length <= 16 ? value : '${value.substring(0, 16)}...';

  Future<bool> _approveHostKey(HostKeyOffer offer) async {
    if (!mounted) return false;
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: Text('Unrecognised host key for ${offer.host}'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'This is the first SSH server this computer has seen at that '
                'address. Approving pins the key below, and any later change '
                'will be refused.',
              ),
              const SizedBox(height: 12),
              Text('Type: ${offer.keyType}'),
              const SizedBox(height: 4),
              SelectableText(
                offer.fingerprint,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
              const SizedBox(height: 12),
              const Text(
                'A changed key is expected straight after a re-flash. If you '
                'have not just flashed this router, someone on the network may '
                'be impersonating it, and approving would hand them the root '
                'password along with any image you send.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Reject'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Accept and pin'),
          ),
        ],
      ),
    );
    return accepted ?? false;
  }

  // ---------------------------------------------------------------- discovery

  Future<void> _probeGateways() async {
    _runOnUi(() {
      _discoveryBusy = true;
      _discoveryStatus = 'Looking for a device on this network...';
    });
    String error = '';
    try {
      final outcome = await _discovery.probeGateways();
      if (!mounted) return;
      _applyDiscovery(outcome.network, outcome.candidates, outcome.warning ?? '');
      return;
    } on Object catch (e) {
      error = '$e';
    }
    _runOnUi(() {
      _discoveryBusy = false;
    });
    _showErrorToast('Search failed: $error');
  }

  Future<void> _sweepSubnet() async {
    final consent = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Find more devices?'),
        content: const Text(
          'This will search all addresses on your network for devices. '
          'Only do this if your router is not found in the list above.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Search'),
          ),
        ],
      ),
    );
    if (consent != true || !mounted) return;

    _sweepCancelled = false;
    _runOnUi(() {
      _discoveryBusy = true;
      _discoveryStatus = 'Searching all devices on network...';
    });
    try {
      final outcome = await _discovery.scanSubnet(
        shouldContinue: () => !_sweepCancelled && mounted,
        onProgress: (done, all) => _runOnUi(
          () => _discoveryStatus =
              'Searching: $done of $all checked.',
        ),
      );
      if (!mounted) return;
      _applyDiscovery(outcome.network, outcome.candidates, outcome.warning ?? '');
      if (outcome.network?.isWireless ?? false) {
        _showErrorToast(
          'Connect the router with an Ethernet cable to search the LAN — '
          'sweeping over Wi-Fi is not supported.',
        );
      }
    } on Object catch (e) {
      _runOnUi(() {
        _discoveryBusy = false;
      });
      _showErrorToast('Sweep failed: $e');
    }
  }

  void _applyDiscovery(
    LocalNetwork? network,
    List<RouterCandidate> candidates,
    String warning,
  ) {
    _runOnUi(() {
      _network = network;
      _discoveryBusy = false;
      _candidates = candidates;
      if (candidates.length == 1) _selectedIp = candidates.single.ip;
      if (candidates.isEmpty) {
        _discoveryStatus = warning.isEmpty
            ? 'No device answered. Enter the address manually.'
            : warning;
      } else {
        _discoveryStatus =
            '${candidates.length} device(s) answered on ${network?.localIp ?? 'a '
                'local address'} (netmask /${network?.prefixLength ?? 24}, '
                '${network?.source ?? 'unknown'}). Identify one below before '
                'flashing.';
      }
    });
    _invalidateChecks();
    if (network == null) {
      _showErrorToast(
        'Could not determine this computer\'s LAN address. Connect the router '
        'with an Ethernet cable and try again.',
      );
    }
  }

  void _useManualIp() {
    final value = _manualIpController.text.trim();
    // A zero octet is normal in a host address (10.0.0.1), so only the
    // this-host and limited-broadcast forms are refused.
    final valid = RouterDiscoveryService.isIPv4(value) &&
        value != '0.0.0.0' &&
        value != '255.255.255.255';
    if (!valid) {
      const message =
          'Enter a full IPv4 address such as 192.168.1.1.';
      _runOnUi(() => _discoveryStatus = message);
      _showErrorToast(message);
      return;
    }
    _runOnUi(() {
      if (!_candidates.any((c) => c.ip == value)) {
        _candidates = [..._candidates,
            RouterCandidate(ip: value, hint: 'manual', banner: 'entered by you')];
      }
      _selectedIp = value;
      _router = null;
      _discoveryStatus = 'Using $value. Identify it to confirm it is the '
          'router you mean to flash.';
    });
    _invalidateChecks();
    _revalidateFirmware();
  }

  // ---------------------------------------------------------------- identity

  Future<void> _identifyRouter() async {
    final ip = _selectedIp;
    if (ip == null) {
      _runOnUi(() => _discoveryStatus = 'Choose or type an address first.');
      _showErrorToast('Choose or type a router address first.');
      return;
    }
    _runOnUi(() {
      _discoveryBusy = true;
      _discoveryStatus = 'Reading the device identity over SSH at $ip...';
      _router = null;
    });
    try {
      await _ssh.connect(ip, _usernameController.text, _passwordController.text);
      final identity = await _ssh.identify(ip);
      await _ssh.disconnect();
      if (!mounted) return;
      _runOnUi(() {
        _discoveryBusy = false;
        _router = identity;
        _versionBefore = identity.firmwareVersion;
        _discoveryStatus = 'Confirmed: ${identity.boardName} at '
            '${identity.ip} running ${identity.firmwareVersion}.';
      });
      _invalidateChecks();
      await _revalidateFirmware();
    } on SSHOperationException catch (error) {
      await _ssh.disconnect();
      _runOnUi(() {
        _discoveryBusy = false;
        _discoveryStatus = 'Cannot confirm this device: ${error.message}';
      });
      _showErrorToast(
        'Could not identify the router at $ip.\n${error.message}',
      );
    } on Object catch (error) {
      await _ssh.disconnect();
      _runOnUi(() {
        // The card must not stay busy if something unexpected escapes.
        _discoveryBusy = false;
        _discoveryStatus = 'Cannot confirm this device: $error';
      });
      _showErrorToast('Could not identify the router at $ip: $error');
    }
  }

  // ---------------------------------------------------------------- firmware

  /// Recovery path for a pin that is wrong or went stale: without it a bad
  /// entry in the trust-on-first-use store blocks the router for good.
  Future<void> _forgetHostKey() async {
    final ip = _selectedIp;
    if (ip == null) return;
    final wasPinned = await _hostKeys.pinnedFingerprint(ip) != null;
    await _hostKeys.unpin(ip);
    await _ssh.disconnect();
    _runOnUi(
      () => _discoveryStatus = wasPinned
          ? 'Forgot the pinned host key for $ip. Identify the router again to '
              'approve whichever key it presents now.'
          : 'No host key was pinned for $ip.',
    );
    _invalidateChecks();
  }

  Future<void> _pickFirmware() async {
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['bin', 'img'],
        withData: false,
      );
    } on Object catch (error) {
      _showErrorToast('Could not open the file picker: $error');
      return;
    }
    final path = result?.files.single.path;
    if (path == null) return;
    _runOnUi(() {
      _firmwarePath = path;
      _firmware = null;
      _ackUnverified = false;
    });
    _invalidateChecks();
    await _revalidateFirmware();
  }

  Future<void> _revalidateFirmware() async {
    final path = _firmwarePath;
    if (path == null) return;
    _runOnUi(() => _firmwareBusy = true);
    try {
      final info = await _firmwareService.validateFirmware(
        path,
        router: _router,
      );
      _runOnUi(() {
        _firmwareBusy = false;
        _firmware = info;
      });
      _invalidateChecks();
    } on Object catch (error) {
      _runOnUi(() {
        _firmwareBusy = false;
        _firmware = null;
      });
      if (mounted) {
        _showErrorToast('Could not inspect the image: $error');
      }
    }
  }

  // ------------------------------------------------------------------ checks

  Future<void> _runPreflight() async {
    final router = _router;
    final firmware = _firmware;
    final path = _firmwarePath;
    if (router == null || firmware == null || path == null) {
      _runOnUi(() {
        _preflightOk = false;
        _checks = [
          const CheckRow(
            'Ready to check',
            CheckOutcome.failed,
            'Identify the router and choose an image first.',
          ),
        ];
      });
      _showErrorToast('Identify the router and choose an image first.');
      return;
    }

    _runOnUi(() {
      _preflightOk = false;
      _checks = [
        const CheckRow('Running checks', CheckOutcome.warning, 'Contacting the router...'),
      ];
    });

    final rows = <CheckRow>[];
    try {
      await _ssh.connect(
        router.ip,
        _usernameController.text,
        _passwordController.text,
      );
      rows.add(CheckRow(
        'SSH login',
        CheckOutcome.passed,
        'Authenticated as "${_usernameController.text}" at ${router.ip}.',
      ));

      final live = await _ssh.identify(router.ip);
      final sameBoard = live.boardName == router.boardName;
      rows.add(CheckRow(
        'Device identity',
        sameBoard ? CheckOutcome.passed : CheckOutcome.failed,
        sameBoard
            ? '${live.boardName} running ${live.firmwareVersion} '
                '(${live.model})'
            : 'The router now reports "${live.boardName}", not '
                '"${router.boardName}". Something has changed; nothing was '
                'flashed.',
      ));
      if (!sameBoard) {
        _finishPreflight(rows, ok: false);
        _showErrorToast(
          'The router at ${router.ip} now reports "${live.boardName}", not '
          '"${router.boardName}". Nothing was flashed.',
        );
        return;
      }
      _versionBefore = live.firmwareVersion;

      final inProgress = await _ssh.isUpgradeInProgress();
      rows.add(CheckRow(
        'No upgrade already running',
        inProgress ? CheckOutcome.failed : CheckOutcome.passed,
        inProgress
            ? 'sysupgrade is already active on the router.'
            : 'The router is idle.',
      ));

      final imageSize = await File(path).length();
      final neededKb = (imageSize / 1024).ceil() + 10240;
      final freeKb = await _ssh.freeSpaceKb('/tmp');
      final roomy = freeKb >= neededKb;
      rows.add(CheckRow(
        'Room in /tmp',
        roomy ? CheckOutcome.passed : CheckOutcome.failed,
        '${freeKb}kB free, about ${neededKb}kB needed. /tmp is RAM: filling it '
            'crashes the router mid-flash.',
      ));

      rows.add(CheckRow(
        'Image names this device',
        firmware.isConfirmedForDevice
            ? CheckOutcome.passed
            : (firmware.needsAcknowledgement && _ackUnverified
                ? CheckOutcome.warning
                : CheckOutcome.failed),
        firmware.detail,
      ));

      final hash = await _firmwareService.computeSha256(path);
      rows.add(CheckRow(
        'Local SHA-256 computed',
        hash.isEmpty ? CheckOutcome.failed : CheckOutcome.passed,
        hash.isEmpty ? 'Could not hash the file.' : hash,
      ));

      final network = _network;
      rows.add(
        network == null
            ? const CheckRow(
                'Wired connection',
                CheckOutcome.warning,
                'Could not confirm a wired LAN interface. Connect the router '
                'with an Ethernet cable before flashing.',
              )
            : CheckRow(
                'Wired connection',
                network.isWireless
                    ? CheckOutcome.warning
                    : CheckOutcome.passed,
                network.isWireless
                    ? 'This computer is on Wi-Fi. Connect the router with an '
                        'Ethernet cable before flashing.'
                    : 'Using ${network.source} at ${network.localIp}.',
              ),
      );

      if (!mounted) return;
      _finishPreflight(
        rows,
        ok: !rows.any((row) => row.outcome == CheckOutcome.failed),
      );
    } on SSHOperationException catch (error) {
      rows.add(CheckRow('Check aborted', CheckOutcome.failed, error.message));
      _finishPreflight(rows, ok: false);
      _showErrorToast('Safety checks could not finish. ${error.message}');
    } on Object catch (error) {
      rows.add(CheckRow('Check aborted', CheckOutcome.failed, '$error'));
      _finishPreflight(rows, ok: false);
      _showErrorToast('Safety checks could not finish: $error');
    } finally {
      await _ssh.disconnect();
    }
  }

  void _finishPreflight(List<CheckRow> rows, {required bool ok}) {
    _runOnUi(() {
      _checks = rows;
      _preflightOk = ok;
    });
  }

  // ------------------------------------------------------------------- flash

  bool get _firmwareAcceptable {
    final firmware = _firmware;
    if (firmware == null) return false;
    return firmware.isConfirmedForDevice ||
        (firmware.needsAcknowledgement && _ackUnverified);
  }

  bool get _canFlash =>
      !_flashing &&
      _router != null &&
      _preflightOk &&
      _firmwareAcceptable;

  void _setStep(FlashStep step, String message, {double? progress}) {
    if (_flowAbandoned) return;
    _runOnUi(() {
      _step = step;
      _status = message;
      if (progress != null) _progress = progress;
    });
  }

  Future<void> _flash() async {
    final router = _router;
    final firmware = _firmware;
    final path = _firmwarePath;
    if (router == null || firmware == null || path == null) return;

    _runOnUi(() {
      _flashing = true;
      _installStarted = false;
      _cancelRequested = false;
      _flowAbandoned = false;
      _flashError = null;
      _verifiedAfter = null;
      _backupFile = null;
      _flashIssued = false;
      _confirmationNote = null;
      _skipConfirmation = false;
      _confirming = false;
      _confirmError = null;
      _confirmIpController.clear();
      _bootIdBefore = null;
      _progress = 0;
      _step = FlashStep.connect;
      _status = 'Connecting to ${router.ip}...';
    });

    var lastShownPercent = -1;
    try {
      await _ssh.connect(
        router.ip,
        _usernameController.text,
        _passwordController.text,
      );
      final live = await _ssh.identify(router.ip);
      if (live.boardName != router.boardName) {
        throw SSHOperationException(
          'The router now reports board name "${live.boardName}" instead of '
          '"${router.boardName}". Nothing was flashed.',
        );
      }
      _versionBefore ??= live.firmwareVersion;
      _bootIdBefore = await _ssh.bootId();

      _setStep(FlashStep.upload, 'Uploading firmware — do not interrupt.');
      await _ssh.uploadFirmware(path, SSHService.remoteFirmwarePath, (value) {
        if (_cancelRequested || _flowAbandoned) return;
        final percent = (value.clamp(0.0, 1.0) * 100).toInt();
        if (percent == lastShownPercent) return;
        lastShownPercent = percent;
        _runOnUi(() => _progress = value.clamp(0.0, 1.0));
      });
      if (_cancelRequested) {
        throw const SSHOperationException(
          'Upload cancelled. The partial image was deleted and nothing was '
          'flashed.',
        );
      }

      _setStep(FlashStep.checksum, 'Comparing the copy on the router with this file...');
      final remoteSha = await _ssh.remoteSha256(SSHService.remoteFirmwarePath);
      if (remoteSha != firmware.sha256) {
        throw SSHOperationException(
          'Checksum mismatch. Local ${_shortHash(firmware.sha256)} / router '
          '${_shortHash(remoteSha)}. The upload is corrupt, so nothing was '
          'flashed.',
        );
      }

      if (_backupConfig) {
        _setStep(FlashStep.backup, 'Backing up the current configuration...');
        await _saveConfigBackup();
      }

      _setStep(FlashStep.compatTest, 'Asking the router to test the image...');
      await _ssh.verifyFirmware(SSHService.remoteFirmwarePath);

      _setStep(
        FlashStep.install,
        _keepSettings
            ? 'Flashing, keeping /etc — DO NOT POWER OFF.'
            : 'Flashing and ERASING the configuration — DO NOT POWER OFF.',
      );
      _installStarted = true;
      await _ssh.flashFirmware(
        SSHService.remoteFirmwarePath,
        keepSettings: _keepSettings,
      );
      // The image is being written from here on: a failed confirmation below
      // is not a failed flash.
      _runOnUi(() => _flashIssued = true);

      _setStep(FlashStep.rebootWait, 'Waiting for the router to reboot...');
      await _ssh.disconnect();
      final after = await _ssh.waitForBoot(
        hosts: RouterDiscoveryService.rebootHosts(router.ip),
        username: _usernameController.text,
        passwords: [
          _passwordController.text,
          // Erasing the configuration also erases the root password.
          if (!_keepSettings && _passwordController.text.isNotEmpty) '',
        ],
        expectedBoard: router.boardName,
        previousBootId: _bootIdBefore,
        shouldStop: () => _skipConfirmation,
        timeout: const Duration(minutes: 3),
        onStatus: (message) => _setStep(FlashStep.rebootWait, message),
      );

      _runOnUi(() {
        if (_flowAbandoned) return;
        _verifiedAfter = after;
        _router = after;
        _selectedIp = after.ip;
        _confirmationNote = null;
        _step = FlashStep.idle;
        _status = 'Verified.';
      });
    } on SSHOperationException catch (error) {
      _flashFailureOrNote(error.message);
    } on Object catch (error) {
      _flashFailureOrNote('$error');
    } finally {
      await _ssh.disconnect();
      if (!_flowAbandoned) _runOnUi(() => _flashing = false);
    }
  }

  /// Failures before `sysupgrade` starts are errors. Once the image is being
  /// written, the router simply could not be confirmed in time, so the result
  /// page reports success with a note instead.
  void _flashFailureOrNote(String message) {
    if (_flowAbandoned) return;
    if (_flashIssued) {
      _runOnUi(() {
        _flashError = null;
        _confirmationNote = message;
        _step = FlashStep.idle;
        _status = '';
      });
      return;
    }
    _runOnUi(() => _flashError = message);
    _showErrorToast('Flashing failed. $message');
  }

  /// Rechecks a router at an address the user typed in. Only a board-name
  /// match is accepted, so this never confirms some other device.
  Future<void> _confirmFirmware() async {
    final router = _router;
    if (router == null) return;
    final ip = _confirmIpController.text.trim();
    if (!RouterDiscoveryService.isIPv4(ip)) {
      const message = 'Enter a full IPv4 address, like 192.168.1.1.';
      _runOnUi(() => _confirmError = message);
      _showErrorToast(message);
      return;
    }
    _runOnUi(() {
      _confirming = true;
      _confirmError = null;
    });
    try {
      final passwords = <String>[
        _passwordController.text,
        if (!_keepSettings && _passwordController.text.isNotEmpty) '',
      ];
      RouterInfo? info;
      Object? lastError;
      for (final password in passwords) {
        try {
          await _ssh.connect(ip, _usernameController.text, password);
          info = await _ssh.identify(ip);
          break;
        } catch (error) {
          lastError = error;
          await _ssh.disconnect();
        }
      }
      if (info == null) {
        throw SSHOperationException(
          'Could not sign in to $ip. Is the router there, and is SSH open? '
          'Last error: $lastError',
        );
      }
      if (info.boardName != router.boardName) {
        throw SSHOperationException(
          '"$ip" reports board "${info.boardName}", not "${router.boardName}". '
          'This is not the router that was flashed.',
        );
      }
      final previousBootId = _bootIdBefore;
      if (previousBootId != null) {
        final currentBootId = await _ssh.bootId();
        if (currentBootId != null && currentBootId == previousBootId) {
          throw const SSHOperationException(
            'The router is still running the boot it had before the flash, so '
            'the new firmware has not started. Do not treat this as confirmed.',
          );
        }
      }
      final confirmed = info;
      _runOnUi(() {
        _verifiedAfter = confirmed;
        _router = confirmed;
        _selectedIp = ip;
        _flashError = null;
        _confirmationNote = null;
      });
    } on SSHOperationException catch (error) {
      _runOnUi(() => _confirmError = error.message);
      _showErrorToast('Could not confirm the firmware. ${error.message}');
    } on Object catch (error) {
      _runOnUi(() => _confirmError = '$error');
      _showErrorToast('Could not confirm the firmware: $error');
    } finally {
      await _ssh.disconnect();
      _runOnUi(() => _confirming = false);
    }
  }

  Future<void> _saveConfigBackup() async {
    try {
      final bytes = await _ssh.createConfigBackup();
      if (bytes == null) {
        const message = 'The router did not produce a configuration backup.';
        _runOnUi(() => _backupFile = message);
        _showErrorToast(message);
        return;
      }
      final suggested =
          'openwrt-config-${DateTime.now().toIso8601String().substring(0, 19)}.tar.gz';
      final target = await FilePicker.platform.saveFile(
        dialogTitle: 'Where should the configuration backup be saved?',
        fileName: suggested,
        type: FileType.custom,
        allowedExtensions: const ['gz', 'tar'],
      );
      if (target == null) {
        _runOnUi(
          () => _backupFile = 'Backup was produced on the router but you did '
              'not choose somewhere to save it.',
        );
        return;
      }
      await File(target).writeAsBytes(bytes, flush: true);
      _runOnUi(() => _backupFile = target);
    } on SSHOperationException catch (error) {
      _runOnUi(() => _backupFile = 'Backup failed: ${error.message}');
      _showErrorToast('Could not save the configuration backup. '
          '${error.message}');
    } on Object catch (error) {
      _runOnUi(() => _backupFile = 'Backup failed: $error');
      _showErrorToast('Could not save the configuration backup: $error');
      rethrow;
    }
  }

  Future<void> _cancelUpload() async {
    _runOnUi(() => _cancelRequested = true);
    await _ssh.cancelUpload();
  }

  Future<void> _leaveProgressScreen() async {
    _runOnUi(() {
      _flowAbandoned = true;
      _flashing = false;
      _step = FlashStep.idle;
      _status = '';
      _progress = 0;
      _flashError = null;
    });
    // Only offered before anything is written to the router, so dropping the
    // session here stops the flow rather than interrupting a flash.
    await _ssh.cancelUpload();
    await _ssh.disconnect();
    _invalidateChecks();
  }

  // --------------------------------------------------------------------- view

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_flashing) return _buildFlashScreen(theme);
    if (_verifiedAfter != null || _flashError != null || _flashIssued) {
      return _buildResultScreen(theme);
    }

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('OpenWrt Flasher'),
          backgroundColor: theme.colorScheme.primaryContainer,
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Flash'),
              Tab(text: 'Recovery'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _buildFlashTab(theme),
            _buildRecoveryTab(theme),
          ],
        ),
      ),
    );
  }

  Widget _buildFlashTab(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        _header(theme, '1. Find the router'),
        _discoveryCard(theme),
        const SizedBox(height: 24),
        _header(theme, '2. Credentials'),
        _credentialsCard(theme),
        const SizedBox(height: 24),
        _header(theme, '3. Firmware image'),
        _firmwareCard(theme),
        const SizedBox(height: 16),
        _header(theme, '4. Options'),
        _optionsCard(theme),
        const SizedBox(height: 16),
        _header(theme, '5. Safety checks'),
        _checksCard(theme),
        const SizedBox(height: 24),
        _warningBanner(theme),
        const SizedBox(height: 16),
        Center(
          child: FilledButton.icon(
            key: HomeScreen.flashButtonKey,
            onPressed: _canFlash ? _flash : null,
            icon: const Icon(Icons.flash_on),
            label: const Text('Flash firmware'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 16),
              textStyle: const TextStyle(fontSize: 16),
            ),
          ),
        ),
        if (!_canFlash && !_flashing) ...[
          const SizedBox(height: 8),
          Center(
            child: Text(
              _blockedReason(),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ],
    );
  }

  // ------------------------------------------------------------ recovery view

  static const _firmwareSelectorLink = 'https://firmware-selector.openwrt.org/';
  static const _tableOfHardwareLink = 'https://openwrt.org/toh/start';

  HostOs get _os => widget.hostOs ?? HostOs.current;
  bool get _isWindows => _os == HostOs.windows;

  String get _serialExample => switch (_os) {
        HostOs.windows => 'COM4',
        HostOs.macos => '/dev/cu.usbserial-0001',
        HostOs.linux => '/dev/ttyUSB0',
      };

  String get _listSerialCommand => switch (_os) {
        HostOs.windows => 'mode',
        HostOs.macos => 'ls /dev/cu.*',
        HostOs.linux => 'ls /dev/ttyUSB* /dev/ttyACM*',
      };

  String get _staticIpCommand => switch (_os) {
        HostOs.windows => 'netsh interface ip set address name="Ethernet" '
            'static 192.168.1.2 255.255.255.0',
        HostOs.macos =>
          'sudo ifconfig en5 192.168.1.2 netmask 255.255.255.0',
        HostOs.linux => 'sudo ip addr add 192.168.1.2/24 dev eth0',
      };

  String get _showIpCommand => switch (_os) {
        HostOs.windows => 'ipconfig',
        HostOs.macos => 'ifconfig en5',
        HostOs.linux => 'ip addr show eth0',
      };

  String _basename(String path) => path.split(RegExp(r'[\\/]')).last;

  String get _firmwareName => _sysupgradeImagePath == null
      ? 'openwrt-sysupgrade.bin'
      : _basename(_sysupgradeImagePath!);

  String get _serverBase => _httpServerUrl ?? 'http://192.168.1.2:8080';

  String get _wgetCommands => 'cd /tmp\n'
      'wget $_serverBase/$_firmwareName\n'
      'ls -lh /tmp/$_firmwareName';

  String get _sysupgradeCommand => 'sysupgrade -n /tmp/$_firmwareName';

  Widget _buildRecoveryTab(ThemeData theme) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 1100;
        final guide = ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              'OpenWrt Board Recovery & Installation (${_os.label})',
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              'Boot an OpenWrt board into a temporary OpenWrt environment and permanently '
              'install the OpenWrt firmware using a ${_os.machine}.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
            _header(theme, 'Prerequisites'),
            _prerequisitesCard(theme),
            const SizedBox(height: 24),
            _header(theme, 'Hardware Setup'),
            _hardwareCard(theme),
            const SizedBox(height: 24),
            _header(theme, 'Boot OpenWrt (Temporary)'),
            _bootOpenWrtCard(theme),
            if (!wide) ...[
              const SizedBox(height: 16),
              _consolePanel(theme, height: 480),
            ],
            const SizedBox(height: 24),
            _header(theme, 'Install OpenWrt Firmware'),
            _installCard(theme),
            const SizedBox(height: 24),
            _header(theme, 'After Installation'),
            _afterInstallCard(theme),
            const SizedBox(height: 24),
            _header(theme, 'Troubleshooting'),
            _troubleshootingCard(theme),
            const SizedBox(height: 32),
          ],
        );
        if (!wide) return guide;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: guide),
            SizedBox(
              width: (constraints.maxWidth * 0.45).clamp(480.0, 1000.0),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 24, 24, 24),
                child: _consolePanel(theme),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _prerequisitesCard(ThemeData theme) {
    final detectedPorts = _guideText(
      theme,
      _availablePorts.isEmpty
          ? 'No serial ports detected yet. Plug in the adapter and press refresh in '
              '"Open the Serial Console" below.'
          : 'Detected: ${_availablePorts.join(', ')}',
    );
    final steps = <Widget>[
      ...switch (_os) {
        HostOs.windows => [
            _guideStep(theme, 1, 'Install Required Software', [
              _guideText(theme,
                  'Install the USB to TTL driver for your adapter (CH340, CP2102, '
                  'FT232, etc.) if Windows does not recognize it automatically.'),
              const SizedBox(height: 6),
              _guideText(theme,
                  'Install a TFTP server such as Tftpd64, set its base directory to '
                  'the firmware folder in step 4, and select 192.168.1.2 (your '
                  'Ethernet adapter, after step 6) as the server interface. The '
                  'bootloader downloads the initramfs image from it.'),
              _guideCode(theme, 'https://pjo2.github.io/tftpd64/'),
              _guideText(theme,
                  'Nothing else is needed: this app includes the serial console '
                  '(replaces PuTTY) and the temporary HTTP server (replaces Python).'),
            ]),
            _guideStep(theme, 2, 'Find the COM Port', [
              _guideText(theme,
                  'Plug in the USB to TTL adapter, open Device Manager and expand '
                  'Ports (COM & LPT). Example: USB-SERIAL CH340 (COM4).'),
              detectedPorts,
            ]),
          ],
        HostOs.macos => [
            _guideStep(theme, 1, 'Enable the TFTP Server', [
              _guideText(theme,
                  'macOS has a built-in TFTP server that serves /private/tftpboot. '
                  'Start it and let this app copy files into the folder:'),
              _guideCode(theme,
                  'sudo launchctl load -F /System/Library/LaunchDaemons/tftp.plist\n'
                  'sudo chmod 777 /private/tftpboot'),
              _guideText(theme, 'Optional: a TFTP client to test the server:'),
              _guideCode(theme, 'brew install tftp-hpa'),
            ]),
            _guideStep(theme, 2, 'Find the USB to TTL Port', [
              _guideCode(theme, _listSerialCommand),
              _guideText(theme, 'Example: $_serialExample'),
              detectedPorts,
            ]),
          ],
        HostOs.linux => [
            _guideStep(theme, 1, 'Install the TFTP Server', [
              _guideText(theme,
                  'Debian/Ubuntu (Fedora: tftp-server; Arch: tftp-hpa). It serves '
                  '/srv/tftp; let this app copy files into the folder:'),
              _guideCode(theme,
                  'sudo apt install tftpd-hpa\n'
                  'sudo chown \$USER /srv/tftp'),
            ]),
            _guideStep(theme, 2, 'Find the USB to TTL Port', [
              _guideCode(theme, _listSerialCommand),
              _guideText(theme, 'Example: $_serialExample'),
              _guideText(theme,
                  'Opening the port needs the dialout group (uucp on Arch). Log out '
                  'and back in after running:'),
              _guideCode(theme, 'sudo usermod -aG dialout \$USER'),
              detectedPorts,
            ]),
          ],
      },
      _guideStep(theme, 3, 'Download Required Firmware', [
        _guideLabel(theme, 'Default Firmware (initramfs)'),
        _guideText(theme,
            'If you have not downloaded firmware yet, use the default. It is '
            'saved to the firmware folder and selected as the initramfs image, '
            'ready for the TFTP boot below.'),
        const SizedBox(height: 4),
        for (final image in FirmwareDownloadService.defaultFirmwareImages) ...[
          _defaultFirmwareRow(theme, image),
          const SizedBox(height: 6),
        ],
        if (_initramfsDownloadStatus != null) ...[
          _guideText(theme, _initramfsDownloadStatus!),
          const SizedBox(height: 4),
        ],
        _guideText(theme,
            'The default firmware boots OpenWrt from RAM and is not permanent.'),
        const SizedBox(height: 6),
        _guideText(theme,
            'Or download the initramfs image (…-initramfs-kernel.bin) for your '
            'exact board and hardware revision from:'),
        _guideCode(theme, _firmwareSelectorLink),
        const SizedBox(height: 4),
        _filePickRow(
          theme,
          _openwrtInitramfsPath,
          'No default firmware (initramfs) selected',
          'Select Default',
          _pickOpenWrtInitramfs,
        ),
        const SizedBox(height: 14),
        _guideLabel(theme, 'Upgrade Firmware (sysupgrade)'),
        _guideText(theme,
            'The upgrade image is installed permanently and must match the same '
            'board. Download the example, or the matching sysupgrade image '
            '(…-squashfs-sysupgrade.bin) from:'),
        const SizedBox(height: 4),
        for (final image in FirmwareDownloadService.upgradeFirmwareImages) ...[
          _defaultFirmwareRow(theme, image),
          const SizedBox(height: 6),
        ],
        if (_upgradeDownloadStatus != null) ...[
          _guideText(theme, _upgradeDownloadStatus!),
          const SizedBox(height: 4),
        ],
        _guideCode(theme, _tableOfHardwareLink),
        const SizedBox(height: 4),
        _filePickRow(
          theme,
          _sysupgradeImagePath,
          'No upgrade firmware (sysupgrade) selected',
          'Select Upgrade',
          _pickSysupgradeImage,
        ),
      ]),
      _guideStep(theme, 4, _isWindows ? 'Create a Firmware Folder' : 'Copy Firmware Files', [
        _guideText(theme,
            'Copy all downloaded firmware files to the folder your TFTP server '
            'serves:'),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _tftpDirController,
                decoration: const InputDecoration(
                  labelText: 'Firmware folder',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (value) => _runOnUi(() => _tftpDir = value),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonalIcon(
              onPressed: _openwrtInitramfsPath == null && _sysupgradeImagePath == null
                  ? null
                  : _copyToTftp,
              icon: const Icon(Icons.copy),
              label: const Text('Copy Files'),
            ),
          ],
        ),
      ]),
      _guideStep(theme, 5, 'Connect the Router', [
        _guideText(theme,
            'Connect your ${_os.machine} directly to one of the '
            'LAN ports of the OpenWrt board.'),
      ]),
      _guideStep(theme, 6, 'Configure a Static IP Address', [
        _guideText(theme,
            'Use 192.168.1.2: it is the TFTP server address U-Boot uses by default.'),
        const SizedBox(height: 6),
        if (_isWindows) ...[
          _guideText(theme,
              'Open Control Panel → Network and Sharing Center → Change adapter settings, '
              'then open your Ethernet adapter properties (IPv4) and set:'),
          const SizedBox(height: 4),
          _kv(theme, 'IP Address', '192.168.1.2'),
          _kv(theme, 'Subnet Mask', '255.255.255.0'),
          _kv(theme, 'Default Gateway', 'Leave blank'),
          const SizedBox(height: 6),
          _guideText(theme,
              'Or, from a Command Prompt run as administrator (replace "Ethernet" '
              'with the adapter name shown in Network Connections):'),
          _guideCode(theme, _staticIpCommand),
        ] else if (_os == HostOs.macos) ...[
          _guideText(theme,
              'Replace en5 with your Ethernet interface. List the interfaces with:'),
          _guideCode(theme, 'networksetup -listallhardwareports'),
          _guideCode(theme, _staticIpCommand),
          _guideText(theme,
              'Or: System Settings → Network → your Ethernet adapter → Details → '
              'TCP/IP → Configure IPv4: Manually.'),
        ] else ...[
          _guideText(theme,
              'Replace eth0 with your Ethernet interface (often enp…). List the '
              'interfaces with:'),
          _guideCode(theme, 'ip link'),
          _guideCode(theme, _staticIpCommand),
          _guideText(theme,
              'If NetworkManager removes the address again, set IPv4 to Manual on '
              'the wired connection in Settings → Network instead.'),
        ],
      ]),
    ];
    return _stepsCard(steps);
  }

  Widget _hardwareCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Required Hardware', style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            _guideBullet(theme, 'USB to TTL Adapter (CH340G, CP2102, FT232, etc.)'),
            _guideBullet(theme, 'UART Jumper Wires'),
            const SizedBox(height: 16),
            Text('Wiring', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _hardwareImage(
                    theme,
                    'assets/images/usb_ttl_adapter.png',
                    Icons.usb,
                    'USB to TTL',
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _hardwareImage(
                    theme,
                    'assets/images/uart_board.png',
                    Icons.memory,
                    'Board UART',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Table(
              border: TableBorder.all(color: theme.colorScheme.outlineVariant),
              children: [
                _wiringRow(theme, 'USB to TTL', 'Board UART', header: true),
                _wiringRow(theme, 'TX', 'TX'),
                _wiringRow(theme, 'RX', 'RX'),
                _wiringRow(theme, 'GND', 'GND'),
              ],
            ),
            const SizedBox(height: 12),
            _callout(
              theme,
              Icons.warning_amber_rounded,
              'Important',
              'Do not connect the 3.3V/VCC pin.\n'
                  'Power the router using its original power adapter.',
              error: true,
            ),
          ],
        ),
      ),
    );
  }

  Widget _bootOpenWrtCard(ThemeData theme) {
    final connectStep = <Widget>[
      Row(
        children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              isExpanded: true,
              initialValue: _selectedSerialPort.isEmpty ? null : _selectedSerialPort,
              decoration: InputDecoration(
                labelText: _isWindows ? 'COM Port' : 'Serial Port',
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              items: _availablePorts
                  .map((port) => DropdownMenuItem(
                        value: port,
                        child: Text(port, overflow: TextOverflow.ellipsis),
                      ))
                  .toList(),
              onChanged: _serialConnected
                  ? null
                  : (value) {
                      if (value != null) {
                        _runOnUi(() => _selectedSerialPort = value);
                      }
                    },
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            onPressed: _serialConnected ? null : _refreshSerialPorts,
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh ports',
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: _selectedSerialPort.isEmpty
                ? null
                : (_serialConnected ? _disconnectSerial : _connectSerial),
            icon: Icon(_serialConnected ? Icons.link_off : Icons.link),
            label: Text(_serialConnected ? 'Disconnect' : 'Connect'),
          ),
        ],
      ),
      const SizedBox(height: 6),
      _guideText(theme, 'Speed: 115200 baud. Status: $_recoveryStatus'),
      const SizedBox(height: 4),
      _guideText(theme, 'Then power on the router.'),
    ];

    var n = 0;
    final steps = <Widget>[
      _guideStep(theme, ++n, 'Open the Serial Console', [
        _guideText(theme,
            'Pick your ${_isWindows ? 'COM port (the one found in Device Manager)' : 'port'} '
            'and connect. This replaces:'),
        _guideCode(
          theme,
          switch (_os) {
            HostOs.windows => 'PuTTY → Serial → COM4 → Speed 115200',
            HostOs.macos => 'screen /dev/cu.usbserial-0001 115200',
            HostOs.linux => 'screen /dev/ttyUSB0 115200',
          },
          copyable: !_isWindows,
        ),
        ...connectStep,
      ]),
      _guideStep(theme, ++n, 'Enter the Bootloader Menu', [
        _guideText(theme, 'When the bootloader appears, you should see:'),
        _guideCode(theme,
            '1. Start default\n2. Upgrade firmware\n3. Upgrade bootloader\n'
            '4. Load image\n5. U-Boot console',
            copyable: false),
      ]),
      _guideStep(theme, ++n, 'Load OpenWrt', [
        _guideText(theme,
            'Select 4. Load image and choose the OpenWrt Initramfs firmware '
            '(${_openwrtInitramfsPath == null ? 'not selected yet' : _basename(_openwrtInitramfsPath!)}) '
            'located in ${_tftpDirController.text}.'),
        const SizedBox(height: 8),
        FilledButton.tonalIcon(
          onPressed: _serialConnected ? () => _sendSerial('4\n') : null,
          icon: const Icon(Icons.download),
          label: const Text('Send "4. Load image"'),
        ),
        const SizedBox(height: 8),
        _guideText(theme,
            'The bootloader then asks for the device IP, the TFTP server IP '
            '(192.168.1.2) and the file name. Press Enter at each prompt to keep '
            'the default values, using the console\'s Enter button or the Enter key. '
            'Only type the initramfs file name if the default does not match it.'),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _serialConnected ? () => _sendSerial('\n') : null,
          icon: const Icon(Icons.keyboard_return),
          label: const Text('Send Enter'),
        ),
        const SizedBox(height: 8),
        _guideText(theme, 'The router will boot into a temporary OpenWrt environment.'),
        const SizedBox(height: 8),
        _callout(
          theme,
          Icons.info_outline,
          'Note',
          'OpenWrt runs from RAM only. It is not permanently installed and will be '
              'lost after reboot.',
        ),
      ]),
    ];
    return _stepsCard(steps);
  }

  Widget _installCard(ThemeData theme) {
    final steps = <Widget>[
      _guideStep(theme, 1, 'Start a Temporary HTTP Server', [
        _guideText(theme,
            'Serves the firmware folder on port 8080. This replaces:'),
        _guideCode(
          theme,
          _isWindows
              ? 'cd ${_tftpDirController.text}\npython -m http.server 8080'
              : 'cd ${_tftpDirController.text}\npython3 -m http.server 8080',
          copyable: false,
        ),
        Row(
          children: [
            FilledButton.tonalIcon(
              onPressed: _startHttpServer,
              icon: Icon(_httpServerRunning ? Icons.stop : Icons.play_arrow),
              label: Text(_httpServerRunning ? 'Stop HTTP Server' : 'Start HTTP Server'),
            ),
          ],
        ),
        if (_httpServerMessage != null) ...[
          const SizedBox(height: 8),
          _serverStatusLine(
            theme,
            _httpServerMessage!,
            error: _httpServerError,
            active: _httpServerRunning,
          ),
        ],
        if (_isWindows)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: _guideText(theme,
                'The first time it starts, Windows may ask for firewall access. '
                'Allow this app for private networks, or the router cannot '
                'download the firmware from it.'),
          ),
      ]),
      _guideStep(theme, 2, 'Download the Firmware in OpenWrt', [
        _guideText(theme, 'On the OpenWrt console:'),
        _guideCode(theme, _wgetCommands),
        FilledButton.tonalIcon(
          onPressed: _serialConnected && _httpServerRunning
              ? () => _sendSerial('$_wgetCommands\n')
              : null,
          icon: const Icon(Icons.send),
          label: const Text('Send to Console'),
        ),
        if (!_httpServerRunning || !_serialConnected)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: _guideText(theme, 'Requires a serial connection and a running HTTP server.'),
          ),
      ]),
      _guideStep(theme, 3, 'Install the Firmware', [
        _guideCode(theme, _sysupgradeCommand),
        _guideText(theme, 'The router will:'),
        _guideBullet(theme, 'Erase the current firmware'),
        _guideBullet(theme, 'Install OpenWrt'),
        _guideBullet(theme, 'Reboot automatically'),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _serialConnected ? _confirmSysupgrade : null,
          style: FilledButton.styleFrom(
            backgroundColor: theme.colorScheme.error,
            foregroundColor: theme.colorScheme.onError,
          ),
          icon: const Icon(Icons.system_update_alt),
          label: const Text('Run sysupgrade'),
        ),
        const SizedBox(height: 8),
        _callout(
          theme,
          Icons.power_off_outlined,
          'Warning',
          'Do not disconnect power during the upgrade.',
          error: true,
        ),
      ]),
    ];
    return _stepsCard(steps);
  }

  Widget _afterInstallCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _guideText(theme, 'Once the router finishes rebooting:'),
            const SizedBox(height: 6),
            if (_isWindows) ...[
              _guideBullet(theme, 'Reconnect your PC to the router.'),
              _guideBullet(theme,
                  'Change your Ethernet adapter back to "Obtain an IP address automatically" '
                  '(or configure it as needed).'),
            ] else if (_os == HostOs.macos) ...[
              _guideBullet(theme, 'Connect to the router normally.'),
              _guideBullet(theme,
                  "Restore your Mac's network settings if necessary (Configure IPv4: "
                  'Using DHCP).'),
              _guideBullet(theme, 'Stop the TFTP server:'),
              _guideCode(theme,
                  'sudo launchctl unload -F /System/Library/LaunchDaemons/tftp.plist'),
            ] else ...[
              _guideBullet(theme, 'Connect to the router normally.'),
              _guideBullet(theme, 'Remove the static address (or set IPv4 back to Automatic):'),
              _guideCode(theme, 'sudo ip addr del 192.168.1.2/24 dev eth0'),
              _guideBullet(theme, 'Optionally stop the TFTP server:'),
              _guideCode(theme, 'sudo systemctl stop tftpd-hpa'),
            ],
            _guideBullet(theme, 'Verify the OpenWrt firmware is running.'),
          ],
        ),
      ),
    );
  }

  Widget _troubleshootingCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('No Serial Output', style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            _guideBullet(theme, 'Verify TX goes to TX and RX goes to RX.'),
            _guideBullet(theme, 'Ensure GND is connected.'),
            if (_isWindows) ...[
              _guideBullet(theme, 'Confirm the correct COM port in Device Manager.'),
              _guideBullet(theme, 'Make sure the console is using 115200 baud.'),
            ] else ...[
              _guideBullet(theme, 'Confirm the correct serial device:'),
              _guideCode(theme, _listSerialCommand),
            ],
            if (_os == HostOs.linux) ...[
              _guideBullet(theme,
                  '"Permission denied": add yourself to the dialout group (see '
                  'Prerequisites) and log in again.'),
              _guideBullet(theme,
                  'On Ubuntu, brltty can grab CH340 adapters. If the port vanishes '
                  'after plugging in, remove it:'),
              _guideCode(theme, 'sudo apt remove brltty'),
            ],
            const Divider(height: 24),
            Text('Cannot Download Firmware', style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            _guideText(theme, 'Verify your ${_os.machine} has the correct IP:'),
            _guideCode(theme, _showIpCommand),
            _guideText(theme, 'Expected: 192.168.1.2'),
            const SizedBox(height: 4),
            _guideText(theme,
                'Ensure the TFTP server is running, the HTTP server is running '
                '(Install OpenWrt Firmware → step 1) and the firmware files were '
                'copied to the firmware folder.'),
            const SizedBox(height: 4),
            ...switch (_os) {
              HostOs.windows => [
                  _guideText(theme,
                      'When Windows Defender Firewall asks, allow Tftpd64 and this app '
                      'on private networks.'),
                ],
              HostOs.macos => [
                  _guideText(theme,
                      'If the macOS firewall is on, allow incoming connections for this '
                      'app. Check the TFTP server is loaded:'),
                  _guideCode(theme, 'sudo launchctl list | grep tftp'),
                ],
              HostOs.linux => [
                  _guideText(theme,
                      'If a firewall is active, open the TFTP and HTTP ports, and check '
                      'the TFTP server is running:'),
                  _guideCode(theme,
                      'sudo ufw allow 69/udp\nsudo ufw allow 8080/tcp\n'
                      'systemctl status tftpd-hpa'),
                ],
            },
            const Divider(height: 24),
            Text('Firmware Disappears After Reboot', style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            _guideText(theme,
                'If the router boots into OpenWrt but returns to the old firmware after reboot, '
                'only the Load Image step was completed. To permanently install the firmware, '
                'run this from the temporary OpenWrt session:'),
            _guideCode(theme, _sysupgradeCommand),
          ],
        ),
      ),
    );
  }

  Widget _consolePanel(ThemeData theme, {double? height}) {
    final output = Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outline),
      ),
      child: SingleChildScrollView(
        controller: _consoleScrollController,
        child: SizedBox(
          width: double.infinity,
          child: SelectableText(
            _consoleBuffer.isEmpty
                ? 'No output yet. Connect the serial port and power on the router.'
                : _consoleBuffer.toString(),
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: Colors.greenAccent,
            ),
          ),
        ),
      ),
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: height == null ? MainAxisSize.max : MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  Icons.circle,
                  size: 10,
                  color: _serialConnected ? Colors.green : theme.colorScheme.outline,
                ),
                const SizedBox(width: 8),
                Text('Serial Console', style: theme.textTheme.titleMedium),
                const Spacer(),
                TextButton.icon(
                  onPressed: _clearConsole,
                  icon: const Icon(Icons.clear_all),
                  label: const Text('Clear'),
                ),
              ],
            ),
            Text(
              _serialConnected ? '$_selectedSerialPort · 115200 baud' : _recoveryStatus,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            if (height == null) Expanded(child: output) else SizedBox(height: height, child: output),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _consoleInputController,
                    enabled: _serialConnected,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                    decoration: const InputDecoration(
                      hintText: 'Send command to router...',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _submitConsoleInput(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: _serialConnected ? _submitConsoleInput : null,
                  icon: const Icon(Icons.send),
                  tooltip: 'Send',
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: _serialConnected ? () => _sendSerial('\n') : null,
                  child: const Text('Enter'),
                ),
                OutlinedButton(
                  onPressed: _serialConnected ? () => _sendSerial('1\n') : null,
                  child: const Text('1. Start default'),
                ),
                OutlinedButton(
                  onPressed: _serialConnected ? () => _sendSerial('4\n') : null,
                  child: const Text('4. Load image'),
                ),
                OutlinedButton(
                  onPressed: _serialConnected ? () => _sendSerial('\x03') : null,
                  child: const Text('Ctrl+C'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _submitConsoleInput() {
    final value = _consoleInputController.text;
    if (value.isEmpty || !_serialConnected) return;
    _sendSerial('$value\n');
    _consoleInputController.clear();
  }

  Future<void> _confirmSysupgrade() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded),
        title: const Text('Install OpenWrt permanently?'),
        content: Text(
          'This sends "$_sysupgradeCommand" to the router. It erases the current '
          'firmware, installs OpenWrt and reboots.\n\n'
          'Make sure the download in step 2 succeeded. Do not disconnect power '
          'during the upgrade.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Install'),
          ),
        ],
      ),
    );
    if (confirmed == true) _sendSerial('$_sysupgradeCommand\n');
  }

  Widget _stepsCard(List<Widget> steps) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < steps.length; i++) ...[
                if (i > 0) const Divider(height: 28),
                steps[i],
              ],
            ],
          ),
        ),
      );

  Widget _guideStep(ThemeData theme, int number, String title, List<Widget> body) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(
          radius: 13,
          backgroundColor: theme.colorScheme.primaryContainer,
          child: Text(
            '$number',
            style: theme.textTheme.labelMedium
                ?.copyWith(color: theme.colorScheme.onPrimaryContainer),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 3, bottom: 8),
                child: Text(title, style: theme.textTheme.titleSmall),
              ),
              ...body,
            ],
          ),
        ),
      ],
    );
  }

  Widget _guideText(ThemeData theme, String text) =>
      Text(text, style: theme.textTheme.bodyMedium);

  Widget _guideLabel(ThemeData theme, String text) => Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 2),
        child: Text(
          text,
          style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
      );

  Widget _guideBullet(ThemeData theme, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('•  ', style: theme.textTheme.bodyMedium),
            Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
          ],
        ),
      );

  Widget _guideCode(ThemeData theme, String code, {bool copyable = true}) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: SelectableText(
                code,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
              ),
            ),
          ),
          if (copyable)
            IconButton(
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              tooltip: 'Copy',
              icon: const Icon(Icons.content_copy),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: code));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Copied to clipboard'),
                    behavior: SnackBarBehavior.floating,
                    duration: Duration(seconds: 1),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _callout(
    ThemeData theme,
    IconData icon,
    String title,
    String body, {
    bool error = false,
  }) {
    final bg = error ? theme.colorScheme.errorContainer : theme.colorScheme.secondaryContainer;
    final fg = error ? theme.colorScheme.onErrorContainer : theme.colorScheme.onSecondaryContainer;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: fg, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: fg, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(body, style: theme.textTheme.bodyMedium?.copyWith(color: fg)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _defaultFirmwareRow(ThemeData theme, DefaultFirmwareImage image) {
    final selectedPath =
        image.isUpgrade ? _sysupgradeImagePath : _openwrtInitramfsPath;
    final selected =
        selectedPath != null && _basename(selectedPath) == image.fileName;
    final title = image.isUpgrade
        ? 'Example upgrade firmware (${image.label})'
        : 'Default firmware (${image.label})';
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            selected ? Icons.check_circle : Icons.download_for_offline_outlined,
            size: 20,
            color: selected ? Colors.green : theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                Text(image.details, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: _downloadingDefault || selected
                ? null
                : () => _downloadDefaultImage(image),
            child: Text(selected ? 'Selected' : 'Download'),
          ),
        ],
      ),
    );
  }

  Widget _serverStatusLine(
    ThemeData theme,
    String message, {
    required bool error,
    required bool active,
  }) {
    final color = error
        ? theme.colorScheme.error
        : (active ? Colors.green.shade700 : theme.colorScheme.onSurfaceVariant);
    final icon = error
        ? Icons.error_outline
        : (active ? Icons.check_circle_outline : Icons.info_outline);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            message,
            style: theme.textTheme.bodySmall?.copyWith(color: color),
          ),
        ),
      ],
    );
  }

  Widget _filePickRow(
    ThemeData theme,
    String? path,
    String placeholder,
    String buttonLabel,
    VoidCallback onPick,
  ) {
    return Row(
      children: [
        Icon(
          path == null ? Icons.insert_drive_file_outlined : Icons.check_circle,
          size: 18,
          color: path == null ? theme.colorScheme.outline : Colors.green,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            path == null ? placeholder : _basename(path),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton(onPressed: onPick, child: Text(buttonLabel)),
      ],
    );
  }

  Widget _hardwareImage(ThemeData theme, String asset, IconData fallback, String label) {
    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.asset(
            asset,
            height: 140,
            fit: BoxFit.contain,
            errorBuilder: (context, error, stackTrace) => Container(
              height: 140,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: Icon(fallback, size: 40, color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(label, style: theme.textTheme.bodySmall),
      ],
    );
  }

  TableRow _wiringRow(ThemeData theme, String left, String right, {bool header = false}) {
    final style = header
        ? theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)
        : theme.textTheme.bodyMedium?.copyWith(fontFamily: 'monospace');
    return TableRow(
      decoration: header
          ? BoxDecoration(color: theme.colorScheme.surfaceContainerHighest)
          : null,
      children: [
        Padding(padding: const EdgeInsets.all(8), child: Text(left, style: style)),
        Padding(padding: const EdgeInsets.all(8), child: Text(right, style: style)),
      ],
    );
  }

  String _blockedReason() {
    if (_router == null) return 'Identify the router over SSH first.';
    if (_firmware == null) return 'Choose a firmware image.';
    if (_firmware!.status == FirmwareStatus.mismatched) {
      return 'This image is for different hardware, so it will stay blocked.';
    }
    if (!_firmwareAcceptable) {
      return 'Confirm the unverified image, or pick one that names this device.';
    }
    if (!_preflightOk) return 'Run the safety checks and get them all green.';
    return 'Ready.';
  }

  Widget _header(ThemeData theme, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text, style: theme.textTheme.titleMedium),
      );

  Widget _discoveryCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.lan_outlined,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Connect the router to this computer with an Ethernet '
                    'cable. Discovery and flashing use the LAN, never Wi-Fi.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                if (_discoveryBusy)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                if (_discoveryBusy) const SizedBox(width: 12),
                Expanded(child: Text(_discoveryStatus)),
              ],
            ),
            if (_network != null) ...[
              const SizedBox(height: 8),
              _kv(
                theme,
                'This computer',
                '${_network!.localIp} /${_network!.prefixLength} '
                    'via ${_network!.source}',
              ),
            ],
            if (_network != null && _network!.isWireless) ...[
              const SizedBox(height: 8),
              _statusLine(
                theme,
                CheckOutcome.warning,
                'Wi-Fi connection',
                'This computer is on Wi-Fi. Plug the router into an Ethernet '
                'port before flashing.',
              ),
            ],
            if (_candidates.isNotEmpty) ...[
              const SizedBox(height: 12),
              ..._candidates.map((candidate) {
                final selected = candidate.ip == _selectedIp;
                return ListTile(
                  dense: true,
                  onTap: () {
                    _runOnUi(() => _selectedIp = candidate.ip);
                    _invalidateChecks();
                    _revalidateFirmware();
                  },
                  leading: Icon(
                    selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    color: selected
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  title: Text(candidate.ip),
                  subtitle: Text('${candidate.hint}: ${candidate.banner}'),
                );
              }),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.only(left: 12),
                child: TextButton.icon(
                  onPressed: _discoveryBusy ? null : _forgetHostKey,
                  icon: const Icon(Icons.key_off),
                  label: Text('Forget pinned host key for $_selectedIp'),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _discoveryBusy ? null : _probeGateways,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Search again'),
                ),
                OutlinedButton.icon(
                  onPressed: _discoveryBusy ? null : _sweepSubnet,
                  icon: const Icon(Icons.search),
                  label: const Text('Find more devices'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _manualIpController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Router IP address',
                      hintText: '192.168.1.1',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(onPressed: _useManualIp, child: const Text('Use')),
              ],
            ),
            if (_discoveryBusy && _candidates.isEmpty) ...[
              const SizedBox(height: 8),
              TextButton(
                onPressed: () {
                  _sweepCancelled = true;
                  _runOnUi(
                    () => _discoveryStatus = 'Search stopped. Enter the address '
                        'manually.',
                  );
                },
                child: const Text('Stop searching'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _credentialsCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _usernameController,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Username',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passwordController,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'Password',
                helperText: 'Leave empty for a fresh OpenWrt install, which '
                    'has no root password. Never stored: it lives in memory '
                    'until this window closes.',
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                onPressed: _selectedIp == null || _discoveryBusy
                    ? null
                    : _identifyRouter,
                icon: const Icon(Icons.how_to_reg),
                label: const Text('Identify router'),
              ),
            ),
            if (_router != null) ...[
              const SizedBox(height: 12),
              _kv(theme, 'Board name', _router!.boardName),
              _kv(theme, 'Model', _router!.model),
              _kv(theme, 'Firmware now', _router!.firmwareVersion),
              _kv(theme, 'Hostname', _router!.hostname),
              _kv(theme, 'Checked identifiers', _router!.identifiers.join(', ')),
            ],
          ],
        ),
      ),
    );
  }

  Widget _kv(ThemeData theme, String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 160,
              child: Text(
                label,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            Expanded(child: SelectableText(value.isEmpty ? '-' : value)),
          ],
        ),
      );

  Widget _firmwareCard(ThemeData theme) {
    final firmware = _firmware;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    firmware?.fileName ?? 'No image selected',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.onSurface),
                  ),
                ),
                if (_firmwareBusy)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  OutlinedButton(
                    onPressed: _pickFirmware,
                    child: const Text('Browse...'),
                  ),
              ],
            ),
            if (firmware != null) ...[
              const SizedBox(height: 12),
              _kv(theme, 'Size', firmware.sizeLabel),
              _kv(theme, 'Version', firmware.version),
              _kv(theme, 'SHA-256', firmware.sha256),
              if (firmware.supportedDevices.isNotEmpty)
                _kv(theme, 'Names devices', firmware.supportedDevices.join(', ')),
              const SizedBox(height: 8),
              _statusLine(
                theme,
                firmware.status == FirmwareStatus.matched
                    ? CheckOutcome.passed
                    : (firmware.status == FirmwareStatus.unverifiable
                        ? CheckOutcome.warning
                        : CheckOutcome.failed),
                switch (firmware.status) {
                  FirmwareStatus.matched => 'Image is for this device',
                  FirmwareStatus.mismatched => 'Image is for different hardware',
                  FirmwareStatus.unverifiable => 'Image cannot be checked',
                  FirmwareStatus.invalid => 'Not flashable',
                },
                firmware.detail,
              ),
              if (firmware.needsAcknowledgement) ...[
                CheckboxListTile(
                  value: _ackUnverified,
                  onChanged: (value) {
                    _runOnUi(() => _ackUnverified = value ?? false);
                    _invalidateChecks();
                  },
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text(
                    'I accept the risk: I have confirmed this image is for this '
                    'exact model, and there is no metadata to prove it.',
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _statusLine(
    ThemeData theme,
    CheckOutcome outcome,
    String title,
    String detail,
  ) {
    final color = switch (outcome) {
      CheckOutcome.passed => theme.colorScheme.primary,
      CheckOutcome.warning => theme.colorScheme.tertiary,
      CheckOutcome.failed => theme.colorScheme.error,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                switch (outcome) {
                  CheckOutcome.passed => Icons.check_circle_outline,
                  CheckOutcome.warning => Icons.warning_amber_rounded,
                  CheckOutcome.failed => Icons.error_outline,
                },
                size: 18,
                color: color,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(title, style: TextStyle(color: color)),
              ),
            ],
          ),
          if (detail.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 26, top: 2),
              child: Text(
                detail,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }

  Widget _optionsCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            SwitchListTile(
              value: _keepSettings,
              onChanged: (value) {
                _runOnUi(() => _keepSettings = value);
                _invalidateChecks();
              },
              title: const Text('Keep the router configuration'),
              subtitle: Text(
                _keepSettings
                    ? 'sysupgrade runs without -n, so /etc files listed for '
                        'backup survive the flash.'
                    : 'sysupgrade runs with -n. Every setting on the router is '
                        'erased, including the password you just typed.',
              ),
            ),
            SwitchListTile(
              value: _backupConfig,
              onChanged: (value) => _runOnUi(() => _backupConfig = value),
              title: const Text('Download a configuration backup first'),
              subtitle: const Text(
                'Runs sysupgrade -b and saves the archive to your computer '
                'before anything is written. Recommended especially when the '
                'configuration is being erased.',
              ),
            ),
            if (_backupFile != null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: _kv(theme, 'Backup', _backupFile!),
              ),
          ],
        ),
      ),
    );
  }

  Widget _checksCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _preflightOk
                        ? 'Checks passed — the flash may proceed.'
                        : 'Checks have not all passed.',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                FilledButton.tonal(
                  onPressed: _router != null && _firmware != null
                      ? _runPreflight
                      : null,
                  child: const Text('Run safety checks'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ..._checks.map(
              (row) => _statusLine(theme, row.outcome, row.name, row.detail),
            ),
          ],
        ),
      ),
    );
  }

  Widget _warningBanner(ThemeData theme) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(Icons.priority_high, color: theme.colorScheme.onErrorContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Interrupting an upload or a flash can leave the router unable '
                'to boot. Keep the router and this computer on power, and do '
                'not close this window while a flash is running.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onErrorContainer),
              ),
            ),
          ],
        ),
      );

  Widget _buildFlashScreen(ThemeData theme) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Flashing'),
        automaticallyImplyLeading: false,
        backgroundColor: theme.colorScheme.primaryContainer,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(_status, style: theme.textTheme.titleMedium),
                const SizedBox(height: 16),
                if (_step == FlashStep.upload) ...[
                  LinearProgressIndicator(value: _progress, minHeight: 10),
                  const SizedBox(height: 8),
                  Text('${(_progress * 100).toStringAsFixed(0)}%'),
                ] else
                  const LinearProgressIndicator(minHeight: 10),
                const SizedBox(height: 24),
                ...FlashStep.values
                    .where((step) => step != FlashStep.idle)
                    .map((step) {
                  final currentIndex = FlashStep.values.indexOf(_step);
                  final stepIndex = FlashStep.values.indexOf(step);
                  final isDone = currentIndex > stepIndex;
                  final isActive = currentIndex == stepIndex;
                  final color = isDone
                      ? theme.colorScheme.primary
                      : (isActive
                          ? theme.colorScheme.onSurface
                          : theme.colorScheme.onSurfaceVariant);
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Icon(
                          isDone
                              ? Icons.check_circle_outline
                              : (isActive
                                  ? Icons.radio_button_checked
                                  : Icons.radio_button_unchecked),
                          size: 18,
                          color: color,
                        ),
                        const SizedBox(width: 8),
                        Text(step.label, style: TextStyle(color: color)),
                      ],
                    ),
                  );
                }),
                const SizedBox(height: 24),
                if (_step == FlashStep.upload)
                  OutlinedButton.icon(
                    onPressed: _cancelRequested ? null : _cancelUpload,
                    icon: const Icon(Icons.close),
                    label: Text(
                      _cancelRequested ? 'Cancelling...' : 'Cancel upload',
                    ),
                  )
                else if (_step == FlashStep.rebootWait && _flashIssued) ...[
                  OutlinedButton.icon(
                    onPressed: _skipConfirmation
                        ? null
                        : () => _runOnUi(() => _skipConfirmation = true),
                    icon: const Icon(Icons.fact_check_outlined),
                    label: Text(
                      _skipConfirmation
                          ? 'Showing the result...'
                          : 'Stop waiting and show result',
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'The image has been installed. Waiting is only for '
                    'automatic confirmation; stopping does not interrupt the '
                    'flash.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall,
                  ),
                ]
                else if (_installStarted)
                  _statusLine(
                    theme,
                    CheckOutcome.warning,
                    'Cannot be cancelled',
                    'The image is already being written to the router. '
                    'Cancelling here would leave it unbootable.',
                  )
                else
                  OutlinedButton.icon(
                    onPressed: _leaveProgressScreen,
                    icon: const Icon(Icons.close),
                    label: const Text('Leave this screen'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildResultScreen(ThemeData theme) {
    final verified = _verifiedAfter;
    final error = _flashError;
    final started = _installStarted;
    final confirmed = verified != null && error == null;
    final installed = _flashIssued && !confirmed;
    final success = confirmed || installed;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          confirmed
              ? 'Flash complete'
              : (installed ? 'Firmware installed' : 'Flash did not complete'),
        ),
        backgroundColor: theme.colorScheme.primaryContainer,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(32),
            shrinkWrap: true,
            children: [
              Icon(
                success
                    ? Icons.check_circle_outline
                    : (started ? Icons.dangerous_outlined : Icons.error_outline),
                size: 56,
                color: success
                    ? theme.colorScheme.primary
                    : theme.colorScheme.error,
              ),
              const SizedBox(height: 12),
              Text(
                confirmed
                    ? 'Confirmed: the router is running '
                        '${verified.firmwareVersion}.'
                    : installed
                        ? 'The sysupgrade command was issued, but the router '
                            'did not confirm the new firmware within the time '
                            'limit. Whether it restarted into the new image is '
                            'not verified yet — check the router below.'
                        : (started
                            ? 'The flash was started and could not be confirmed.'
                            : 'Nothing was flashed.'),
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      _kv(theme, 'Board', _router?.boardName ?? ''),
                      _kv(theme, 'Firmware before', _versionBefore ?? 'not recorded'),
                      _kv(
                        theme,
                        'Firmware after',
                        verified?.firmwareVersion ?? 'unconfirmed',
                      ),
                      if (_backupFile != null)
                        _kv(theme, 'Config backup', _backupFile!),
                      if (_firmware != null && !_firmware!.isConfirmedForDevice)
                        _kv(theme, 'Image was', 'unverified by your choice'),
                    ],
                  ),
                ),
              ),
              if (_confirmationNote != null) ...[
                const SizedBox(height: 16),
                _statusLine(
                  theme,
                  CheckOutcome.warning,
                  'Why it is unconfirmed',
                  _confirmationNote!,
                ),
              ],
              if (error != null) ...[
                const SizedBox(height: 16),
                _statusLine(theme, CheckOutcome.failed, 'What happened', error),
              ],
              if (installed) ...[
                const SizedBox(height: 12),
                _statusLine(
                  theme,
                  CheckOutcome.warning,
                  'What to do',
                  'Give the router a few minutes to finish booting. Erasing the '
                  'configuration usually returns it to its stock address (often '
                  '192.168.1.1), and this computer may need to renew its DHCP '
                  'lease to reach it. Confirm below once it answers — do not '
                  're-flash.',
                ),
              ] else if (started && !success) ...[
                const SizedBox(height: 12),
                _statusLine(
                  theme,
                  CheckOutcome.warning,
                  'What to do',
                  'Give the router up to five minutes and look at its power '
                  'light. If it never comes back, follow the Recovery tab '
                  '(TFTP or failsafe) rather than re-flashing blind. '
                  'Re-running this tool against an image that is not the '
                  'router\'s own board name will make things worse.',
                ),
              ],
              if (installed) ...[
                const SizedBox(height: 16),
                _confirmAddressCard(theme),
              ],
              const SizedBox(height: 24),
              Center(
                child: FilledButton(
                  onPressed: () {
                    _runOnUi(() {
                      _verifiedAfter = null;
                      _flashError = null;
                      _installStarted = false;
                      _flashIssued = false;
                      _confirmationNote = null;
                      _skipConfirmation = false;
                      _confirming = false;
                      _confirmError = null;
                      _confirmIpController.clear();
                      _firmwarePath = null;
                      _firmware = null;
                      _ackUnverified = false;
                      _checks = [];
                      _preflightOk = false;
                      _backupFile = null;
                      _versionBefore = null;
                      _bootIdBefore = null;
                      _passwordController.clear();
                    });
                    _probeGateways();
                  },
                  child: const Text('Start over'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _confirmAddressCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Confirm the router\'s new address',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            Text(
              'After the configuration was erased the router returns to its '
              'stock address. Enter the address it answers on now and this '
              'check reads its board name over SSH. It never re-flashes.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _confirmIpController,
              keyboardType: TextInputType.number,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Router address',
                hintText: '192.168.1.1',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            if (_confirmError != null) ...[
              const SizedBox(height: 8),
              Text(
                _confirmError!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ],
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                onPressed: _confirming ? null : _confirmFirmware,
                icon: const Icon(Icons.how_to_reg),
                label: Text(_confirming ? 'Checking...' : 'Confirm firmware'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
