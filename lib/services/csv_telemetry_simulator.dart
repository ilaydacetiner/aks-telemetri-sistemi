import 'dart:async';

import 'package:csv/csv.dart';
import 'package:flutter/services.dart';

import '../models/telemetry_data.dart';

class CsvTelemetrySimulator {
  final String assetPath;

  List<TelemetryData> _data = [];
  int _currentIndex = 0;

  Timer? _timer;

  CsvTelemetrySimulator({
    this.assetPath = 'assets/data/ev_telemetry.csv',
  });

  Future<void> loadCsv() async {
    final rawCsv = await rootBundle.loadString(assetPath);

    final rows = const CsvToListConverter(
      eol: '\n',
      shouldParseNumbers: false,
    ).convert(rawCsv);

    if (rows.isEmpty) {
      throw Exception('CSV dosyası boş.');
    }

    final headers = rows.first.map((e) => e.toString().trim()).toList();
    final dataRows = rows.skip(1).toList();

    _data = dataRows.map((row) {
      return _mapRowToTelemetryData(headers, row);
    }).toList();

    _currentIndex = 0;
  }

  void start({
    required void Function(TelemetryData data) onData,
    Duration interval = const Duration(milliseconds: 500),
  }) {
    if (_data.isEmpty) {
      throw Exception('CSV verisi yüklenmedi. Önce loadCsv() çağırılmalı.');
    }

    _timer?.cancel();

    _timer = Timer.periodic(interval, (_) {
      if (_currentIndex >= _data.length) {
        _currentIndex = 0;
      }

      final data = _data[_currentIndex];
      _currentIndex++;

      onData(data);
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void reset() {
    _currentIndex = 0;
  }

  bool get isRunning => _timer?.isActive ?? false;

  TelemetryData _mapRowToTelemetryData(
    List<String> headers,
    List<dynamic> row,
  ) {
    String getString(List<String> possibleNames) {
      for (final name in possibleNames) {
        final target = _normalize(name);

        final index = headers.indexWhere(
          (header) => _normalize(header) == target,
        );

        if (index != -1 && index < row.length) {
          return row[index].toString().trim();
        }
      }

      return '';
    }

    double getDouble(List<String> possibleNames, {double defaultValue = 0}) {
      final value = getString(possibleNames);

      if (value.isEmpty) {
        return defaultValue;
      }

      final cleanedValue = value
          .replaceAll(',', '.')
          .replaceAll('%', '')
          .replaceAll('ms', '')
          .replaceAll('V', '')
          .replaceAll('A', '')
          .replaceAll('RPM', '')
          .replaceAll('rpm', '')
          .trim();

      return double.tryParse(cleanedValue) ?? defaultValue;
    }

    return TelemetryData(
      timestamp: DateTime.now(),
      timeMs: getDouble([
        'Time (ms)',
        'Time',
        'time_ms',
        'time',
      ]),
      voltage: getDouble([
        'Voltage (V)',
        'Voltage',
        'voltage',
        'voltage_v',
      ]),
      current: getDouble([
        'Current (A)',
        'Current',
        'current',
        'current_a',
      ]),
      temperature: getDouble([
        'Temperature (°C)',
        'Temperature (Â°C)',
        'Temperature',
        'temperature',
        'temperature_c',
      ]),
      motorSpeedRpm: getDouble([
        'Motor Speed (RPM)',
        'Motor Speed',
        'Motor_Speed_RPM',
        'motor_speed_rpm',
        'motorSpeed',
      ]),
      hallCode: getString([
        'Hall Code',
        'Hall_Code',
        'hall_code',
        'hallCode',
      ]),
      estimatedSoc: getDouble([
        'Estimated SOC (%)',
        'Estimated SOC',
        'estimated_soc',
        'estimatedSoc',
      ]),
      groundTruthSoc: getDouble([
        'Ground Truth SOC (%)',
        'Ground Truth SOC',
        'ground_truth_soc',
        'groundTruthSoc',
      ]),
      residual: getDouble([
        'Residual (%)',
        'Residual',
        'residual',
      ]),
      faultLabel: getString([
        'Fault Label',
        'Fault_Label',
        'fault_label',
        'faultLabel',
      ]),
    );
  }

  String _normalize(String value) {
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), '');
  }
}