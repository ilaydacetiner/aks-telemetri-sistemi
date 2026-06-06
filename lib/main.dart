import 'dart:io';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import 'models/telemetry_data.dart';
import 'services/logging_service.dart';
import 'services/serial_service.dart';
import 'services/simulation_service.dart';
import 'utils/telemetry_parser.dart';

void main() {
  runApp(const AksTelemetryApp());
}

class AksTelemetryApp extends StatelessWidget {
  const AksTelemetryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AKS Telemetri Paneli',
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
  final SimulationService _simulationService = SimulationService();
  final SerialService _serialService = SerialService();
  final LoggingService _loggingService = LoggingService();

  TelemetryData _telemetryData = TelemetryData.empty();

  String _lastRawData = 'Henüz veri alınmadı.';
  String _connectionStatus = 'Bağlı değil';
  String _loggingStatus = 'Kapalı';
  String _logFilePath = '-';

  bool _isSimulationRunning = false;
  bool _isSerialConnected = false;
  bool _isLogging = false;

  List<String> _availablePorts = [];
  String? _selectedPort;

  final List<FlSpot> _speedPoints = [];
  final List<FlSpot> _socPoints = [];
  double _chartIndex = 0;

  @override
  void initState() {
    super.initState();
    _refreshPorts();
  }

  void _refreshPorts() {
    final ports = _serialService.getAvailablePorts();

    setState(() {
      _availablePorts = ports;
      _selectedPort = ports.isNotEmpty ? (_selectedPort ?? ports.first) : null;
    });
  }

  Future<void> _handleIncomingData(String rawData) async {
    final parsedData = TelemetryParser.parse(rawData);

    if (parsedData != null) {
      setState(() {
        _telemetryData = parsedData;
        _lastRawData = rawData;

        _chartIndex++;
        _speedPoints.add(FlSpot(_chartIndex, parsedData.speed));
        _socPoints.add(FlSpot(_chartIndex, parsedData.soc));

        if (_speedPoints.length > 20) {
          _speedPoints.removeAt(0);
        }

        if (_socPoints.length > 20) {
          _socPoints.removeAt(0);
        }
      });

      if (_isLogging) {
        await _loggingService.writeData(parsedData);
      }
    }
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
      onDataReceived: _handleIncomingData,
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
      _connectionStatus = 'Bağlantı kesildi';
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

    _simulationService.startSimulation(_handleIncomingData);

    setState(() {
      _isSimulationRunning = true;
      _connectionStatus = 'Simülasyon çalışıyor';
    });
  }

  void _stopSimulation() {
    _simulationService.stopSimulation();

    setState(() {
      _isSimulationRunning = false;
      _connectionStatus = 'Simülasyon durduruldu';
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
    _simulationService.stopSimulation();
    _serialService.disconnect();
    _loggingService.stopLogging();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final statusColor = _telemetryData.status == 'OK'
        ? Colors.greenAccent
        : _telemetryData.status == 'WARNING'
            ? Colors.orangeAccent
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
              'Elektrikli Araç Kontrol ve Gerçek Zamanlı İzleme Paneli',
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
                          height: 360,
                          child: _buildDataGrid(),
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          height: 360,
                          child: _buildStatusAndWarningArea(statusColor),
                        ),
                      ],
                    )
                  else
                    SizedBox(
                      height: shortScreen ? 360 : 390,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 500,
                            child: _buildDataGrid(),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _buildStatusAndWarningArea(statusColor),
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
    final bool active = _isSimulationRunning || _isSerialConnected;

    final Color indicatorColor = active ? Colors.greenAccent : Colors.redAccent;
    final Color backgroundColor =
        active ? Colors.green.withOpacity(0.15) : Colors.red.withOpacity(0.15);
    final Color borderColor = active ? Colors.green : Colors.red;

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
        child: Text(text),
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
                  title: 'Araç Hızı',
                  value: '${_telemetryData.speed.toStringAsFixed(0)}',
                  unit: 'km/h',
                  icon: Icons.speed,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _buildDataCard(
                  title: 'Batarya',
                  value: '%${_telemetryData.soc.toStringAsFixed(0)}',
                  unit: 'SOC',
                  icon: Icons.battery_charging_full,
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
                  title: 'Gerilim',
                  value: '${_telemetryData.voltage.toStringAsFixed(0)}',
                  unit: 'V',
                  icon: Icons.bolt,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _buildDataCard(
                  title: 'Akım',
                  value: '${_telemetryData.current.toStringAsFixed(1)}',
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
                  title: 'Batarya Sıcaklığı',
                  value: '${_telemetryData.batteryTemp.toStringAsFixed(0)}',
                  unit: '°C',
                  icon: Icons.thermostat,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _buildDataCard(
                  title: 'Motor Sıcaklığı',
                  value: '${_telemetryData.motorTemp.toStringAsFixed(0)}',
                  unit: '°C',
                  icon: Icons.device_thermostat,
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
                    Text(
                      value,
                      style: const TextStyle(
                        fontSize: 27,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
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
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusAndWarningArea(Color statusColor) {
    return Column(
      children: [
        _buildStatusPanel(statusColor),
        const SizedBox(height: 8),
        Expanded(
          child: _buildWarningsPanel(),
        ),
        const SizedBox(height: 8),
        _buildRawDataPanel(),
      ],
    );
  }

  Widget _buildStatusPanel(Color statusColor) {
    final sourceText = _isSimulationRunning
        ? 'Simülasyon'
        : _isSerialConnected
            ? _selectedPort ?? 'COM'
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
              value: _telemetryData.status,
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
              icon: Icons.settings_input_antenna,
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

  Widget _buildWarningsPanel() {
    final warnings = _telemetryData.warnings;

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
                      ? Colors.green.withOpacity(0.15)
                      : Colors.orange.withOpacity(0.15),
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
                      color: Colors.orange.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Colors.orange.withOpacity(0.35),
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
            title: 'Araç Hızı Grafiği',
            spots: _speedPoints,
            maxY: 120,
            unit: 'km/h',
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildLineChartCard(
            title: 'Batarya Doluluğu Grafiği',
            spots: _socPoints,
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
          color: Colors.black.withOpacity(0.22),
          blurRadius: 8,
          offset: const Offset(0, 3),
        ),
      ],
    );
  }
}