import 'dart:async';
import 'dart:io';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import 'models/telemetry_data.dart';
import 'services/csv_telemetry_simulator.dart';
import 'services/logging_service.dart';
import 'services/serial_service.dart';
import 'utils/telemetry_parser.dart';

void main() {
  runApp(const AksTelemetryApp());
}

enum SensorLevel {
  waiting,
  normal,
  critical,
  risky,
}

Color getLevelColor(SensorLevel level) {
  switch (level) {
    case SensorLevel.waiting:
      return Colors.white70;
    case SensorLevel.normal:
      return const Color(0xFF38BDF8);
    case SensorLevel.critical:
      return Colors.amber;
    case SensorLevel.risky:
      return Colors.redAccent;
  }
}

class AksTelemetryApp extends StatelessWidget {
  const AksTelemetryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AKS Telemetri Sistemi',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF050816),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF38BDF8),
          brightness: Brightness.dark,
        ),
      ),
      home: const TelemetryHomePage(),
    );
  }
}

class TelemetryHomePage extends StatefulWidget {
  const TelemetryHomePage({super.key});

  @override
  State<TelemetryHomePage> createState() => _TelemetryHomePageState();
}

class _TelemetryHomePageState extends State<TelemetryHomePage> {
  final CsvTelemetrySimulator _csvSimulator = CsvTelemetrySimulator();
  final LoggingService _loggingService = LoggingService();
  final SerialService _serialService = SerialService();

  TelemetryData _telemetryData = TelemetryData.empty();

  String _connectionStatus = 'Veri seti bekleniyor';

  bool _isSimulationRunning = false;
  bool _isLogging = false;
  bool _isCsvLoaded = false;
  bool _hasReceivedData = false;
  bool _isSerialConnected = false;
  bool _isDataTimeout = false;

  DateTime? _lastDataReceivedAt;
  Timer? _connectionWatchTimer;

  List<String> _availablePorts = [];
  String? _selectedPort;

  final List<FlSpot> _voltagePoints = [];
  final List<FlSpot> _groundTruthSocPoints = [];
  double _chartIndex = 0;

  double _totalEnergyKwh = 0.0;

  static const int _seriesCellCount = 96;
  static const double _batteryCapacityKwh = 5.0;
  static const double _averageConsumptionKwhPer100Km = 15.0;
  static const double _sampleIntervalHours = 0.5 / 3600;

  @override
  void initState() {
    super.initState();
    _refreshPorts();
    _loadDataset();
    _startConnectionWatchTimer();
  }

  Future<void> _loadDataset() async {
    try {
      await _csvSimulator.loadCsv();

      setState(() {
        _isCsvLoaded = true;
        _connectionStatus = 'Veri seti hazır';
      });
    } catch (e) {
      setState(() {
        _isCsvLoaded = false;
        _isSimulationRunning = false;
        _connectionStatus = 'Veri seti yüklenemedi';
      });
    }
  }

  void _startConnectionWatchTimer() {
    _connectionWatchTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        final isExpectingData = _isSimulationRunning || _isSerialConnected;

        if (!isExpectingData) {
          if (_isDataTimeout) {
            setState(() {
              _isDataTimeout = false;
            });
          }
          return;
        }

        if (!_hasReceivedData || _lastDataReceivedAt == null) {
          return;
        }

        final difference = DateTime.now().difference(_lastDataReceivedAt!);
        final timeout = difference.inSeconds >= 5;

        if (timeout != _isDataTimeout) {
          setState(() {
            _isDataTimeout = timeout;
          });
        }
      },
    );
  }

  void _refreshPorts() {
    final ports = _serialService.getAvailablePorts();

    setState(() {
      _availablePorts = ports;

      if (ports.isNotEmpty) {
        if (_selectedPort == null || !ports.contains(_selectedPort)) {
          _selectedPort = ports.first;
        }
      } else {
        _selectedPort = null;
      }
    });
  }

  Future<void> _handleIncomingRawData(String rawData) async {
    final parsedData = TelemetryParser.parse(rawData);

    if (parsedData == null) {
      return;
    }

    await _handleIncomingData(parsedData);
  }

  Future<void> _handleIncomingData(TelemetryData data) async {
    final warnings = _generateWarnings(data);

    final instantPowerKw = _calculateInstantPowerKw(data);
    final energyIncrementKwh = instantPowerKw * _sampleIntervalHours;

    setState(() {
      _hasReceivedData = true;
      _isDataTimeout = false;
      _lastDataReceivedAt = DateTime.now();
      _telemetryData = data;
      _totalEnergyKwh += energyIncrementKwh;

      _chartIndex++;

      _voltagePoints.add(FlSpot(_chartIndex, data.voltage));
      _groundTruthSocPoints.add(FlSpot(_chartIndex, data.groundTruthSoc));

      if (_voltagePoints.length > 20) {
        _voltagePoints.removeAt(0);
      }

      if (_groundTruthSocPoints.length > 20) {
        _groundTruthSocPoints.removeAt(0);
      }
    });

    if (_isLogging) {
      await _loggingService.writeWarnings(data, warnings);
    }
  }

  String _getStatusText(List<String> warnings) {
    if (!_hasReceivedData) {
      return 'BEKLENİYOR';
    }

    if (_isDataTimeout) {
      return 'BAĞLANTI YOK';
    }

    if (warnings.isNotEmpty) {
      return 'WARNING';
    }

    return 'OK';
  }

  double _boundedSoc(double soc) {
    return soc.clamp(0, 100).toDouble();
  }

  double _calculatePackVoltage(TelemetryData data) {
    return data.voltage * _seriesCellCount;
  }

  double _calculateInstantPowerKw(TelemetryData data) {
    final packVoltage = _calculatePackVoltage(data);
    return (packVoltage * data.current.abs()) / 1000;
  }

  double _calculateRemainingEnergyKwh(TelemetryData data) {
    final boundedSoc = _boundedSoc(data.groundTruthSoc);
    return _batteryCapacityKwh * (boundedSoc / 100);
  }

  double _calculateEstimatedRangeKm(TelemetryData data) {
    final remainingEnergyKwh = _calculateRemainingEnergyKwh(data);
    return (remainingEnergyKwh / _averageConsumptionKwhPer100Km) * 100;
  }

  SensorLevel _getVoltageLevel(double voltage) {
    if (!_hasReceivedData) return SensorLevel.waiting;

    if (voltage < 3.40 || voltage > 4.10) {
      return SensorLevel.risky;
    }

    if (voltage < 3.55 || voltage > 3.95) {
      return SensorLevel.critical;
    }

    return SensorLevel.normal;
  }

  SensorLevel _getCurrentLevel(double current) {
    if (!_hasReceivedData) return SensorLevel.waiting;

    final absoluteCurrent = current.abs();

    if (absoluteCurrent >= 4.50) {
      return SensorLevel.risky;
    }

    if (absoluteCurrent >= 3.50) {
      return SensorLevel.critical;
    }

    return SensorLevel.normal;
  }

  SensorLevel _getTemperatureLevel(double temperature) {
    if (!_hasReceivedData) return SensorLevel.waiting;

    if (temperature >= 40) {
      return SensorLevel.risky;
    }

    if (temperature >= 32) {
      return SensorLevel.critical;
    }

    return SensorLevel.normal;
  }

  SensorLevel _getMotorSpeedLevel(double rpm) {
    if (!_hasReceivedData) return SensorLevel.waiting;

    if (rpm >= 1350) {
      return SensorLevel.risky;
    }

    if (rpm >= 1250) {
      return SensorLevel.critical;
    }

    return SensorLevel.normal;
  }

  SensorLevel _getSocLevel(double soc) {
    if (!_hasReceivedData) return SensorLevel.waiting;

    if (soc < 20 || soc > 100) {
      return SensorLevel.risky;
    }

    if (soc < 35) {
      return SensorLevel.critical;
    }

    return SensorLevel.normal;
  }

  List<String> _generateWarnings(TelemetryData data) {
    final List<String> warnings = [];

    if (!_hasReceivedData) {
      return warnings;
    }

    if (_isDataTimeout) {
      warnings.add('Riskli veri akisi kesildi');
      return warnings;
    }

    final voltageLevel = _getVoltageLevel(data.voltage);
    final currentLevel = _getCurrentLevel(data.current);
    final temperatureLevel = _getTemperatureLevel(data.temperature);
    final motorSpeedLevel = _getMotorSpeedLevel(data.motorSpeedRpm);
    final socLevel = _getSocLevel(data.groundTruthSoc);

    if (voltageLevel == SensorLevel.critical) {
      warnings.add('Kritik gerilim seviyesi');
    } else if (voltageLevel == SensorLevel.risky) {
      warnings.add('Riskli gerilim seviyesi');
    }

    if (currentLevel == SensorLevel.critical) {
      warnings.add('Kritik akim seviyesi');
    } else if (currentLevel == SensorLevel.risky) {
      warnings.add('Riskli akim seviyesi');
    }

    if (temperatureLevel == SensorLevel.critical) {
      warnings.add('Kritik sicaklik seviyesi');
    } else if (temperatureLevel == SensorLevel.risky) {
      warnings.add('Riskli sicaklik seviyesi');
    }

    if (motorSpeedLevel == SensorLevel.critical) {
      warnings.add('Kritik motor hizi seviyesi');
    } else if (motorSpeedLevel == SensorLevel.risky) {
      warnings.add('Riskli motor hizi seviyesi');
    }

    if (socLevel == SensorLevel.critical) {
      warnings.add('Kritik SOC seviyesi');
    } else if (socLevel == SensorLevel.risky) {
      warnings.add('Riskli SOC seviyesi');
    }

    return warnings;
  }

  SensorLevel _getOverallWarningLevel() {
    if (!_hasReceivedData) return SensorLevel.waiting;

    if (_isDataTimeout) {
      return SensorLevel.risky;
    }

    final levels = [
      _getVoltageLevel(_telemetryData.voltage),
      _getCurrentLevel(_telemetryData.current),
      _getTemperatureLevel(_telemetryData.temperature),
      _getMotorSpeedLevel(_telemetryData.motorSpeedRpm),
      _getSocLevel(_telemetryData.groundTruthSoc),
    ];

    if (levels.contains(SensorLevel.risky)) {
      return SensorLevel.risky;
    }

    if (levels.contains(SensorLevel.critical)) {
      return SensorLevel.critical;
    }

    return SensorLevel.normal;
  }

  IconData _getConnectionIcon() {
    if (_isDataTimeout) {
      return Icons.signal_wifi_connected_no_internet_4;
    }

    if (_connectionStatus == 'Bağlantı kesildi') {
      return Icons.link_off;
    }

    if (_isSimulationRunning || _isSerialConnected) {
      return Icons.link;
    }

    if (_isCsvLoaded) {
      return Icons.dataset_outlined;
    }

    return Icons.link_off;
  }

  String _getConnectionText() {
    if (_isDataTimeout) {
      return 'Veri Akışı Yok';
    }

    if (_isSerialConnected) {
      return 'COM Bağlı';
    }

    if (_isSimulationRunning) {
      return 'Veri Akıyor';
    }

    if (_connectionStatus == 'Bağlantı kesildi') {
      return 'Bağlantı Kesildi';
    }

    if (_isCsvLoaded) {
      return 'Hazır';
    }

    return 'Bağlı Değil';
  }

  Color _getConnectionColor() {
    if (_isDataTimeout) {
      return Colors.redAccent;
    }

    if (_connectionStatus == 'Bağlantı kesildi') {
      return Colors.redAccent;
    }

    if (_isSimulationRunning || _isSerialConnected) {
      return Colors.greenAccent;
    }

    if (_isCsvLoaded) {
      return const Color(0xFF38BDF8);
    }

    return Colors.white70;
  }

  void _toggleSerialConnection() {
    if (_isSerialConnected) {
      _disconnectSerial();
    } else {
      _connectSerial();
    }
  }

  void _connectSerial() {
    if (_selectedPort == null) {
      setState(() {
        _connectionStatus = 'COM port bulunamadı';
      });
      return;
    }

    if (_isSimulationRunning) {
      _stopSimulation();
    }

    final success = _serialService.connect(
      portName: _selectedPort!,
      baudRate: 9600,
      onDataReceived: _handleIncomingRawData,
    );

    setState(() {
      _isSerialConnected = success;
      _isDataTimeout = false;
      _connectionStatus =
          success ? '$_selectedPort bağlı' : '$_selectedPort bağlanamadı';
    });
  }

  void _disconnectSerial() {
    _serialService.disconnect();

    setState(() {
      _isSerialConnected = false;
      _isDataTimeout = false;
      _connectionStatus = 'Bağlantı kesildi';
    });

    Future.delayed(const Duration(seconds: 2), () {
      if (!mounted) return;

      if (!_isSimulationRunning && !_isSerialConnected && _isCsvLoaded) {
        setState(() {
          _connectionStatus = 'Veri seti hazır';
        });
      }
    });
  }

  void _toggleSimulation() {
    if (_isSimulationRunning) {
      _stopSimulation();
    } else {
      _startSimulation();
    }
  }

  void _startSimulation() {
    if (_isSerialConnected) {
      _disconnectSerial();
    }

    if (!_isCsvLoaded) {
      setState(() {
        _connectionStatus = 'Önce veri seti yüklenmeli';
      });
      return;
    }

    _csvSimulator.start(
      onData: _handleIncomingData,
      interval: const Duration(milliseconds: 500),
    );

    setState(() {
      _isSimulationRunning = true;
      _isDataTimeout = false;
      _totalEnergyKwh = 0.0;
      _connectionStatus = 'Veri seti simülasyonu çalışıyor';
    });
  }

  void _stopSimulation() {
    _csvSimulator.stop();

    setState(() {
      _isSimulationRunning = false;
      _isDataTimeout = false;
      _connectionStatus = 'Bağlantı kesildi';
    });

    Future.delayed(const Duration(seconds: 2), () {
      if (!mounted) return;

      if (!_isSimulationRunning && !_isSerialConnected && _isCsvLoaded) {
        setState(() {
          _connectionStatus = 'Veri seti hazır';
        });
      }
    });
  }

  Future<void> _toggleLogging() async {
    if (_isLogging) {
      await _stopLogging();
    } else {
      await _startLogging();
    }
  }

  Future<void> _startLogging() async {
    await _loggingService.startLogging();

    setState(() {
      _isLogging = true;
    });
  }

  Future<void> _stopLogging() async {
    await _loggingService.stopLogging();

    setState(() {
      _isLogging = false;
    });
  }

  Future<void> _openLogFolder() async {
    final userProfile = Platform.environment['USERPROFILE'];

    if (userProfile == null) {
      return;
    }

    final folderPath = '$userProfile\\Desktop\\AKS_Telemetri_Kayitlari';
    final folder = Directory(folderPath);

    if (!await folder.exists()) {
      await folder.create(recursive: true);
    }

    await Process.run('explorer', [folderPath]);
  }

  @override
  void dispose() {
    _connectionWatchTimer?.cancel();
    _csvSimulator.stop();
    _serialService.disconnect();
    _loggingService.stopLogging();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final warnings = _generateWarnings(_telemetryData);
    final statusText = _getStatusText(warnings);

    final statusColor = statusText == 'OK'
        ? const Color(0xFF38BDF8)
        : statusText == 'WARNING'
            ? getLevelColor(_getOverallWarningLevel())
            : statusText == 'BAĞLANTI YOK'
                ? Colors.redAccent
                : Colors.white70;

    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final bool narrowScreen = constraints.maxWidth < 1150;
            final bool shortScreen = constraints.maxHeight < 760;

            return SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    _buildHeaderBar(),
                    const SizedBox(height: 14),
                    if (narrowScreen)
                      Column(
                        children: [
                          SizedBox(
                            height: 440,
                            child: _buildDataGrid(),
                          ),
                          const SizedBox(height: 14),
                          SizedBox(
                            height: 360,
                            child: _buildStatusAndWarningArea(
                              statusText: statusText,
                              statusColor: statusColor,
                              warnings: warnings,
                            ),
                          ),
                        ],
                      )
                    else
                      SizedBox(
                        height: shortScreen ? 350 : 380,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 620,
                              child: _buildDataGrid(),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: _buildStatusAndWarningArea(
                                statusText: statusText,
                                statusColor: statusColor,
                                warnings: warnings,
                              ),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 14),
                    _buildEnergyRangePanel(),
                    const SizedBox(height: 14),
                    SizedBox(
                      height: shortScreen ? 240 : 280,
                      child: _buildChartsPanel(),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildHeaderBar() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: _panelDecoration(),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: const Color(0xFF0EA5E9).withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(
              Icons.directions_car_filled,
              color: Color(0xFF38BDF8),
              size: 26,
            ),
          ),
          const SizedBox(width: 14),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'AKS Telemetri Paneli',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                SizedBox(height: 3),
                Text(
                  'Elektrikli Araç Kontrol Sistemi • Gerçek Zamanlı Dashboard',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.white54,
                  ),
                ),
              ],
            ),
          ),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 85,
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: _selectedPort,
                  hint: const Text('Yok'),
                  items: _availablePorts.map((port) {
                    return DropdownMenuItem<String>(
                      value: port,
                      child: Text(port),
                    );
                  }).toList(),
                  onChanged: _isSerialConnected
                      ? null
                      : (value) {
                          setState(() {
                            _selectedPort = value;
                          });
                        },
                ),
              ),
              _smallButton(
                text: _isSerialConnected ? 'Bağlantıyı Kes' : 'Bağlan',
                icon: _isSerialConnected ? Icons.link_off : Icons.link,
                onPressed: _toggleSerialConnection,
              ),
              _smallButton(
                text: _isLogging ? 'Kaydı Durdur' : 'Kaydı Başlat',
                icon:
                    _isLogging ? Icons.stop_circle : Icons.fiber_manual_record,
                onPressed: _toggleLogging,
              ),
              _smallButton(
                text: 'Klasör',
                icon: Icons.folder_open,
                onPressed: _openLogFolder,
              ),
              _connectionChip(),
              _primaryStartButton(),
            ],
          ),
        ],
      ),
    );
  }

  Widget _primaryStartButton() {
    return SizedBox(
      height: 42,
      child: ElevatedButton.icon(
        onPressed: _toggleSimulation,
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF0EA5E9),
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        icon: Icon(
          _isSimulationRunning ? Icons.stop_circle : Icons.play_circle,
          size: 18,
        ),
        label: Text(
          _isSimulationRunning ? 'Durdur' : 'Başlat',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  Widget _connectionChip() {
    Color indicatorColor;
    Color backgroundColor;
    Color borderColor;

    if (_connectionStatus == 'Bağlantı kesildi') {
      indicatorColor = Colors.redAccent;
      backgroundColor = Colors.red.withValues(alpha: 0.15);
      borderColor = Colors.red;
    } else if (_isSimulationRunning || _isSerialConnected) {
      indicatorColor = Colors.greenAccent;
      backgroundColor = Colors.green.withValues(alpha: 0.15);
      borderColor = Colors.green;
    } else if (_isCsvLoaded) {
      indicatorColor = const Color(0xFF38BDF8);
      backgroundColor = const Color(0xFF38BDF8).withValues(alpha: 0.15);
      borderColor = const Color(0xFF38BDF8);
    } else {
      indicatorColor = Colors.redAccent;
      backgroundColor = Colors.red.withValues(alpha: 0.15);
      borderColor = Colors.red;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: borderColor.withValues(alpha: 0.8)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              color: indicatorColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _connectionStatus,
            style: TextStyle(
              color: indicatorColor,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _smallButton({
    required String text,
    required IconData icon,
    required VoidCallback? onPressed,
  }) {
    return SizedBox(
      height: 38,
      child: ElevatedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 16),
        label: Text(
          text,
          overflow: TextOverflow.ellipsis,
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF0B1020),
          foregroundColor: const Color(0xFFC4B5FD),
          disabledForegroundColor: Colors.white30,
          disabledBackgroundColor: const Color(0xFF0B1020),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
    );
  }

  Widget _buildDataGrid() {
    final voltageLevel = _getVoltageLevel(_telemetryData.voltage);
    final currentLevel = _getCurrentLevel(_telemetryData.current);
    final temperatureLevel = _getTemperatureLevel(_telemetryData.temperature);
    final motorSpeedLevel = _getMotorSpeedLevel(_telemetryData.motorSpeedRpm);
    final socLevel = _getSocLevel(_telemetryData.groundTruthSoc);

    return Column(
      children: [
        Expanded(
          child: Row(
            children: [
              Expanded(
                child: _buildDataCard(
                  title: 'Gerilim',
                  value: _telemetryData.voltage.toStringAsFixed(2),
                  unit: 'V',
                  icon: Icons.bolt,
                  level: voltageLevel,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _buildDataCard(
                  title: 'Akım',
                  value: _telemetryData.current.toStringAsFixed(2),
                  unit: 'A',
                  icon: Icons.electric_meter,
                  level: currentLevel,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: Row(
            children: [
              Expanded(
                child: _buildDataCard(
                  title: 'Sıcaklık',
                  value: _telemetryData.temperature.toStringAsFixed(2),
                  unit: '°C',
                  icon: Icons.thermostat,
                  level: temperatureLevel,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _buildDataCard(
                  title: 'Motor Hızı',
                  value: _telemetryData.motorSpeedRpm.toStringAsFixed(0),
                  unit: 'RPM',
                  icon: Icons.speed,
                  level: motorSpeedLevel,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: _buildDataCard(
            title: 'SOC',
            value: '%${_boundedSoc(_telemetryData.groundTruthSoc).toStringAsFixed(1)}',
            unit: '',
            icon: Icons.battery_full,
            level: socLevel,
          ),
        ),
      ],
    );
  }

  Widget _buildDataCard({
    required String title,
    required String value,
    required String unit,
    required IconData icon,
    required SensorLevel level,
  }) {
    final levelColor = getLevelColor(level);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: _panelDecoration(),
      child: Row(
        children: [
          BlinkingStatusIcon(
            icon: icon,
            level: level,
            size: 28,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Colors.white60,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Flexible(
                      child: Text(
                        value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          color: levelColor,
                        ),
                      ),
                    ),
                    if (unit.isNotEmpty) ...[
                      const SizedBox(width: 5),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          unit,
                          style: const TextStyle(
                            fontSize: 13,
                            color: Colors.white54,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusAndWarningArea({
    required String statusText,
    required Color statusColor,
    required List<String> warnings,
  }) {
    return Column(
      children: [
        _buildStatusPanel(
          statusText: statusText,
          statusColor: statusColor,
        ),
        const SizedBox(height: 12),
        Expanded(
          child: _buildWarningsPanel(warnings),
        ),
      ],
    );
  }

  Widget _buildStatusPanel({
    required String statusText,
    required Color statusColor,
  }) {
    final sourceText = _isSerialConnected
        ? _selectedPort ?? 'COM Port'
        : _isSimulationRunning
            ? 'CSV Veri Seti'
            : _isCsvLoaded
                ? 'Veri Seti Hazır'
                : 'Bekleniyor';

    final lastPacketTime = !_hasReceivedData
        ? '--:--:--'
        : '${_telemetryData.timestamp.hour.toString().padLeft(2, '0')}:'
            '${_telemetryData.timestamp.minute.toString().padLeft(2, '0')}:'
            '${_telemetryData.timestamp.second.toString().padLeft(2, '0')}';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: _panelDecoration(),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _statusInfoItem(
                  title: 'Sistem Durumu',
                  value: statusText,
                  valueColor: statusColor,
                  icon: Icons.monitor_heart_outlined,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _statusInfoItem(
                  title: 'Bağlantı',
                  value: _getConnectionText(),
                  valueColor: _getConnectionColor(),
                  icon: _getConnectionIcon(),
                  iconColor: _getConnectionColor(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _statusInfoItem(
                  title: 'Son Paket',
                  value: lastPacketTime,
                  valueColor: Colors.white,
                  icon: Icons.access_time,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _statusInfoItem(
                  title: 'Veri Kaynağı',
                  value: sourceText,
                  valueColor: Colors.white,
                  icon: Icons.dataset_outlined,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statusInfoItem({
    required String title,
    required String value,
    required Color valueColor,
    required IconData icon,
    Color? iconColor,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF050816),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        children: [
          Icon(
            icon,
            size: 20,
            color: iconColor ?? Colors.white70,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Colors.white54,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: valueColor,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWarningsPanel(List<String> warnings) {
    final warningLevel = _getOverallWarningLevel();
    final bool hasWarning = warnings.isNotEmpty;

    final panelColor =
        !hasWarning ? const Color(0xFF38BDF8) : getLevelColor(warningLevel);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: _panelDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.warning_amber_rounded,
                color: panelColor,
              ),
              const SizedBox(width: 8),
              const Text(
                'Uyarı Paneli',
                style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: panelColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Text(
                  '${warnings.length} uyarı',
                  style: TextStyle(
                    color: panelColor,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (warnings.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: panelColor.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: panelColor.withValues(alpha: 0.35),
                ),
              ),
              child: Text(
                'Aktif uyarı bulunmuyor.',
                style: TextStyle(
                  color: panelColor,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            )
          else
            Expanded(
              child: ListView.builder(
                padding: EdgeInsets.zero,
                itemCount: warnings.length,
                itemBuilder: (context, index) {
                  final warning = warnings[index];
                  final lowerWarning = warning.toLowerCase();

                  final itemColor = lowerWarning.contains('riskli')
                      ? Colors.redAccent
                      : Colors.amber;

                  return Container(
                    margin: const EdgeInsets.only(bottom: 7),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 9,
                    ),
                    decoration: BoxDecoration(
                      color: itemColor.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: itemColor.withValues(alpha: 0.50),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          lowerWarning.contains('riskli')
                              ? Icons.error_outline
                              : Icons.warning_amber_rounded,
                          color: itemColor,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            warning,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: itemColor,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEnergyRangePanel() {
    final instantPowerKw =
        _hasReceivedData ? _calculateInstantPowerKw(_telemetryData) : 0.0;

    final estimatedRangeKm =
        _hasReceivedData ? _calculateEstimatedRangeKm(_telemetryData) : 0.0;

    final calculatedLevel =
        _hasReceivedData ? SensorLevel.normal : SensorLevel.waiting;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: _panelDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(
                Icons.energy_savings_leaf,
                color: Color(0xFF38BDF8),
                size: 18,
              ),
              SizedBox(width: 8),
              Text(
                'Enerji ve Menzil Bilgileri',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 115,
            child: Row(
              children: [
                Expanded(
                  child: _buildMiniInfoCard(
                    title: 'Anlık Güç',
                    value: instantPowerKw.toStringAsFixed(2),
                    unit: 'kW',
                    subtitle: 'Volt × Amper hesabına göre',
                    icon: Icons.flash_on,
                    level: calculatedLevel,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildMiniInfoCard(
                    title: 'Toplam Enerji Tüketimi',
                    value: _totalEnergyKwh.toStringAsFixed(3),
                    unit: 'kWh',
                    subtitle: 'Zamana bağlı birikimli tüketim',
                    icon: Icons.battery_charging_full,
                    level: calculatedLevel,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildMiniInfoCard(
                    title: 'Tahmini Kalan Yol',
                    value: estimatedRangeKm.toStringAsFixed(1),
                    unit: 'km',
                    subtitle: 'SOC ve ortalama tüketime göre',
                    icon: Icons.route,
                    level: calculatedLevel,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMiniInfoCard({
    required String title,
    required String value,
    required String unit,
    required String subtitle,
    required IconData icon,
    required SensorLevel level,
  }) {
    final levelColor = getLevelColor(level);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF050816),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: levelColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: levelColor.withValues(alpha: 0.55),
              ),
            ),
            child: Icon(
              icon,
              color: levelColor,
              size: 22,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.white60,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 5),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Flexible(
                      child: Text(
                        value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 21,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Text(
                        unit,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.white54,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 9,
                    color: Colors.white38,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChartsPanel() {
    return Row(
      children: [
        Expanded(
          child: _buildLineChartCard(
            title: 'Gerilim Grafiği',
            spots: _voltagePoints,
            maxY: 5,
            unit: 'V',
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: _buildLineChartCard(
            title: 'SOC Grafiği',
            spots: _groundTruthSocPoints,
            maxY: 110,
            unit: '%',
          ),
        ),
      ],
    );
  }

  Widget _buildLineChartCard({
    required String title,
    required List<FlSpot> spots,
    required double maxY,
    required String unit,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _panelDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.show_chart,
                size: 18,
                color: Color(0xFF38BDF8),
              ),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              Text(
                unit,
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.white38,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: spots.isEmpty
                ? const Center(
                    child: Text(
                      'Grafik için veri bekleniyor...',
                      style: TextStyle(color: Colors.white70),
                    ),
                  )
                : LineChart(
                    LineChartData(
                      minX: spots.first.x,
                      maxX: spots.last.x,
                      minY: 0,
                      maxY: maxY,
                      gridData: FlGridData(
                        show: true,
                        getDrawingHorizontalLine: (value) {
                          return FlLine(
                            color: Colors.white.withValues(alpha: 0.08),
                            strokeWidth: 1,
                          );
                        },
                        getDrawingVerticalLine: (value) {
                          return FlLine(
                            color: Colors.white.withValues(alpha: 0.06),
                            strokeWidth: 1,
                          );
                        },
                      ),
                      borderData: FlBorderData(
                        show: true,
                        border: Border.all(color: Colors.white10),
                      ),
                      titlesData: FlTitlesData(
                        topTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                        rightTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                        bottomTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                        leftTitles: AxisTitles(
                          axisNameWidget: Text(unit),
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 42,
                            interval: maxY > 100 ? 25 : 1,
                          ),
                        ),
                      ),
                      lineBarsData: [
                        LineChartBarData(
                          spots: spots,
                          isCurved: true,
                          color: const Color(0xFF22D3EE),
                          barWidth: 3,
                          dotData: const FlDotData(show: false),
                          belowBarData: BarAreaData(
                            show: true,
                            color: const Color(0xFF22D3EE)
                                .withValues(alpha: 0.16),
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  BoxDecoration _panelDecoration() {
    return BoxDecoration(
      color: const Color(0xFF0F172A),
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: Colors.white10),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.28),
          blurRadius: 12,
          offset: const Offset(0, 5),
        ),
      ],
    );
  }
}

class BlinkingStatusIcon extends StatefulWidget {
  final IconData icon;
  final SensorLevel level;
  final double size;

  const BlinkingStatusIcon({
    super.key,
    required this.icon,
    required this.level,
    this.size = 28,
  });

  @override
  State<BlinkingStatusIcon> createState() => _BlinkingStatusIconState();
}

class _BlinkingStatusIconState extends State<BlinkingStatusIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacityAnimation;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );

    _opacityAnimation = Tween<double>(
      begin: 0.35,
      end: 1.0,
    ).animate(_controller);

    _updateAnimation();
  }

  @override
  void didUpdateWidget(covariant BlinkingStatusIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateAnimation();
  }

  void _updateAnimation() {
    if (widget.level == SensorLevel.critical ||
        widget.level == SensorLevel.risky) {
      _controller.repeat(reverse: true);
    } else {
      _controller.stop();
      _controller.value = 1.0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final iconColor = getLevelColor(widget.level);

    if (widget.level == SensorLevel.critical ||
        widget.level == SensorLevel.risky) {
      return FadeTransition(
        opacity: _opacityAnimation,
        child: Icon(
          widget.icon,
          color: iconColor,
          size: widget.size,
        ),
      );
    }

    return Icon(
      widget.icon,
      color: iconColor,
      size: widget.size,
    );
  }
}