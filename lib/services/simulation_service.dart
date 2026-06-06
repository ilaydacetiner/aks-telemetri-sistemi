import 'dart:async';
import 'dart:math';

class SimulationService {
  Timer? _timer;
  final Random _random = Random();

  void startSimulation(Function(String rawData) onDataReceived) {
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      final speed = 20 + _random.nextInt(80);
      final soc = 40 + _random.nextInt(60);
      final voltage = 280 + _random.nextInt(80);
      final current = (5 + _random.nextDouble() * 30).toStringAsFixed(1);
      final batteryTemp = 25 + _random.nextInt(25);
      final motorTemp = 30 + _random.nextInt(35);

      String status = 'OK';

      if (batteryTemp > 45 || motorTemp > 55) {
        status = 'WARNING';
      }

      final rawData =
          'speed:$speed,soc:$soc,voltage:$voltage,current:$current,batteryTemp:$batteryTemp,motorTemp:$motorTemp,status:$status';

      onDataReceived(rawData);
    });
  }

  void stopSimulation() {
    _timer?.cancel();
    _timer = null;
  }
}