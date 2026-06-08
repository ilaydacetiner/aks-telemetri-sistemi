class TelemetryData {
  final DateTime timestamp;

  final double timeMs;
  final double voltage;
  final double current;
  final double temperature;
  final double motorSpeedRpm;
  final String hallCode;
  final double estimatedSoc;
  final double groundTruthSoc;
  final double residual;
  final String faultLabel;

  TelemetryData({
    required this.timestamp,
    required this.timeMs,
    required this.voltage,
    required this.current,
    required this.temperature,
    required this.motorSpeedRpm,
    required this.hallCode,
    required this.estimatedSoc,
    required this.groundTruthSoc,
    required this.residual,
    required this.faultLabel,
  });

  factory TelemetryData.empty() {
    return TelemetryData(
      timestamp: DateTime.now(),
      timeMs: 0,
      voltage: 0,
      current: 0,
      temperature: 0,
      motorSpeedRpm: 0,
      hallCode: '-',
      estimatedSoc: 0,
      groundTruthSoc: 0,
      residual: 0,
      faultLabel: 'Normal',
    );
  }
}