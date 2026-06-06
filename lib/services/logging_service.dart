import 'dart:io';

import '../models/telemetry_data.dart';

class LoggingService {
  File? _logFile;
  bool _isLogging = false;

  bool get isLogging => _isLogging;

  Future<String> startLogging() async {
    final userProfile = Platform.environment['USERPROFILE'];

    if (userProfile == null) {
      throw Exception('Kullanıcı klasörü bulunamadı.');
    }

    final desktopDirectory = Directory('$userProfile\\Desktop');
    final logDirectory =
        Directory('${desktopDirectory.path}\\AKS_Telemetri_Kayitlari');

    if (!await logDirectory.exists()) {
      await logDirectory.create(recursive: true);
    }

    final now = DateTime.now();

    final fileName =
        'aks_telemetri_${now.year}_${now.month.toString().padLeft(2, '0')}_${now.day.toString().padLeft(2, '0')}_'
        '${now.hour.toString().padLeft(2, '0')}_${now.minute.toString().padLeft(2, '0')}_${now.second.toString().padLeft(2, '0')}.csv';

    _logFile = File('${logDirectory.path}\\$fileName');

    await _logFile!.writeAsString(
      'sep=;\n'
      'timestamp;speed_kmh;soc_percent;voltage_v;current_ampere;battery_temp_c;motor_temp_c;status\n',
    );

    _isLogging = true;

    return _logFile!.path;
  }

  Future<void> stopLogging() async {
    _isLogging = false;
    _logFile = null;
  }

  Future<void> writeData(TelemetryData data) async {
    if (!_isLogging || _logFile == null) {
      return;
    }

    final timestamp = _formatDateTime(data.timestamp);

    final line =
        '$timestamp;'
        '${data.speed.toStringAsFixed(0)};'
        '${data.soc.toStringAsFixed(0)};'
        '${data.voltage.toStringAsFixed(0)};'
        '${_formatDecimal(data.current, 1)};'
        '${data.batteryTemp.toStringAsFixed(0)};'
        '${data.motorTemp.toStringAsFixed(0)};'
        '${data.status}\n';

    await _logFile!.writeAsString(
      line,
      mode: FileMode.append,
      flush: true,
    );
  }

  String _formatDecimal(double value, int fractionDigits) {
    return value.toStringAsFixed(fractionDigits).replaceAll('.', ',');
  }

  String _formatDateTime(DateTime dateTime) {
    return '${dateTime.year}-${dateTime.month.toString().padLeft(2, '0')}-${dateTime.day.toString().padLeft(2, '0')} '
        '${dateTime.hour.toString().padLeft(2, '0')}:'
        '${dateTime.minute.toString().padLeft(2, '0')}:'
        '${dateTime.second.toString().padLeft(2, '0')}';
  }
}