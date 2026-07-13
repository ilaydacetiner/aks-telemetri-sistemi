import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

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

class ExpectedDecisionResults {
  final String firstLabel;
  final String firstValue;

  final String secondLabel;
  final String secondValue;

  final String thirdLabel;
  final String thirdValue;

  const ExpectedDecisionResults({
    required this.firstLabel,
    required this.firstValue,
    required this.secondLabel,
    required this.secondValue,
    required this.thirdLabel,
    required this.thirdValue,
  });
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
  final List<FlSpot> _speedPoints = [];
  final List<FlSpot> _temperaturePoints = [];

  double _chartIndex = 0;
  double _totalEnergyKwh = 0.0;

  static const int _seriesCellCount = 96;
  static const double _batteryCapacityKwh = 5.0;
  static const double _averageConsumptionKwhPer100Km = 15.0;
  static const double _sampleIntervalHours = 1 / 3600;

  static const double _wheelRadiusMeter = 0.30;
  static const double _gearRatio = 10.0;

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
    final speedKmh = _calculateVehicleSpeedKmh(data);

    setState(() {
      _hasReceivedData = true;
      _isDataTimeout = false;
      _lastDataReceivedAt = DateTime.now();
      _telemetryData = data;
      _totalEnergyKwh += energyIncrementKwh;

      _chartIndex++;

      _voltagePoints.add(FlSpot(_chartIndex, data.voltage));
      _groundTruthSocPoints.add(
        FlSpot(_chartIndex, _boundedSoc(data.groundTruthSoc)),
      );
      _speedPoints.add(FlSpot(_chartIndex, speedKmh));
      _temperaturePoints.add(FlSpot(_chartIndex, data.temperature));

      if (_voltagePoints.length > 20) {
        _voltagePoints.removeAt(0);
      }

      if (_groundTruthSocPoints.length > 20) {
        _groundTruthSocPoints.removeAt(0);
      }

      if (_speedPoints.length > 20) {
        _speedPoints.removeAt(0);
      }

      if (_temperaturePoints.length > 20) {
        _temperaturePoints.removeAt(0);
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
      return 'UYARI';
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

  double _calculateVehicleSpeedKmh(TelemetryData data) {
    final wheelRpm = data.motorSpeedRpm / _gearRatio;
    final wheelCircumferenceMeter = 2 * math.pi * _wheelRadiusMeter;

    return wheelRpm * wheelCircumferenceMeter * 60 / 1000;
  }

  double _calculateEfficiencyWhPerKm(TelemetryData data) {
    final speedKmh = _calculateVehicleSpeedKmh(data);

    if (speedKmh <= 1) {
      return 0;
    }

    final instantPowerW = _calculateInstantPowerKw(data) * 1000;
    return instantPowerW / speedKmh;
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

  int _calculateVehicleHealthScore() {
    if (!_hasReceivedData) {
      return 0;
    }

    double riskPenalty = 0;

    riskPenalty += _getRiskPenalty(
      level: _getMotorSpeedLevel(_telemetryData.motorSpeedRpm),
      weight: 35,
    );

    riskPenalty += _getRiskPenalty(
      level: _getCurrentLevel(_telemetryData.current),
      weight: 30,
    );

    riskPenalty += _getRiskPenalty(
      level: _getTemperatureLevel(_telemetryData.temperature),
      weight: 20,
    );

    riskPenalty += _getRiskPenalty(
      level: _getVoltageLevel(_telemetryData.voltage),
      weight: 10,
    );

    riskPenalty += _getRiskPenalty(
      level: _getSocLevel(_telemetryData.groundTruthSoc),
      weight: 5,
    );

    if (_isDataTimeout) {
      riskPenalty += 20;
    }

    final score = 100 - riskPenalty;
    return score.clamp(0, 100).round();
  }

  double _getRiskPenalty({
    required SensorLevel level,
    required double weight,
  }) {
    switch (level) {
      case SensorLevel.waiting:
        return 0;
      case SensorLevel.normal:
        return 0;
      case SensorLevel.critical:
        return weight * 0.45;
      case SensorLevel.risky:
        return weight;
    }
  }

  String _getVehicleHealthStatus(int score) {
    if (!_hasReceivedData) {
      return 'Bekleniyor';
    }

    if (score >= 75) {
      return 'Güvenli';
    }

    if (score >= 50) {
      return 'Dikkat';
    }

    return 'Riskli';
  }

  Color _getVehicleHealthColor(int score) {
    if (!_hasReceivedData) {
      return Colors.white70;
    }

    if (score >= 75) {
      return const Color(0xFF38BDF8);
    }

    if (score >= 50) {
      return Colors.amber;
    }

    return Colors.redAccent;
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

String _getSmartDecisionRecommendation(List<String> warnings) {
  if (!_hasReceivedData) {
    return 'Veri bekleniyor. Sistem değerlendirmesi için telemetri akışı başlatılmalıdır.';
  }

  if (_isDataTimeout) {
    return 'Veri akışı kesildi. COM bağlantısı, LoRa haberleşmesi veya simülasyon durumu kontrol edilmelidir.';
  }

  if (warnings.isEmpty) {
    return 'Batarya ve araç parametreleri güvenli bölgede. Normal sürüşe devam edebilirsiniz.';
  }

  final warningText = warnings.join(' ').toLowerCase();
  final List<String> recommendations = [];

  if (warningText.contains('riskli akim')) {
    recommendations.add(
      'Akımı yaklaşık %18 azaltmak için ani hızlanmadan kaçının ve sürüş yükünü düşürün.',
    );
  } else if (warningText.contains('kritik akim')) {
    recommendations.add(
      'Akımı yaklaşık %12 azaltmak için sürüş yükünü kontrollü şekilde düşürün.',
    );
  }

  if (warningText.contains('riskli motor hizi')) {
    recommendations.add(
      'Motor hızını yaklaşık %15 düşürün ve yüksek devirli kullanımdan kaçının.',
    );
  } else if (warningText.contains('kritik motor hizi')) {
    recommendations.add(
      'Motor hızını yaklaşık %10 düşürün ve motor yükünü azaltın.',
    );
  }

  if (warningText.contains('riskli sicaklik')) {
    recommendations.add(
      'Sıcaklığı düşürmek için aracı güvenli noktaya alın ve sistemi soğumaya bırakın.',
    );
  } else if (warningText.contains('kritik sicaklik')) {
    recommendations.add(
      'Sıcaklığı yaklaşık %8 azaltmak için hızı düşürün ve termal durumu takip edin.',
    );
  }

  if (warningText.contains('riskli gerilim')) {
    recommendations.add(
      'Gerilim seviyesi güvenli aralık dışında. Batarya bağlantısı ve hücre gerilimini kontrol edin.',
    );
  } else if (warningText.contains('kritik gerilim')) {
    recommendations.add(
      'Gerilim dengesini korumak için batarya yükünü azaltın ve yüksek güç tüketiminden kaçının.',
    );
  }

  if (warningText.contains('riskli soc')) {
    recommendations.add(
      'SOC seviyesi riskli bölgede. Enerji tüketimini azaltın ve kalan menzili kontrol edin.',
    );
  } else if (warningText.contains('kritik soc')) {
    recommendations.add(
      'Batarya seviyesini korumak için enerji tüketimini yaklaşık %10 azaltın.',
    );
  }

  if (recommendations.isEmpty) {
    return 'Sistemde uyarı algılandı. İlgili araç parametrelerini düşürerek kontrollü sürüşe devam ediniz.';
  }

  return recommendations.join(' ');
}

  List<String> _getDecisionReasons(List<String> warnings) {
    if (!_hasReceivedData) {
      return ['Telemetri verisi bekleniyor.'];
    }

    if (_isDataTimeout) {
      return ['Telemetri veri akışı kesildi.'];
    }

    if (warnings.isEmpty) {
      return ['Tüm parametreler güvenli çalışma aralığında.'];
    }

    return warnings.take(2).toList();
  }

  ExpectedDecisionResults _getExpectedResults(List<String> warnings) {
  if (!_hasReceivedData) {
    return const ExpectedDecisionResults(
      firstLabel: 'Veri',
      firstValue: '-',
      secondLabel: 'Sistem',
      secondValue: '-',
      thirdLabel: 'Sağlık skoru',
      thirdValue: '-',
    );
  }

  if (_isDataTimeout) {
    return const ExpectedDecisionResults(
      firstLabel: 'Veri akışı',
      firstValue: 'Kontrol',
      secondLabel: 'Bağlantı',
      secondValue: 'Yenile',
      thirdLabel: 'Sağlık skoru',
      thirdValue: '↓ %20',
    );
  }

  if (warnings.isEmpty) {
    return const ExpectedDecisionResults(
      firstLabel: 'Enerji tüketimi',
      firstValue: 'Normal',
      secondLabel: 'Motor yükü',
      secondValue: 'Normal',
      thirdLabel: 'Sağlık skoru',
      thirdValue: 'Korunur',
    );
  }

  final warningText = warnings.join(' ').toLowerCase();
  final currentHealth = _calculateVehicleHealthScore();

  final int healthIncrease = warningText.contains('riskli') ? 12 : 7;
  final improvedHealth = (currentHealth + healthIncrease).clamp(0, 100).round();

  final List<Map<String, String>> expectedItems = [];

  if (warningText.contains('riskli akim')) {
    expectedItems.add({
      'label': 'Akım seviyesi',
      'value': '↓ %18',
    });
  } else if (warningText.contains('kritik akim')) {
    expectedItems.add({
      'label': 'Akım seviyesi',
      'value': '↓ %12',
    });
  }

  if (warningText.contains('riskli motor hizi')) {
    expectedItems.add({
      'label': 'Motor hızı',
      'value': '↓ %15',
    });
  } else if (warningText.contains('kritik motor hizi')) {
    expectedItems.add({
      'label': 'Motor hızı',
      'value': '↓ %10',
    });
  }

  if (warningText.contains('riskli sicaklik')) {
    expectedItems.add({
      'label': 'Sıcaklık',
      'value': '↓ %12',
    });
  } else if (warningText.contains('kritik sicaklik')) {
    expectedItems.add({
      'label': 'Sıcaklık',
      'value': '↓ %8',
    });
  }

  if (warningText.contains('riskli gerilim')) {
    expectedItems.add({
      'label': 'Gerilim',
      'value': 'Kontrol',
    });
  } else if (warningText.contains('kritik gerilim')) {
    expectedItems.add({
      'label': 'Batarya yükü',
      'value': '↓ %8',
    });
  }

  if (warningText.contains('riskli soc')) {
    expectedItems.add({
      'label': 'Enerji tüketimi',
      'value': '↓ %15',
    });
  } else if (warningText.contains('kritik soc')) {
    expectedItems.add({
      'label': 'Enerji tüketimi',
      'value': '↓ %10',
    });
  }

  while (expectedItems.length < 2) {
    expectedItems.add({
      'label': 'Risk seviyesi',
      'value': 'Azalır',
    });
  }

  return ExpectedDecisionResults(
    firstLabel: expectedItems[0]['label']!,
    firstValue: expectedItems[0]['value']!,
    secondLabel: expectedItems[1]['label']!,
    secondValue: expectedItems[1]['value']!,
    thirdLabel: 'Sağlık skoru',
    thirdValue: '$currentHealth → $improvedHealth',
  );
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
      interval: const Duration(seconds: 1),
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
                padding: const EdgeInsets.all(14),
                child: Column(
                  children: [
                    _buildHeaderBar(),
                    const SizedBox(height: 10),
                    _buildTopStatusRow(
                      statusText: statusText,
                      statusColor: statusColor,
                    ),
                    const SizedBox(height: 12),
                    if (narrowScreen)
                      Column(
                        children: [
                          SizedBox(
                            height: 660,
                            child: _buildLeftDashboardColumn(),
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            height: 660,
                            child: _buildRightDashboardColumn(
                              warnings: warnings,
                            ),
                          ),
                        ],
                      )
                    else
                      SizedBox(
                        height: shortScreen ? 660 : 700,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              flex: 10,
                              child: _buildLeftDashboardColumn(),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              flex: 12,
                              child: _buildRightDashboardColumn(
                                warnings: warnings,
                              ),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 12),
                    SizedBox(
                      height: shortScreen ? 500 : 560,
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

  Widget _buildLeftDashboardColumn() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 7,
          child: _buildDataGrid(),
        ),
        const SizedBox(height: 12),
        Expanded(
          flex: 3,
          child: _buildEnergyRangePanel(),
        ),
      ],
    );
  }

  Widget _buildRightDashboardColumn({
    required List<String> warnings,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 3,
          child: _buildWarningsPanel(warnings),
        ),
        const SizedBox(height: 10),
        Expanded(
          flex: 4,
          child: _buildSmartDecisionSupportPanel(warnings),
        ),
        const SizedBox(height: 10),
        Expanded(
          flex: 3,
          child: _buildVehicleHealthPanel(),
        ),
      ],
    );
  }

  Widget _buildTopStatusRow({
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
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: _panelDecoration(),
      child: Row(
        children: [
          Expanded(
            child: _statusInfoItem(
              title: 'Sistem Durumu',
              value: statusText,
              valueColor: statusColor,
              icon: Icons.monitor_heart_outlined,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _statusInfoItem(
              title: 'Bağlantı',
              value: _getConnectionText(),
              valueColor: _getConnectionColor(),
              icon: _getConnectionIcon(),
              iconColor: _getConnectionColor(),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _statusInfoItem(
              title: 'Son Paket',
              value: lastPacketTime,
              valueColor: Colors.white,
              icon: Icons.access_time,
            ),
          ),
          const SizedBox(width: 10),
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
    );
  }

  Widget _buildHeaderBar() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: _panelDecoration(),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: const Color(0xFF0EA5E9).withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(13),
            ),
            child: const Icon(
              Icons.directions_car_filled,
              color: Color(0xFF38BDF8),
              size: 24,
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
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'Elektrikli Araç Kontrol Sistemi • Gerçek Zamanlı Dashboard',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.white54,
                  ),
                ),
              ],
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 80,
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
      height: 38,
      child: ElevatedButton.icon(
        onPressed: _toggleSimulation,
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF0EA5E9),
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(13),
          ),
        ),
        icon: Icon(
          _isSimulationRunning ? Icons.stop_circle : Icons.play_circle,
          size: 17,
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
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 11),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: borderColor.withValues(alpha: 0.8)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
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
      height: 36,
      child: ElevatedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 15),
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
            borderRadius: BorderRadius.circular(13),
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
              const SizedBox(width: 9),
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
        const SizedBox(height: 9),
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
              const SizedBox(width: 9),
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
        const SizedBox(height: 9),
        Expanded(
          child: _buildDataCard(
            title: 'SOC',
            value:
                '%${_boundedSoc(_telemetryData.groundTruthSoc).toStringAsFixed(1)}',
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
    padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 18),
    decoration: _panelDecoration(),
    child: Row(
      children: [
        BlinkingStatusIcon(
          icon: icon,
          level: level,
          size: 32,
        ),
        const SizedBox(width: 22),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 14,
                  color: Colors.white60,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
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
                    const SizedBox(width: 8),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        unit,
                        style: const TextStyle(
                          fontSize: 14,
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

  Widget _statusInfoItem({
    required String title,
    required String value,
    required Color valueColor,
    required IconData icon,
    Color? iconColor,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFF050816),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        children: [
          Icon(
            icon,
            size: 17,
            color: iconColor ?? Colors.white70,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 9,
                    color: Colors.white54,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
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
      padding: const EdgeInsets.all(13),
      decoration: _panelDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.warning_amber_rounded,
                color: panelColor,
                size: 20,
              ),
              const SizedBox(width: 8),
              const Text(
                'Uyarı Paneli',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: panelColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(17),
                ),
                child: Text(
                  '${warnings.length} uyarı',
                  style: TextStyle(
                    color: panelColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (warnings.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: panelColor.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(13),
                border: Border.all(
                  color: panelColor.withValues(alpha: 0.35),
                ),
              ),
              child: Text(
                'Aktif uyarı bulunmuyor.',
                style: TextStyle(
                  color: panelColor,
                  fontSize: 13,
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
                      horizontal: 11,
                      vertical: 8,
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
                          size: 17,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            warning,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: itemColor,
                              fontSize: 12,
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

  Widget _buildSmartDecisionSupportPanel(List<String> warnings) {
    final recommendation = _getSmartDecisionRecommendation(warnings);

    final recommendationColor = warnings.isEmpty
        ? const Color(0xFF22C55E)
        : getLevelColor(_getOverallWarningLevel());

    final reasons = _getDecisionReasons(warnings);
    final results = _getExpectedResults(warnings);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: const Color(0xFF07111F),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.20),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(
                Icons.auto_awesome,
                color: Colors.white70,
                size: 18,
              ),
              SizedBox(width: 8),
              Text(
                'Akıllı Karar Destek Önerisi',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF050816),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Sebep',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 5),
                  ...reasons.map(
                    (reason) => Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '• ',
                            style: TextStyle(
                              color: Colors.white60,
                              fontSize: 12,
                            ),
                          ),
                          Expanded(
                            child: Text(
                              reason,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const Spacer(),
                  const Text(
                    'Öneri',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        warnings.isEmpty ? Icons.check_circle : Icons.south,
                        color: recommendationColor,
                        size: 17,
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          recommendation,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: recommendationColor,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            height: 1.22,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'Beklenen Sonuç:',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              _expectedResultCard(
                icon: Icons.tune,
                label: results.firstLabel,
                value: results.firstValue,
              ),
              const SizedBox(width: 8),
              _expectedResultCard(
                icon: Icons.bolt,
                label: results.secondLabel,
                value: results.secondValue,
              ),
              const SizedBox(width: 8),
              _expectedResultCard(
                icon: Icons.trending_up,
                label: results.thirdLabel,
                value: results.thirdValue,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _expectedResultCard({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
        decoration: BoxDecoration(
          color: const Color(0xFF050816),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white10),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              color: Colors.white60,
              size: 15,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                  height: 1.05,
                ),
              ),
            ),
            const SizedBox(width: 4),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEnergyRangePanel() {
    final instantPowerKw =
        _hasReceivedData ? _calculateInstantPowerKw(_telemetryData) : 0.0;

    final estimatedRangeKm =
        _hasReceivedData ? _calculateEstimatedRangeKm(_telemetryData) : 0.0;

    final efficiencyWhPerKm =
        _hasReceivedData ? _calculateEfficiencyWhPerKm(_telemetryData) : 0.0;

    final calculatedLevel =
        _hasReceivedData ? SensorLevel.normal : SensorLevel.waiting;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: _panelDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(
                Icons.energy_savings_leaf,
                color: Color(0xFF38BDF8),
                size: 17,
              ),
              SizedBox(width: 7),
              Text(
                'Enerji ve Menzil Bilgileri',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
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
                const SizedBox(width: 9),
                Expanded(
                  child: _buildMiniInfoCard(
                    title: 'Enerji Verimliliği',
                    value: efficiencyWhPerKm.toStringAsFixed(1),
                    unit: 'Wh/km',
                    subtitle: 'Anlık güç / tahmini hız',
                    icon: Icons.eco,
                    level: calculatedLevel,
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: _buildMiniInfoCard(
                    title: 'Tahmini Kalan Yol',
                    value: estimatedRangeKm.toStringAsFixed(1),
                    unit: 'km',
                    subtitle: 'SOC ve tüketime göre',
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

  Widget _buildVehicleHealthPanel() {
    final healthScore = _calculateVehicleHealthScore();
    final healthStatus = _getVehicleHealthStatus(healthScore);
    final healthColor = _getVehicleHealthColor(healthScore);

    String description;

    if (!_hasReceivedData) {
      description =
          'Telemetri verisi bekleniyor. Sağlık skoru veri akışı başladığında hesaplanacaktır.';
    } else if (healthScore >= 75) {
      description =
          'Sistem genel olarak güvenli bölgede çalışmaktadır. Parametreler kabul edilebilir aralıktadır.';
    } else if (healthScore >= 50) {
      description =
          'Bazı parametreler kritik sınıra yaklaşmıştır. Sistem takip edilmelidir.';
    } else {
      description =
          'Araç riskli bölgede çalışmaktadır. Kritik parametreler kontrol edilmelidir.';
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(11),
      decoration: _panelDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.health_and_safety,
                color: healthColor,
                size: 17,
              ),
              const SizedBox(width: 7),
              Text(
                'Araç Sağlık Skoru',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: healthColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF050816),
                borderRadius: BorderRadius.circular(17),
                border: Border.all(
                  color: healthColor.withValues(alpha: 0.35),
                ),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 78,
                    height: 78,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        SizedBox(
                          width: 78,
                          height: 78,
                          child: CircularProgressIndicator(
                            value: healthScore / 100,
                            strokeWidth: 8,
                            backgroundColor:
                                healthColor.withValues(alpha: 0.18),
                            valueColor: AlwaysStoppedAnimation<Color>(
                              healthColor,
                            ),
                            strokeCap: StrokeCap.round,
                          ),
                        ),
                        Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              '$healthScore',
                              style: const TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                            const Text(
                              '/100',
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.white54,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Durum: $healthStatus',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: healthColor,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 10.5,
                            height: 1.20,
                            color: Colors.white70,
                          ),
                        ),
                        const Spacer(),
                        Row(
                          children: [
                            _healthLegendItem(
                              label: 'Güvenli',
                              range: '75-100',
                              color: const Color(0xFF38BDF8),
                            ),
                            const SizedBox(width: 5),
                            _healthLegendItem(
                              label: 'Dikkat',
                              range: '50-74',
                              color: Colors.amber,
                            ),
                            const SizedBox(width: 5),
                            _healthLegendItem(
                              label: 'Riskli',
                              range: '0-49',
                              color: Colors.redAccent,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  _buildVehicleCarIcon(healthColor),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVehicleCarIcon(Color color) {
    return Container(
      width: 62,
      height: 62,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: 0.10),
        border: Border.all(
          color: color.withValues(alpha: 0.35),
          width: 1.3,
        ),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.18),
            blurRadius: 16,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Center(
        child: Icon(
          Icons.electric_car_rounded,
          size: 34,
          color: color.withValues(alpha: 0.85),
        ),
      ),
    );
  }

  Widget _healthLegendItem({
    required String label,
    required String range,
    required Color color,
  }) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
            color: color.withValues(alpha: 0.35),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: 8,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 1),
            Text(
              range,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 6.5,
              ),
            ),
          ],
        ),
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
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
    decoration: BoxDecoration(
      color: const Color(0xFF050816),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: Colors.white10),
    ),
    child: Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: levelColor.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: levelColor.withValues(alpha: 0.55),
            ),
          ),
          child: Icon(
            icon,
            color: levelColor,
            size: 20,
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11,
                  color: Colors.white60,
                  fontWeight: FontWeight.w700,
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
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
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
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 8.5,
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
    return Column(
      children: [
        Expanded(
          child: Row(
            children: [
              Expanded(
                child: _buildLineChartCard(
                  title: 'Gerilim Grafiği',
                  spots: _voltagePoints,
                  maxY: 5,
                  unit: 'V',
                  icon: Icons.bolt,
                  lineColor: const Color(0xFF22D3EE),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildLineChartCard(
                  title: 'SOC Grafiği',
                  spots: _groundTruthSocPoints,
                  maxY: 110,
                  unit: '%',
                  icon: Icons.battery_full,
                  lineColor: const Color(0xFF4ADE80),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: Row(
            children: [
              Expanded(
                child: _buildLineChartCard(
                  title: 'Araç Hızı Grafiği',
                  spots: _speedPoints,
                  maxY: 120,
                  unit: 'km/h',
                  icon: Icons.speed,
                  lineColor: const Color(0xFF60A5FA),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildLineChartCard(
                  title: 'Sıcaklık Grafiği',
                  spots: _temperaturePoints,
                  maxY: 60,
                  unit: '°C',
                  icon: Icons.thermostat,
                  lineColor: Colors.redAccent,
                ),
              ),
            ],
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
    required IconData icon,
    required Color lineColor,
  }) {
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: _panelDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                icon,
                size: 18,
                color: lineColor,
              ),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
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
          const SizedBox(height: 9),
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
                            interval: maxY >= 100
                                ? 25
                                : maxY >= 60
                                    ? 10
                                    : 1,
                          ),
                        ),
                      ),
                      lineBarsData: [
                        LineChartBarData(
                          spots: spots,
                          isCurved: true,
                          color: lineColor,
                          barWidth: 3,
                          dotData: const FlDotData(show: false),
                          belowBarData: BarAreaData(
                            show: true,
                            color: lineColor.withValues(alpha: 0.16),
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