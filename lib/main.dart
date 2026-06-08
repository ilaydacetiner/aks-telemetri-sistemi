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
        scaffoldBackgroundColor: const Color(0xFF101014),
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

  String _lastRawData = 'Henüz veri alınmadı.';
  String _connectionStatus = 'Veri seti bekleniyor';
  String _loggingStatus = 'Kapalı';
  String _logFilePath = '-';

  bool _isSimulationRunning = false;
  bool _isLogging = false;
  bool _isCsvLoaded = false;
  bool _hasReceivedData = false;
  bool _isSerialConnected = false;

  List<String> _availablePorts = [];
  String? _selectedPort;

  final List<FlSpot> _voltagePoints = [];
  final List<FlSpot> _groundTruthSocPoints = [];
  double _chartIndex = 0;

  @override
  void initState() {
    super.initState();
    _refreshPorts();
    _loadDataset();
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
      setState(() {
        _lastRawData = 'Parse edilemeyen veri: $rawData';
      });
      return;
    }

    await _handleIncomingData(parsedData);
  }

  Future<void> _handleIncomingData(TelemetryData data) async {
    final warnings = _generateWarnings(data);
    final status = _getStatusText(warnings);

    final rawData =
        'timeMs:${data.timeMs.toStringAsFixed(0)},'
        'voltage:${data.voltage.toStringAsFixed(2)},'
        'current:${data.current.toStringAsFixed(2)},'
        'temperature:${data.temperature.toStringAsFixed(2)},'
        'motorSpeedRpm:${data.motorSpeedRpm.toStringAsFixed(0)},'
        'hallCode:${data.hallCode},'
        'estimatedSoc:${data.estimatedSoc.toStringAsFixed(2)},'
        'groundTruthSoc:${data.groundTruthSoc.toStringAsFixed(2)},'
        'residual:${data.residual.toStringAsFixed(2)},'
        'faultLabel:${data.faultLabel},'
        'status:$status';

    setState(() {
      _hasReceivedData = true;
      _telemetryData = data;
      _lastRawData = rawData;

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

    if (warnings.isNotEmpty) {
      return 'WARNING';
    }

    return 'OK';
  }

  List<String> _generateWarnings(TelemetryData data) {
    final List<String> warnings = [];

    if (!_hasReceivedData) {
      return warnings;
    }

    if (data.voltage < 3.0) {
      warnings.add('Batarya gerilimi dusuk');
    }

    if (data.voltage > 4.2) {
      warnings.add('Batarya gerilimi yuksek');
    }

    if (data.current.abs() > 40) {
      warnings.add('Akim degeri yuksek');
    }

    if (data.temperature > 35) {
      warnings.add('Sicaklik yuksek');
    }

    if (data.motorSpeedRpm > 5000) {
      warnings.add('Motor hizi yuksek');
    }

    if (data.estimatedSoc < 20) {
      warnings.add('Tahmini SOC dusuk');
    }

    if (data.residual.abs() > 2.5) {
      warnings.add('SOC tahmin hatasi yuksek');
    }

    return warnings;
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
      _connectionStatus =
          success ? '$_selectedPort bağlı' : '$_selectedPort bağlanamadı';
    });
  }

  void _disconnectSerial() {
    _serialService.disconnect();

    setState(() {
      _isSerialConnected = false;
      _connectionStatus = 'COM bağlantısı kesildi';
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
      _connectionStatus = 'Veri seti simülasyonu çalışıyor';
    });
  }

  void _stopSimulation() {
    _csvSimulator.stop();

    setState(() {
      _isSimulationRunning = false;
      _connectionStatus = 'Veri seti simülasyonu durduruldu';
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
    final filePath = await _loggingService.startLogging();

    setState(() {
      _isLogging = true;
      _loggingStatus = 'Açık';
      _logFilePath = filePath;
    });
  }

  Future<void> _stopLogging() async {
    await _loggingService.stopLogging();

    setState(() {
      _isLogging = false;
      _loggingStatus = 'Kapalı';
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
        ? Colors.greenAccent
        : statusText == 'WARNING'
            ? Colors.orangeAccent
            : statusText == 'BEKLENİYOR'
                ? Colors.white70
                : Colors.redAccent;

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 72,
        centerTitle: true,
        backgroundColor: const Color(0xFF171720),
        title: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'AKS & Telemetri Sistemi',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 22,
              ),
            ),
            SizedBox(height: 4),
            Text(
              'Elektrikli Araç Kontrol ve Veri Seti Tabanlı İzleme Paneli',
              style: TextStyle(
                fontSize: 13,
                color: Colors.white70,
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final bool narrowScreen = constraints.maxWidth < 1150;
          final bool shortScreen = constraints.maxHeight < 760;

          return SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                children: [
                  _buildTopControlBar(),
                  const SizedBox(height: 12),
                  if (narrowScreen)
                    Column(
                      children: [
                        SizedBox(
                          height: 500,
                          child: _buildDataGrid(),
                        ),
                        const SizedBox(height: 12),
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
                      height: shortScreen ? 390 : 430,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 560,
                            child: _buildDataGrid(),
                          ),
                          const SizedBox(width: 12),
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
                  const SizedBox(height: 12),
                  SizedBox(
                    height: shortScreen ? 230 : 270,
                    child: _buildChartsPanel(),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildTopControlBar() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: _boxDecoration(),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Text(
            'COM:',
            style: TextStyle(fontSize: 15),
          ),
          SizedBox(
            width: 105,
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
            text: 'Yenile',
            onPressed: _isSerialConnected ? null : _refreshPorts,
          ),
          _smallButton(
            text: _isSerialConnected ? 'Bağlantıyı Kes' : 'Bağlan',
            onPressed: _toggleSerialConnection,
          ),
        
          _smallButton(
            text: _isSimulationRunning
                ? 'Simülasyonu Durdur'
                : 'Simülasyonu Başlat',
            onPressed: _toggleSimulation,
          ),
          Text('Kayıt: $_loggingStatus'),
          _smallButton(
            text: _isLogging ? 'Kaydı Durdur' : 'Kaydı Başlat',
            onPressed: _toggleLogging,
          ),
          _smallButton(
            text: 'Klasör',
            onPressed: _openLogFolder,
          ),
          _connectionChip(),
        ],
      ),
    );
  }

  Widget _connectionChip() {
    Color indicatorColor;
    Color backgroundColor;
    Color borderColor;

    if (_isSimulationRunning || _isSerialConnected) {
      indicatorColor = Colors.greenAccent;
      backgroundColor = Colors.green.withValues(alpha: 0.15);
      borderColor = Colors.green;
    } else if (_isCsvLoaded) {
      indicatorColor = Colors.blueAccent;
      backgroundColor = Colors.blue.withValues(alpha: 0.15);
      borderColor = Colors.blue;
    } else {
      indicatorColor = Colors.redAccent;
      backgroundColor = Colors.red.withValues(alpha: 0.15);
      borderColor = Colors.red;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: borderColor),
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
    required VoidCallback? onPressed,
  }) {
    return SizedBox(
      height: 36,
      child: ElevatedButton(
        onPressed: onPressed,
        child: Text(
          text,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  Widget _buildDataGrid() {
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
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _buildDataCard(
                  title: 'Akım',
                  value: _telemetryData.current.toStringAsFixed(2),
                  unit: 'A',
                  icon: Icons.electric_meter,
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
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _buildDataCard(
                  title: 'Motor Hızı',
                  value: _telemetryData.motorSpeedRpm.toStringAsFixed(0),
                  unit: 'RPM',
                  icon: Icons.rotate_right,
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
                  title: 'Tahmini SOC',
                  value: '%${_telemetryData.estimatedSoc.toStringAsFixed(1)}',
                  unit: '',
                  icon: Icons.battery_charging_full,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _buildDataCard(
                  title: 'Gerçek SOC',
                  value:
                      '%${_telemetryData.groundTruthSoc.toStringAsFixed(1)}',
                  unit: '',
                  icon: Icons.battery_full,
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
                  title: 'Residual',
                  value: _telemetryData.residual.toStringAsFixed(2),
                  unit: '%',
                  icon: Icons.compare_arrows,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _buildDataCard(
                  title: 'Fault Label',
                  value: _telemetryData.faultLabel,
                  unit: '',
                  icon: Icons.label_important,
                ),
              ),
            ],
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
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: _boxDecoration(),
      child: Row(
        children: [
          Icon(
            icon,
            size: 26,
            color: Colors.white70,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Colors.white70,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Flexible(
                      child: Text(
                        value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 27,
                          fontWeight: FontWeight.bold,
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
                            color: Colors.white60,
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
        const SizedBox(height: 8),
        Expanded(
          child: _buildWarningsPanel(warnings),
        ),
        const SizedBox(height: 8),
        _buildRawDataPanel(),
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

    final lastPacketTime =
        '${_telemetryData.timestamp.hour.toString().padLeft(2, '0')}:'
        '${_telemetryData.timestamp.minute.toString().padLeft(2, '0')}:'
        '${_telemetryData.timestamp.second.toString().padLeft(2, '0')}';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: _boxDecoration(),
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
          const SizedBox(width: 12),
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
    );
  }

  Widget _statusInfoItem({
    required String title,
    required String value,
    required Color valueColor,
    required IconData icon,
  }) {
    return Row(
      children: [
        Icon(
          icon,
          size: 24,
          color: Colors.white70,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.white54,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: valueColor,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildWarningsPanel(List<String> warnings) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: _boxDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.warning_amber_rounded,
                color: Colors.orange,
              ),
              const SizedBox(width: 8),
              const Text(
                'Aktif Uyarılar',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: warnings.isEmpty
                      ? Colors.green.withValues(alpha: 0.15)
                      : Colors.orange.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Text(
                  '${warnings.length} uyarı',
                  style: TextStyle(
                    color: warnings.isEmpty
                        ? Colors.greenAccent
                        : Colors.orangeAccent,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (warnings.isEmpty)
            const Text(
              'Aktif uyarı bulunmuyor.',
              style: TextStyle(
                color: Colors.greenAccent,
                fontSize: 15,
              ),
            )
          else
            Expanded(
              child: ListView(
                children: warnings.map((warning) {
                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.orange.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Colors.orange.withValues(alpha: 0.35),
                      ),
                    ),
                    child: Text(
                      '• $warning',
                      style: const TextStyle(
                        color: Colors.orangeAccent,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildRawDataPanel() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: 13,
        vertical: 10,
      ),
      decoration: _boxDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Son Gelen Ham Veri',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            _lastRawData,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 4),
          Text(
            'Dosya: $_logFilePath',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 11,
              color: Colors.white38,
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
        const SizedBox(width: 12),
        Expanded(
          child: _buildLineChartCard(
            title: 'Gerçek SOC Grafiği',
            spots: _groundTruthSocPoints,
            maxY: 100,
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
      padding: const EdgeInsets.all(14),
      decoration: _boxDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
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
                      gridData: const FlGridData(show: true),
                      borderData: FlBorderData(show: true),
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
                          sideTitles: const SideTitles(
                            showTitles: true,
                            reservedSize: 38,
                          ),
                        ),
                      ),
                      lineBarsData: [
                        LineChartBarData(
                          spots: spots,
                          isCurved: true,
                          barWidth: 3,
                          dotData: const FlDotData(show: false),
                          belowBarData: BarAreaData(show: true),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  BoxDecoration _boxDecoration() {
    return BoxDecoration(
      color: const Color(0xFF1B1B1F),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: Colors.white12),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.22),
          blurRadius: 8,
          offset: const Offset(0, 3),
        ),
      ],
    );
  }
}