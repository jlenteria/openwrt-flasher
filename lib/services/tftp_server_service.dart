import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Read-only TFTP server (RFC 1350) with the blksize and tsize options
/// (RFC 2347/2348/2349), which is what U-Boot `tftpboot` and most vendor
/// bootloader recovery modes use to pull an image from the PC.
///
/// Every request is logged, including ones for files that do not exist, so
/// the user can see the exact file name a bootloader is asking for.
class TftpServerService {
  static const defaultPort = 69;
  static const _opRrq = 1;
  static const _opWrq = 2;
  static const _opData = 3;
  static const _opAck = 4;
  static const _opError = 5;
  static const _opOack = 6;
  static const _retryTimeout = Duration(seconds: 2);
  static const _maxRetries = 6;

  RawDatagramSocket? _socket;
  String _root = '';
  final Set<_Transfer> _transfers = {};

  final _logController = StreamController<String>.broadcast();
  Stream<String> get log => _logController.stream;

  bool get isRunning => _socket != null;
  int? get port => _socket?.port;

  /// Throws a [SocketException] when the port cannot be bound, for example
  /// when another TFTP server is running or the OS reserves ports below 1024.
  Future<void> start(String rootDirectory, {int port = defaultPort}) async {
    await stop();
    final dir = Directory(rootDirectory);
    if (!await dir.exists()) {
      throw FileSystemException('Folder does not exist', rootDirectory);
    }
    _root = dir.absolute.path;
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port);
    _socket = socket;
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram != null) _onRequest(datagram);
    });
    _emit('TFTP server listening on UDP port $port, serving $_root');
  }

  Future<void> stop() async {
    for (final transfer in _transfers.toList()) {
      transfer.close();
    }
    _transfers.clear();
    _socket?.close();
    if (_socket != null) _emit('TFTP server stopped');
    _socket = null;
  }

  void dispose() {
    stop();
    _logController.close();
  }

  void _emit(String message) {
    if (_logController.isClosed) return;
    final now = DateTime.now();
    final stamp = '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}';
    _logController.add('[$stamp] $message');
  }

  Future<void> _onRequest(Datagram datagram) async {
    final data = datagram.data;
    final peer = '${datagram.address.address}:${datagram.port}';
    if (data.length < 4) return;
    final opcode = (data[0] << 8) | data[1];

    if (opcode == _opWrq) {
      _emit('$peer tried to upload a file; this server is read-only');
      await _sendErrorFromNewSocket(datagram, 2, 'Uploads are not accepted');
      return;
    }
    if (opcode != _opRrq) return;

    final fields = parseRequestFields(data.sublist(2));
    if (fields.isEmpty) return;
    final requested = fields.first;
    final mode = fields.length > 1 ? fields[1].toLowerCase() : 'octet';
    final options = <String, String>{};
    for (var i = 2; i + 1 < fields.length; i += 2) {
      options[fields[i].toLowerCase()] = fields[i + 1];
    }

    _emit('$peer requested "$requested" ($mode)');

    final file = resolveFile(_root, requested);
    if (file == null) {
      _emit('  -> not found in $_root. Put a file named '
          '"${baseName(requested)}" in the folder and retry.');
      await _sendErrorFromNewSocket(datagram, 1, 'File not found');
      return;
    }

    final transfer = _Transfer(
      peer: datagram.address,
      peerPort: datagram.port,
      file: file,
      options: options,
      log: _emit,
      onDone: (t) => _transfers.remove(t),
    );
    _transfers.add(transfer);
    try {
      await transfer.start();
    } catch (error) {
      _emit('  -> could not start transfer: $error');
      transfer.close();
    }
  }

  Future<void> _sendErrorFromNewSocket(
    Datagram request,
    int code,
    String message,
  ) async {
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.send(errorPacket(code, message), request.address, request.port);
    } catch (_) {
    } finally {
      socket?.close();
    }
  }

  /// Splits the NUL-separated strings of a request after the opcode.
  static List<String> parseRequestFields(List<int> body) {
    final fields = <String>[];
    var start = 0;
    for (var i = 0; i < body.length; i++) {
      if (body[i] == 0) {
        fields.add(String.fromCharCodes(body.sublist(start, i)));
        start = i + 1;
      }
    }
    return fields;
  }

  static String baseName(String requested) =>
      requested.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty).lastOrNull ??
      '';

  /// Maps a requested name onto a file directly inside [root]. Bootloaders
  /// often prefix a directory or use different letter case, so only the base
  /// name is honoured and a case-insensitive match is accepted. Nothing outside
  /// [root] can ever be served.
  static File? resolveFile(String root, String requested) {
    final name = baseName(requested);
    if (name.isEmpty || name == '.' || name == '..') return null;
    final separator = Platform.pathSeparator;
    final exact = File('$root$separator$name');
    if (exact.existsSync()) return exact;
    try {
      for (final entity in Directory(root).listSync(followLinks: false)) {
        if (entity is! File) continue;
        if (baseName(entity.path).toLowerCase() == name.toLowerCase()) {
          return entity;
        }
      }
    } catch (_) {}
    return null;
  }

  static Uint8List errorPacket(int code, String message) {
    final bytes = BytesBuilder()
      ..add([0, _opError, 0, code])
      ..add(message.codeUnits)
      ..addByte(0);
    return bytes.toBytes();
  }
}

class _Transfer {
  _Transfer({
    required this.peer,
    required this.peerPort,
    required this.file,
    required this.options,
    required this.log,
    required this.onDone,
  });

  final InternetAddress peer;
  final int peerPort;
  final File file;
  final Map<String, String> options;
  final void Function(String) log;
  final void Function(_Transfer) onDone;

  RawDatagramSocket? _socket;
  RandomAccessFile? _raf;
  Timer? _timer;
  int _blockSize = 512;
  int _fileSize = 0;
  int _block = 0;
  int _sentBytes = 0;
  int _retries = 0;
  bool _lastBlockSent = false;
  bool _closed = false;
  Uint8List? _lastPacket;
  int _lastLoggedPercent = -1;
  final _stopwatch = Stopwatch();

  Future<void> start() async {
    _raf = await file.open();
    _fileSize = await file.length();
    _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    _socket!.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = _socket?.receive();
      if (datagram != null) _onPacket(datagram);
    });

    final accepted = <String, String>{};
    final requestedBlock = int.tryParse(options['blksize'] ?? '');
    if (requestedBlock != null) {
      _blockSize = requestedBlock.clamp(8, 1468);
      accepted['blksize'] = '$_blockSize';
    }
    if (options.containsKey('tsize')) accepted['tsize'] = '$_fileSize';
    final timeout = int.tryParse(options['timeout'] ?? '');
    if (timeout != null && timeout >= 1 && timeout <= 255) {
      accepted['timeout'] = '$timeout';
    }

    log('  -> sending ${file.path} (${_formatSize(_fileSize)}, '
        'block size $_blockSize)');
    _stopwatch.start();
    if (accepted.isEmpty) {
      _sendNextBlock();
    } else {
      final packet = BytesBuilder()..add([0, TftpServerService._opOack]);
      accepted.forEach((key, value) {
        packet
          ..add(key.codeUnits)
          ..addByte(0)
          ..add(value.codeUnits)
          ..addByte(0);
      });
      _send(packet.toBytes());
    }
  }

  void _onPacket(Datagram datagram) {
    if (_closed) return;
    if (datagram.address != peer || datagram.port != peerPort) {
      _socket?.send(
        TftpServerService.errorPacket(5, 'Unknown transfer ID'),
        datagram.address,
        datagram.port,
      );
      return;
    }
    final data = datagram.data;
    if (data.length < 4) return;
    final opcode = (data[0] << 8) | data[1];
    if (opcode == TftpServerService._opError) {
      final message = String.fromCharCodes(
        data.sublist(4).takeWhile((byte) => byte != 0),
      );
      log('  -> client aborted the transfer: $message');
      close();
      return;
    }
    if (opcode != TftpServerService._opAck) return;
    final acked = (data[2] << 8) | data[3];
    // Block numbers are 16 bits and roll over to 0 on large images.
    if (acked != (_block & 0xFFFF)) return;
    _retries = 0;
    if (_lastBlockSent) {
      _stopwatch.stop();
      final seconds = math.max(_stopwatch.elapsedMilliseconds, 1) / 1000;
      log('  -> done: ${_formatSize(_sentBytes)} in '
          '${seconds.toStringAsFixed(1)}s');
      close();
      return;
    }
    _sendNextBlock();
  }

  void _sendNextBlock() {
    final raf = _raf;
    if (raf == null || _closed) return;
    _block++;
    final chunk = raf.readSync(_blockSize);
    _sentBytes += chunk.length;
    _lastBlockSent = chunk.length < _blockSize;
    final packet = Uint8List(4 + chunk.length)
      ..[0] = 0
      ..[1] = TftpServerService._opData
      ..[2] = (_block >> 8) & 0xFF
      ..[3] = _block & 0xFF
      ..setRange(4, 4 + chunk.length, chunk);
    _send(packet);

    if (_fileSize > 0) {
      final percent = (_sentBytes * 100 ~/ _fileSize);
      if (percent ~/ 10 != _lastLoggedPercent ~/ 10) {
        _lastLoggedPercent = percent;
        if (percent < 100) log('  -> $percent%');
      }
    }
  }

  void _send(Uint8List packet) {
    _lastPacket = packet;
    _socket?.send(packet, peer, peerPort);
    _timer?.cancel();
    _timer = Timer(TftpServerService._retryTimeout, _retransmit);
  }

  void _retransmit() {
    if (_closed) return;
    final packet = _lastPacket;
    if (packet == null) return;
    if (++_retries > TftpServerService._maxRetries) {
      log('  -> client stopped answering; transfer abandoned at '
          '${_formatSize(_sentBytes)}');
      close();
      return;
    }
    _socket?.send(packet, peer, peerPort);
    _timer = Timer(TftpServerService._retryTimeout, _retransmit);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    _socket?.close();
    _socket = null;
    try {
      _raf?.closeSync();
    } catch (_) {}
    _raf = null;
    onDone(this);
  }

  static String _formatSize(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}
