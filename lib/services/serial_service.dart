import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_libserialport/flutter_libserialport.dart';

class SerialService {
  SerialPort? _port;
  SerialPortReader? _reader;
  StreamSubscription<Uint8List>? _subscription;

  String _buffer = '';

  List<String> getAvailablePorts() {
    return SerialPort.availablePorts;
  }

  bool connect({
    required String portName,
    required Function(String rawData) onDataReceived,
    int baudRate = 9600,
  }) {
    try {
      _port = SerialPort(portName);

      if (!_port!.openReadWrite()) {
        return false;
      }

      final config = SerialPortConfig();
      config.baudRate = baudRate;
      config.bits = 8;
      config.stopBits = 1;
      config.parity = SerialPortParity.none;
      _port!.config = config;

      _reader = SerialPortReader(_port!);

      _subscription = _reader!.stream.listen((data) {
        final incomingText = utf8.decode(data, allowMalformed: true);
        _buffer += incomingText;

        while (_buffer.contains('\n')) {
          final index = _buffer.indexOf('\n');
          final line = _buffer.substring(0, index).trim();
          _buffer = _buffer.substring(index + 1);

          if (line.isNotEmpty) {
            onDataReceived(line);
          }
        }
      });

      return true;
    } catch (e) {
      disconnect();
      return false;
    }
  }

  void disconnect() {
    _subscription?.cancel();
    _subscription = null;

    _reader?.close();
    _reader = null;

    if (_port != null && _port!.isOpen) {
      _port!.close();
    }

    _port = null;
    _buffer = '';
  }
}