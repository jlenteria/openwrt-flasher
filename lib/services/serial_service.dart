import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_libserialport/flutter_libserialport.dart';

class SerialService {
  SerialPort? _port;
  SerialPortReader? _reader;
  StreamSubscription<Uint8List>? _subscription;
  
  final _dataController = StreamController<String>.broadcast();
  Stream<String> get dataStream => _dataController.stream;
  
  bool get isConnected => _port != null && _port!.isOpen;
  
  List<String> getAvailablePorts() {
    return SerialPort.availablePorts;
  }
  
  Future<bool> connect(String portName, {int baudRate = 115200}) async {
    try {
      disconnect();
      _port = SerialPort(portName);
      if (!_port!.openReadWrite()) {
        return false;
      }
      
      final config = SerialPortConfig();
      config.baudRate = baudRate;
      config.bits = 8;
      config.stopBits = 1;
      config.parity = 0;
      _port!.config = config;
      
      _reader = SerialPortReader(_port!);
      _subscription = _reader!.stream.listen((data) {
        try {
          final str = String.fromCharCodes(data);
          _dataController.add(str);
        } catch (e) {
          // Ignore decode errors
        }
      });
      return true;
    } catch (e) {
      return false;
    }
  }
  
  void write(String data) {
    if (_port != null && _port!.isOpen) {
      _port!.write(Uint8List.fromList(data.codeUnits));
    }
  }
  
  void writeByte(int byte) {
    if (_port != null && _port!.isOpen) {
      _port!.write(Uint8List.fromList([byte]));
    }
  }
  
  void disconnect() {
    _subscription?.cancel();
    _subscription = null;
    _reader = null;
    if (_port != null && _port!.isOpen) {
      _port!.close();
    }
    _port = null;
  }
  
  void dispose() {
    disconnect();
    _dataController.close();
  }
}
