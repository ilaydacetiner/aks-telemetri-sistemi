import '../models/telemetry_data.dart';

class TelemetryParser {
  static TelemetryData? parse(String rawData) {
    try {
      final cleanedRawData = rawData.trim();

      if (cleanedRawData.isEmpty) {
        return null;
      }

      final Map<String, String> values = {};

      final parts = cleanedRawData.split(',');

      for (final part in parts) {
        final keyValue = part.split(':');

        if (keyValue.length == 2) {
          final key = _normalize(keyValue[0]);
          final value = keyValue[1].trim();

          values[key] = value;
        }
      }

      double getDouble(List<String> possibleKeys, {double defaultValue = 0}) {
        for (final key in possibleKeys) {
          final normalizedKey = _normalize(key);

          if (values.containsKey(normalizedKey)) {
            final value = values[normalizedKey] ?? '';
            return double.tryParse(value.replaceAll(',', '.')) ?? defaultValue;
          }
        }

        return defaultValue;
      }

      String getString(List<String> possibleKeys, {String defaultValue = ''}) {
        for (final key in possibleKeys) {
          final normalizedKey = _normalize(key);

          if (values.containsKey(normalizedKey)) {
            return values[normalizedKey] ?? defaultValue;
          }
        }

        return defaultValue;
      }

      return TelemetryData(
        timestamp: DateTime.now(),
        timeMs: getDouble([
          'timeMs',
          'time_ms',
          'time',
        ]),
        voltage: getDouble([
          'voltage',
          'voltageV',
          'voltage_v',
        ]),
        current: getDouble([
          'current',
          'currentA',
          'current_a',
        ]),
        temperature: getDouble([
          'temperature',
          'temp',
          'temperatureC',
          'temperature_c',
        ]),
        motorSpeedRpm: getDouble([
          'motorSpeedRpm',
          'motor_speed_rpm',
          'motorRpm',
          'rpm',
        ]),
        hallCode: getString([
          'hallCode',
          'hall_code',
          'hall',
        ], defaultValue: '-'),
        estimatedSoc: getDouble([
          'estimatedSoc',
          'estimated_soc',
          'soc',
        ]),
        groundTruthSoc: getDouble([
          'groundTruthSoc',
          'ground_truth_soc',
          'realSoc',
          'actualSoc',
        ]),
        residual: getDouble([
          'residual',
          'residualPercent',
          'residual_percent',
        ]),
        faultLabel: getString([
          'faultLabel',
          'fault_label',
          'status',
          'fault',
        ], defaultValue: 'Normal'),
      );
    } catch (e) {
      return null;
    }
  }

  static String _normalize(String value) {
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), '');
  }
}