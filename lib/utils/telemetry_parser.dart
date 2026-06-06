import '../models/telemetry_data.dart';

class TelemetryParser {
  static TelemetryData? parse(String rawData) {
    try {
      final cleanedData = rawData.trim();

      if (cleanedData.isEmpty) {
        return null;
      }

      final parts = cleanedData.split(',');
      final Map<String, String> dataMap = {};

      for (final part in parts) {
        final keyValue = part.split(':');

        if (keyValue.length == 2) {
          final key = keyValue[0].trim();
          final value = keyValue[1].trim();
          dataMap[key] = value;
        }
      }

      final speed = double.tryParse(dataMap['speed'] ?? '0') ?? 0;
      final soc = double.tryParse(dataMap['soc'] ?? '0') ?? 0;
      final voltage = double.tryParse(dataMap['voltage'] ?? '0') ?? 0;
      final current = double.tryParse(dataMap['current'] ?? '0') ?? 0;
      final batteryTemp = double.tryParse(dataMap['batteryTemp'] ?? '0') ?? 0;
      final motorTemp = double.tryParse(dataMap['motorTemp'] ?? '0') ?? 0;

      final warnings = _generateWarnings(
        speed: speed,
        soc: soc,
        voltage: voltage,
        current: current,
        batteryTemp: batteryTemp,
        motorTemp: motorTemp,
      );

      final status = warnings.isEmpty ? 'OK' : 'WARNING';

      return TelemetryData(
        speed: speed,
        soc: soc,
        voltage: voltage,
        current: current,
        batteryTemp: batteryTemp,
        motorTemp: motorTemp,
        status: status,
        timestamp: DateTime.now(),
        warnings: warnings,
      );
    } catch (e) {
      return null;
    }
  }

  static List<String> _generateWarnings({
    required double speed,
    required double soc,
    required double voltage,
    required double current,
    required double batteryTemp,
    required double motorTemp,
  }) {
    final List<String> warnings = [];

    if (soc < 20) {
      warnings.add('Batarya doluluk oranı düşük');
    }

    if (voltage < 280) {
      warnings.add('Batarya gerilimi düşük');
    }

    if (current > 30) {
      warnings.add('Batarya akımı yüksek');
    }

    if (batteryTemp > 45) {
      warnings.add('Batarya sıcaklığı yüksek');
    }

    if (motorTemp > 55) {
      warnings.add('Motor sıcaklığı yüksek');
    }

    if (speed > 100) {
      warnings.add('Araç hızı güvenli sınırın üzerinde');
    }

    return warnings;
  }
}