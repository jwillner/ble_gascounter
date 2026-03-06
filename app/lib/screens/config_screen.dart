import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/ble_manager.dart';

class ConfigScreen extends StatefulWidget {
  const ConfigScreen({super.key});

  @override
  State<ConfigScreen> createState() => _ConfigScreenState();
}

class _ConfigScreenState extends State<ConfigScreen> {
  final _ssidCtrl     = TextEditingController();
  final _passCtrl     = TextEditingController();
  final _mqttCtrl     = TextEditingController();
  final _pulseVolCtrl = TextEditingController();
  final _kwhM3Ctrl    = TextEditingController();

  bool _passVisible = false;
  bool _populated   = false;

  @override
  void initState() {
    super.initState();
    bleManager.addListener(_onBleChanged);
    _populateFromConfig();
  }

  @override
  void dispose() {
    bleManager.removeListener(_onBleChanged);
    _ssidCtrl.dispose();
    _passCtrl.dispose();
    _mqttCtrl.dispose();
    _pulseVolCtrl.dispose();
    _kwhM3Ctrl.dispose();
    super.dispose();
  }

  void _onBleChanged() {
    if (!mounted) return;

    // Fill fields when config arrives
    if (!_populated) _populateFromConfig();

    // Show ack snackbar
    final ack = bleManager.lastAck;
    final cmd = bleManager.lastAckCmd;
    if (ack != null) {
      String msg;
      if (ack) {
        msg = cmd == 'set_config'
            ? 'Gespeichert – Gerät startet neu…'
            : cmd == 'reset'
                ? 'Zähler zurückgesetzt'
                : 'OK';
      } else {
        msg = 'Fehler: ${bleManager.lastError ?? "unbekannt"}';
      }
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
      bleManager.lastAck    = null;
      bleManager.lastAckCmd = null;
    }
    setState(() {});
  }

  void _populateFromConfig() {
    final cfg = bleManager.configData;
    if (cfg.isEmpty) return;

    if (_ssidCtrl.text.isEmpty && cfg['ssid'] != null) {
      _ssidCtrl.text = cfg['ssid'].toString();
    }
    if (_mqttCtrl.text.isEmpty && cfg['mqtt_host'] != null) {
      _mqttCtrl.text = cfg['mqtt_host'].toString();
    }
    if (_pulseVolCtrl.text.isEmpty && cfg['pulse_vol'] != null) {
      _pulseVolCtrl.text = cfg['pulse_vol'].toString();
    }
    if (_kwhM3Ctrl.text.isEmpty && cfg['kwh_m3'] != null) {
      _kwhM3Ctrl.text = cfg['kwh_m3'].toString();
    }
    _populated = true;
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _sendConfig() async {
    final ssid     = _ssidCtrl.text.trim();
    final pass     = _passCtrl.text;
    final mqtt     = _mqttCtrl.text.trim();
    final pulseVol = double.tryParse(_pulseVolCtrl.text.trim());
    final kwhM3    = double.tryParse(_kwhM3Ctrl.text.trim());

    if (ssid.isEmpty || mqtt.isEmpty) {
      _snack('SSID und MQTT Host dürfen nicht leer sein');
      return;
    }

    try {
      await bleManager.sendSetConfig(
        ssid:     ssid.isNotEmpty ? ssid : null,
        pass:     pass.isNotEmpty ? pass : null,
        mqttHost: mqtt.isNotEmpty ? mqtt : null,
        pulseVol: pulseVol,
        kwhM3:    kwhM3,
      );
      _snack('Konfiguration gesendet…');
    } catch (e) {
      _snack('Fehler: $e');
    }
  }

  Future<void> _sendReset() async {
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

  Future<void> _sendReboot() async {
    try {
      await bleManager.sendReboot();
      _snack('Gerät startet neu…');
    } catch (e) {
      _snack('Fehler: $e');
    }
  }

  InputDecoration _deco(String label, {String? hint}) => InputDecoration(
        labelText: label,
        hintText: hint,
        border: const OutlineInputBorder(borderRadius: BorderRadius.zero),
        isDense: true,
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Konfiguration'),
        actions: [
          ListenableBuilder(
            listenable: bleManager,
            builder: (context, _) => IconButton(
              icon: const Icon(Icons.download_outlined),
              tooltip: 'Konfiguration lesen',
              onPressed: bleManager.isConnected
                  ? () async {
                      _populated = false;
                      try {
                        await bleManager.requestConfig();
                      } catch (e) {
                        _snack('Fehler: $e');
                      }
                    }
                  : null,
            ),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: bleManager,
        builder: (context, _) {
          final connected = bleManager.isConnected;

          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── WiFi ────────────────────────────────
                const Text('WiFi',
                    style: TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                TextField(
                  controller: _ssidCtrl,
                  enabled: connected,
                  decoration: _deco('SSID'),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: _passCtrl,
                  enabled: connected,
                  obscureText: !_passVisible,
                  decoration: _deco('Passwort', hint: '(leer = unverändert)')
                      .copyWith(
                    suffixIcon: IconButton(
                      icon: Icon(_passVisible
                          ? Icons.visibility_off
                          : Icons.visibility),
                      onPressed: () =>
                          setState(() => _passVisible = !_passVisible),
                    ),
                  ),
                ),
                const SizedBox(height: 10),

                // ── MQTT ────────────────────────────────
                const Text('MQTT',
                    style: TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                TextField(
                  controller: _mqttCtrl,
                  enabled: connected,
                  decoration: _deco('MQTT Host / IP'),
                  keyboardType: TextInputType.url,
                ),
                const SizedBox(height: 10),

                // ── Kalibrierung ────────────────────────
                const Text('Kalibrierung',
                    style: TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _pulseVolCtrl,
                        enabled: connected,
                        decoration: _deco('m³/Impuls', hint: '0.01'),
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(
                              RegExp(r'[0-9.]')),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _kwhM3Ctrl,
                        enabled: connected,
                        decoration: _deco('kWh/m³', hint: '10.5'),
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(
                              RegExp(r'[0-9.]')),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // ── Senden ──────────────────────────────
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                      shape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.zero),
                      padding:
                          const EdgeInsets.symmetric(vertical: 12)),
                  icon: const Icon(Icons.upload_outlined),
                  label: const Text('Speichern & Senden'),
                  onPressed: connected ? _sendConfig : null,
                ),
                const SizedBox(height: 10),
                const Divider(),
                const SizedBox(height: 8),

                // ── Geräte-Aktionen ──────────────────────
                const Text('Geräte-Aktionen',
                    style: TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red,
                      shape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.zero)),
                  icon: const Icon(Icons.restart_alt),
                  label: const Text('Zähler zurücksetzen'),
                  onPressed: connected ? _sendReset : null,
                ),
                const SizedBox(height: 6),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                      shape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.zero)),
                  icon: const Icon(Icons.power_settings_new),
                  label: const Text('Gerät neu starten'),
                  onPressed: connected ? _sendReboot : null,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
