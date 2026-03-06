import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../constants/nus_uuids.dart';
import '../models/ble_row.dart';

class BleManager extends ChangeNotifier {
  BluetoothDevice? connectedDevice;
  String? connectedId;
  String? connectedName;

  BluetoothCharacteristic? _rx;
  // ignore: unused_field
  BluetoothCharacteristic? _tx;

  StreamSubscription<List<int>>?            _txSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  final StringBuffer _lineBuf = StringBuffer();

  // Incoming data – state and config stored separately
  Map<String, dynamic> stateData  = {};
  Map<String, dynamic> configData = {};

  // Last ack from device
  bool?   lastAck;
  String? lastAckCmd;
  String? lastError;

  bool isConnecting = false;
  bool isConnected  = false;

  // ── Connection ────────────────────────────────────────────

  Future<void> disconnect() async {
    try {
      await _txSub?.cancel();
      await _connSub?.cancel();
      _txSub   = null;
      _connSub = null;
      _rx = null;
      _tx = null;
      if (connectedDevice != null) await connectedDevice!.disconnect();
    } catch (_) {
    } finally {
      connectedDevice = null;
      connectedId     = null;
      connectedName   = null;
      isConnected     = false;
      isConnecting    = false;
      notifyListeners();
    }
  }

  Future<void> connectNus(BleRow row) async {
    if (isConnecting) return;

    try { await FlutterBluePlus.stopScan(); } catch (_) {}
    await Future.delayed(const Duration(milliseconds: 200));

    await disconnect();

    isConnecting = true;
    notifyListeners();

    try {
      await row.device.connect(timeout: const Duration(seconds: 10));
      await Future.delayed(const Duration(milliseconds: 300));

      try { await row.device.requestMtu(255); } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 250));

      final services = await row.device.discoverServices();
      await Future.delayed(const Duration(milliseconds: 250));

      BluetoothCharacteristic? rx;
      BluetoothCharacteristic? tx;

      for (final s in services) {
        if (s.uuid != nusServiceUuid) continue;
        for (final c in s.characteristics) {
          if (c.uuid == nusRxUuid) rx = c;
          if (c.uuid == nusTxUuid) tx = c;
        }
      }

      if (rx == null || tx == null) {
        await row.device.disconnect();
        throw Exception('NUS RX/TX nicht gefunden');
      }

      // Enable notifications with retry
      try {
        await tx.setNotifyValue(true);
      } catch (_) {
        await Future.delayed(const Duration(milliseconds: 700));
        await tx.setNotifyValue(true);
      }
      await Future.delayed(const Duration(milliseconds: 300));

      await _txSub?.cancel();
      _txSub = tx.onValueReceived.listen(_onTxBytes);

      connectedDevice = row.device;
      connectedId     = row.id;
      connectedName   = row.name;
      _rx             = rx;
      _tx             = tx;
      isConnected     = true;
      isConnecting    = false;

      // Auto-cleanup on unexpected disconnect (e.g. device reboot)
      _connSub = row.device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected && isConnected) {
          _txSub?.cancel();
          _connSub?.cancel();
          _txSub        = null;
          _connSub      = null;
          _rx           = null;
          _tx           = null;
          connectedDevice = null;
          connectedId     = null;
          connectedName   = null;
          isConnected     = false;
          notifyListeners();
        }
      });

      notifyListeners();

      // Immediately request state + config
      await Future.delayed(const Duration(milliseconds: 500));
      await requestState();
      await Future.delayed(const Duration(milliseconds: 300));
      await requestConfig();
    } catch (e) {
      try { await row.device.disconnect(); } catch (_) {}
      isConnecting = false;
      isConnected  = false;
      notifyListeners();
      rethrow;
    }
  }

  // ── Incoming data ─────────────────────────────────────────

  void _onTxBytes(List<int> bytes) {
    final text = utf8.decode(bytes, allowMalformed: true);
    _lineBuf.write(text);

    final all   = _lineBuf.toString();
    final lines = all.split('\n');

    _lineBuf.clear();
    if (!all.endsWith('\n')) _lineBuf.write(lines.removeLast());

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      try {
        final obj = json.decode(trimmed);
        if (obj is! Map<String, dynamic>) continue;

        if (obj.containsKey('ack')) {
          lastAck    = obj['ack'] == true;
          lastAckCmd = obj['cmd']?.toString();
          lastError  = obj['error']?.toString();
          notifyListeners();
        } else if (obj['type'] == 'state') {
          stateData = obj;
          notifyListeners();
        } else if (obj['type'] == 'config') {
          configData = obj;
          notifyListeners();
        }
      } catch (_) {}
    }
  }

  // ── Send helpers ──────────────────────────────────────────

  Future<void> sendLine(String line) async {
    if (_rx == null) throw Exception('Nicht verbunden');
    final data = utf8.encode(line.endsWith('\n') ? line : '$line\n');
    await _rx!.write(Uint8List.fromList(data), withoutResponse: true);
  }

  Future<void> requestState() async {
    await sendLine('{"cmd":"get_state"}');
  }

  Future<void> requestConfig() async {
    await sendLine('{"cmd":"get_config"}');
  }

  Future<void> sendReset() async {
    lastAck = null;
    await sendLine('{"cmd":"reset"}');
  }

  Future<void> sendReboot() async {
    lastAck = null;
    await sendLine('{"cmd":"reboot"}');
  }

  Future<void> sendSetConfig({
    String? ssid,
    String? pass,
    String? mqttHost,
    double? pulseVol,
    double? kwhM3,
  }) async {
    lastAck    = null;
    lastAckCmd = null;
    lastError  = null;

    final map = <String, dynamic>{'cmd': 'set_config'};
    if (ssid     != null) map['ssid']       = ssid;
    if (pass     != null) map['pass']       = pass;
    if (mqttHost != null) map['mqtt_host']  = mqttHost;
    if (pulseVol != null) map['pulse_vol']  = pulseVol;
    if (kwhM3    != null) map['kwh_m3']     = kwhM3;

    await sendLine(json.encode(map));
  }
}

/// Global singleton
final bleManager = BleManager();
