import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_libserialport/flutter_libserialport.dart';

class SerialService {
  SerialPort? _port;
  SerialPortReader? _reader;
  StreamSubscription<Uint8List>? _subscription;

  final StringBuffer _buffer = StringBuffer();

  List<String> getAvailablePorts() {
    return SerialPort.availablePorts;
  }

  bool connect({
    required String portName,
    required void Function(String rawData) onDataReceived,
    int baudRate = 9600,
  }) {
    try {
      disconnect();

      _port = SerialPort(portName);

      if (!_port!.openReadWrite()) {
        return false;
      }

      final config = SerialPortConfig()
        ..baudRate = baudRate
        ..bits = 8
        ..stopBits = 1
        ..parity = SerialPortParity.none;

      _port!.config = config;

      _reader = SerialPortReader(_port!);

      _subscription = _reader!.stream.listen((data) {
        final incomingText = utf8.decode(data, allowMalformed: true);

        _buffer.write(incomingText);

        final bufferText = _buffer.toString();

        if (bufferText.contains('\n')) {
          final lines = bufferText.split('\n');

          for (int i = 0; i < lines.length - 1; i++) {
            final line = lines[i].trim();

            if (line.isNotEmpty) {
              onDataReceived(line);
            }
          }

          _buffer
            ..clear()
            ..write(lines.last);
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

    _port?.dispose();
    _port = null;

    _buffer.clear();
  }
}