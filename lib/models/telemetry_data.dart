class TelemetryData {
  final double speed;
  final double soc;
  final double voltage;
  final double current;
  final double batteryTemp;
  final double motorTemp;
  final String status;
  final DateTime timestamp;
  final List<String> warnings;

  TelemetryData({
    required this.speed,
    required this.soc,
    required this.voltage,
    required this.current,
    required this.batteryTemp,
    required this.motorTemp,
    required this.status,
    required this.timestamp,
    required this.warnings,
  });

  factory TelemetryData.empty() {
    return TelemetryData(
      speed: 0,
      soc: 0,
      voltage: 0,
      current: 0,
      batteryTemp: 0,
      motorTemp: 0,
      status: 'BEKLENİYOR',
      timestamp: DateTime.now(),
      warnings: const [],
    );
  }
}