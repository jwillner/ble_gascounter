import 'package:flutter/material.dart';

import '../services/ble_manager.dart';
import 'config_screen.dart';

class DeviceScreen extends StatefulWidget {
  const DeviceScreen({super.key});

  @override
  State<DeviceScreen> createState() => _DeviceScreenState();
}

class _DeviceScreenState extends State<DeviceScreen> {
  @override
  void initState() {
    super.initState();
    bleManager.addListener(_onBleChanged);
  }

  @override
  void dispose() {
    bleManager.removeListener(_onBleChanged);
    super.dispose();
  }

  void _onBleChanged() {
    if (!mounted) return;
    final ack = bleManager.lastAck;
    final cmd = bleManager.lastAckCmd;
    if (ack != null) {
      final msg = ack
          ? (cmd == 'reset' ? 'Zähler zurückgesetzt' : 'OK')
          : 'Fehler: ${bleManager.lastError ?? "unbekannt"}';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
      bleManager.lastAck = null;
      bleManager.lastAckCmd = null;
    }
    setState(() {});
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _reset() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Zähler zurücksetzen?'),
        content: const Text(
            'Setzt total kWh, Stunden-kWh und Impulszähler auf 0 zurück.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Abbrechen')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Zurücksetzen',
                  style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await bleManager.sendReset();
    } catch (e) {
      _snack('Fehler: $e');
    }
  }

  Widget _statCard(String label, String value, {String? sub}) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style:
                    const TextStyle(fontSize: 12, color: Colors.black54)),
            const SizedBox(height: 4),
            Text(value,
                style: const TextStyle(
                    fontSize: 28, fontWeight: FontWeight.bold)),
            if (sub != null)
              Text(sub,
                  style: const TextStyle(
                      fontSize: 12, color: Colors.black54)),
          ],
        ),
      ),
    );
  }

  Widget _kv(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 120,
            child: Text(label,
                style: const TextStyle(
                    fontSize: 13, color: Colors.black54)),
          ),
          Text(value, style: const TextStyle(fontSize: 13)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Messwerte')),
      body: ListenableBuilder(
        listenable: bleManager,
        builder: (context, _) {
          final connected = bleManager.isConnected;
          final state     = bleManager.stateData;
          final devName   = bleManager.connectedName ?? '–';

          final totalKwh     = state['total_kwh'];
          final hourKwh      = state['hour_kwh'];
          final pulsesTotal  = state['pulses_total'];
          final pulsesHour   = state['pulses_hour'];
          final rssi         = state['rssi'];
          final mqttOnline   = state['mqtt'];

          return Padding(
            padding: const EdgeInsets.all(14),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ── Status bar ──────────────────────────
                  Row(
                    children: [
                      Icon(
                        connected
                            ? Icons.bluetooth_connected
                            : Icons.bluetooth_disabled,
                        color: connected ? Colors.teal : Colors.black38,
                        size: 18,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          connected ? devName : 'Nicht verbunden',
                          style: TextStyle(
                              color: connected
                                  ? Colors.teal
                                  : Colors.black38),
                        ),
                      ),
                      if (connected && mqttOnline != null)
                        Chip(
                          label: Text(
                            mqttOnline == true ? 'MQTT ✓' : 'MQTT ✗',
                            style: const TextStyle(fontSize: 11),
                          ),
                          backgroundColor: mqttOnline == true
                              ? Colors.green.shade100
                              : Colors.red.shade100,
                          padding: EdgeInsets.zero,
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // ── Main values ─────────────────────────
                  _statCard(
                    'Gesamt',
                    totalKwh != null
                        ? '${totalKwh.toStringAsFixed(3)} kWh'
                        : '– kWh',
                  ),
                  const SizedBox(height: 8),
                  _statCard(
                    'Diese Stunde',
                    hourKwh != null
                        ? '${hourKwh.toStringAsFixed(3)} kWh'
                        : '– kWh',
                  ),
                  const SizedBox(height: 16),

                  // ── Detail values ───────────────────────
                  const Divider(),
                  const SizedBox(height: 8),
                  _kv('Impulse gesamt',
                      pulsesTotal?.toString() ?? '–'),
                  _kv('Impulse Stunde',
                      pulsesHour?.toString() ?? '–'),
                  _kv('RSSI',
                      rssi != null ? '$rssi dBm' : '–'),
                  const SizedBox(height: 16),

                  // ── Actions ─────────────────────────────
                  const Divider(),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                        shape: const RoundedRectangleBorder(
                            borderRadius: BorderRadius.zero)),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Werte abrufen'),
                    onPressed: connected
                        ? () async {
                            try {
                              await bleManager.requestState();
                            } catch (e) {
                              _snack('Fehler: $e');
                            }
                          }
                        : null,
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                        shape: const RoundedRectangleBorder(
                            borderRadius: BorderRadius.zero)),
                    icon: const Icon(Icons.settings_outlined),
                    label: const Text('Konfiguration'),
                    onPressed: connected
                        ? () => Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) => const ConfigScreen()),
                            )
                        : null,
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red,
                        shape: const RoundedRectangleBorder(
                            borderRadius: BorderRadius.zero)),
                    icon: const Icon(Icons.restart_alt),
                    label: const Text('Zähler zurücksetzen'),
                    onPressed: connected ? _reset : null,
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                        shape: const RoundedRectangleBorder(
                            borderRadius: BorderRadius.zero)),
                    icon: const Icon(Icons.bluetooth_disabled),
                    label: const Text('Trennen'),
                    onPressed: connected ? bleManager.disconnect : null,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
