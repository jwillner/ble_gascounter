import 'package:flutter/material.dart';

import 'scan_connect_screen.dart';
import 'device_screen.dart';
import 'config_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  Widget _tile(BuildContext context, String title, String subtitle,
      IconData icon, VoidCallback onTap) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 14),
        ),
        onPressed: onTap,
        child: Row(
          children: [
            Icon(icon, size: 28),
            const SizedBox(width: 14),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w600)),
                Text(subtitle,
                    style:
                        const TextStyle(fontSize: 12, color: Colors.black54)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('GasCounter')),
      body: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _tile(
              context,
              'Scan + Verbinden',
              'BLE Gerät suchen und verbinden',
              Icons.bluetooth_searching,
              () => Navigator.of(context).push(
                MaterialPageRoute(
                    builder: (_) => const ScanConnectScreen()),
              ),
            ),
            const SizedBox(height: 12),
            _tile(
              context,
              'Messwerte',
              'Zählerstand, kWh, Pulse',
              Icons.gas_meter_outlined,
              () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const DeviceScreen()),
              ),
            ),
            const SizedBox(height: 12),
            _tile(
              context,
              'Konfiguration',
              'WiFi, MQTT, Kalibrierung',
              Icons.settings_outlined,
              () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ConfigScreen()),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
