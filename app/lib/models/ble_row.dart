import 'package:flutter_blue_plus/flutter_blue_plus.dart';

class BleRow {
  final BluetoothDevice device;
  final String id;
  final String name;
  final int rssi;

  const BleRow({
    required this.device,
    required this.id,
    required this.name,
    required this.rssi,
  });
}
