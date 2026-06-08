import 'dart:io';

import '../models/telemetry_data.dart';

class LoggingService {
  File? _warningLogFile;
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

    final datePart =
        '${now.year}_${now.month.toString().padLeft(2, '0')}_${now.day.toString().padLeft(2, '0')}_'
        '${now.hour.toString().padLeft(2, '0')}_${now.minute.toString().padLeft(2, '0')}_${now.second.toString().padLeft(2, '0')}';

    final warningFileName = 'aks_uyari_kaydi_$datePart.csv';

    _warningLogFile = File('${logDirectory.path}\\$warningFileName');

    await _warningLogFile!.writeAsString(
  '\uFEFFsep=;\n'
  'timestamp;time_ms;warning_message;voltage_v;current_a;temperature_c;motor_speed_rpm;estimated_soc_percent;ground_truth_soc_percent;residual_percent;hall_code;fault_label\n',
);

    _isLogging = true;

    return _warningLogFile!.path;
  }

  Future<void> stopLogging() async {
    _isLogging = false;
    _warningLogFile = null;
  }

  Future<void> writeWarnings(
    TelemetryData data,
    List<String> warnings,
  ) async {
    if (!_isLogging || _warningLogFile == null || warnings.isEmpty) {
      return;
    }

    final timestamp = _formatDateTime(data.timestamp);

    for (final warning in warnings) {
      final line =
          '$timestamp;'
          '${_formatDecimal(data.timeMs, 0)};'
          '$warning;'
          '${_formatDecimal(data.voltage, 2)};'
          '${_formatDecimal(data.current, 2)};'
          '${_formatDecimal(data.temperature, 2)};'
          '${_formatDecimal(data.motorSpeedRpm, 0)};'
          '${_formatDecimal(data.estimatedSoc, 2)};'
          '${_formatDecimal(data.groundTruthSoc, 2)};'
          '${_formatDecimal(data.residual, 2)};'
          '${data.hallCode};'
          '${data.faultLabel}\n';

      await _warningLogFile!.writeAsString(
        line,
        mode: FileMode.append,
        flush: true,
      );
    }
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