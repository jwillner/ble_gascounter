# Entwicklungsumgebung – Aufbau und Konfiguration

Dieses Dokument beschreibt vollständig, wie die Entwicklungsumgebung für das BLE GasCounter Projekt aufgebaut wurde. Ziel ist es, die Umgebung auf einem anderen System reproduzieren zu können.

---

## System

- **Host:** Proxmox-Server mit KVM-Virtualisierung
- **VM:** Ubuntu 22.04 LTS (Linux 5.15.0)
- **Entwicklung:** Vollständig auf der VM — kein lokales Windows/Mac nötig
- **Handy-Verbindung:** Android per USB, durchgereicht via Proxmox USB-Passthrough

---

## 1. arduino-cli

### Installation prüfen

```bash
which arduino-cli
arduino-cli version
# Erwartung: arduino-cli Version: 1.4.1
```

Falls nicht installiert:

```bash
curl -fsSL https://raw.githubusercontent.com/arduino/arduino-cli/master/install.sh | sh
sudo mv bin/arduino-cli /usr/local/bin/
```

### ESP32-Core prüfen

```bash
arduino-cli core list
# Erwartung:
# esp32:esp32  3.3.7  3.3.7  esp32
```

Falls nicht installiert:

```bash
arduino-cli config init
arduino-cli config add board_manager.additional_urls \
  https://raw.githubusercontent.com/espressif/arduino-esp32/gh-pages/package_esp32_index.json
arduino-cli core update-index
arduino-cli core install esp32:esp32
```

### Board erkennen

Board per USB anschließen und prüfen:

```bash
arduino-cli board list
# Erwartung:
# /dev/ttyACM0  serial  Serial Port (USB)  ESP32 Family Device
```

Alle C6-Boards anzeigen:

```bash
arduino-cli board listall | grep -i c6
```

### Libraries installieren (global unter `~/Arduino/libraries`)

```bash
arduino-cli lib install "NimBLE-Arduino"
arduino-cli lib install "ArduinoJson"
arduino-cli lib install "PubSubClient"
arduino-cli lib install "Adafruit SSD1306"
arduino-cli lib install "Adafruit GFX Library"
arduino-cli lib install "Adafruit NeoPixel"
```

Installierte Libraries prüfen:

```bash
arduino-cli lib list
```

### Kompilieren

```bash
arduino-cli compile \
  --fqbn "esp32:esp32:esp32c6:UploadSpeed=921600,CDCOnBoot=cdc,CPUFreq=160,FlashFreq=80,FlashMode=qio,FlashSize=4M,PartitionScheme=huge_app,DebugLevel=none,EraseFlash=none" \
  --libraries /home/jw/Arduino/libraries \
  .
```

### Flashen

```bash
arduino-cli upload \
  --fqbn "esp32:esp32:esp32c6:UploadSpeed=921600,CDCOnBoot=cdc,CPUFreq=160,FlashFreq=80,FlashMode=qio,FlashSize=4M,PartitionScheme=huge_app,DebugLevel=none,EraseFlash=none" \
  --port /dev/ttyACM0 \
  .
```

Falls der Upload nicht startet (ESP32-C6 SuperMini):

1. `BOOT`-Taste gedrückt halten
2. `RESET` kurz drücken
3. `BOOT` loslassen

### Serieller Monitor

```bash
# Mit arduino-cli:
arduino-cli monitor -p /dev/ttyACM0 -c baudrate=115200

# Mit tio (empfohlen):
tio /dev/ttyACM0 -b 115200
# Beenden: Ctrl+T Q

# tio installieren falls nötig:
sudo apt install tio
```

---

## 2. sketch.yaml — Fallstricke

```yaml
profiles:
  default:
    fqbn: esp32:esp32:esp32c6:UploadSpeed=921600,CDCOnBoot=cdc,CPUFreq=160,FlashFreq=80,FlashMode=qio,FlashSize=4M,PartitionScheme=huge_app,DebugLevel=none,EraseFlash=none
    platforms:
      - platform: esp32:esp32
```

**Wichtige Erkenntnisse:**

- **Plattformversion weglassen** — `platform: esp32:esp32 (3.3.7)` führt zu Validierungsfehlern; einfach `platform: esp32:esp32` ohne Version schreiben
- **`libraries:` Sektion weglassen** — Im Profile-Modus von arduino-cli werden global installierte Libraries nicht gefunden wenn sie in sketch.yaml aufgelistet sind; sie werden stattdessen neu heruntergeladen und schlagen fehl. Ohne Eintrag werden sie automatisch gefunden.
- **`.ino`-Stub muss exakt den gleichen Namen haben wie das Verzeichnis** — z.B. Verzeichnis `firmware/` → Datei `firmware.ino` (auch wenn der eigentliche Code in `src/main.cpp` liegt)

---

## 3. Partition Scheme — BLE + WiFi

Mit dem Standard-Partition-Schema (`PartitionScheme=default`, 1,25 MB) passt die Firmware nicht:

```
Sketch too big: 106% of available flash
```

Lösung: `PartitionScheme=huge_app` (3 MB Code-Partition) → ~44% Auslastung.

---

## 4. NimBLE-Arduino 2.x — API-Änderungen

NimBLE-Arduino 2.x hat gegenüber 1.x geänderte Callback-Signaturen. Alle Server- und Characteristic-Callbacks brauchen einen `NimBLEConnInfo&`-Parameter:

```cpp
// NimBLE 1.x (alt — kompiliert nicht mehr):
void onConnect(NimBLEServer* pSrv) override {}
void onDisconnect(NimBLEServer* pSrv) override {}
void onWrite(NimBLECharacteristic* pChar) override {}

// NimBLE 2.x (korrekt):
void onConnect(NimBLEServer* pSrv, NimBLEConnInfo& connInfo) override {}
void onDisconnect(NimBLEServer* pSrv, NimBLEConnInfo& connInfo, int reason) override {}
void onWrite(NimBLECharacteristic* pChar, NimBLEConnInfo& connInfo) override {}
```

`setScanResponse()` wurde in 2.x entfernt — Aufrufe vollständig entfernen.

---

## 5. Flutter installieren

```bash
sudo snap install flutter --classic
flutter --version
# Flutter 3.41.4, Dart 3.11.1
```

Flutter-Binaries liegen unter:
```
/home/jw/snap/flutter/common/flutter/
```

### Flutter-Projekt anlegen

Wenn `lib/`-Dart-Dateien bereits vorhanden sind, `flutter create` ausführen um die Android-Boilerplate zu erzeugen — vorhandene Dateien werden **nicht** überschrieben:

```bash
cd app/
flutter create --project-name ble_gascounter --org de.jwillner .
flutter pub get
```

### Code prüfen

```bash
flutter analyze
# Ziel: No issues found!
```

---

## 6. Android SDK

Das Android SDK ist nicht über apt verfügbar und muss manuell eingerichtet werden.

### Java 17 installieren

```bash
sudo apt install openjdk-17-jdk
java -version
# openjdk version "17.0.18"
```

### Android Command Line Tools

```bash
mkdir -p ~/android-sdk/cmdline-tools
cd ~/android-sdk/cmdline-tools

# Aktuelle Version von https://developer.android.com/studio herunterladen
wget https://dl.google.com/android/repository/commandlinetools-linux-<VERSION>_latest.zip
unzip commandlinetools-linux-*_latest.zip
mv cmdline-tools latest
```

Verzeichnisstruktur danach:
```
~/android-sdk/
└── cmdline-tools/
    └── latest/
        └── bin/
            ├── sdkmanager
            └── avdmanager
```

### SDK-Komponenten installieren

```bash
export ANDROID_HOME=/home/jw/android-sdk
export PATH=$PATH:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools

sdkmanager --licenses          # alle Lizenzen akzeptieren
sdkmanager "platform-tools"
sdkmanager "platforms;android-36"
sdkmanager "build-tools;28.0.3"
```

> Beim ersten Gradle-Build werden automatisch zusätzlich heruntergeladen: NDK 28.2.x, Platforms 33 + 34, CMake 3.22.1. Das dauert beim ersten Mal mehrere Minuten.

### Flutter mit SDK verbinden

```bash
flutter config --android-sdk /home/jw/android-sdk
flutter doctor --android-licenses
```

### Zielzustand flutter doctor

```
[✓] Flutter (Channel stable, 3.41.4)
[✓] Android toolchain - develop for Android devices (Android SDK version 36)
[✓] Linux toolchain
[!] Android Studio (not installed)   ← ignorierbar, kein IDE nötig
[✓] Connected device (1 available)
[✓] Network resources
```

---

## 7. APK bauen und installieren

Da auf der VM `JAVA_HOME` und `ANDROID_HOME` nicht persistent gesetzt sind, werden sie beim Build-Befehl explizit mitgegeben:

```bash
cd /home/jw/arduino_projects/ble_gascounter/app

JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64 \
ANDROID_HOME=/home/jw/android-sdk \
flutter build apk --release
```

APK-Ausgabe:
```
build/app/outputs/flutter-apk/app-release.apk  (~48 MB)
```

Erster Build: mehrere Minuten (NDK-Download etc.). Folgebuilds: ~30–60 Sekunden.

### APK per ADB installieren

```bash
/home/jw/android-sdk/platform-tools/adb install -r \
  build/app/outputs/flutter-apk/app-release.apk
```

---

## 8. ADB und Android-Gerät einrichten

### Handy vorbereiten (einmalig)

1. **Entwickleroptionen aktivieren:** Einstellungen → Über das Telefon → Build-Nummer 7× tippen
2. **USB-Debugging aktivieren:** Einstellungen → Entwickleroptionen → USB-Debugging → Ein
3. USB-Verbindungstyp auf **Dateiübertragung (MTP)** stellen (erscheint als Benachrichtigung beim Einstecken)
4. Auf dem Handy den Dialog **"USB-Debugging zulassen?"** mit **Zulassen** bestätigen

### Gerät prüfen

```bash
/home/jw/android-sdk/platform-tools/adb devices
# Erwartung: R5CX60NQPCK  device
```

Erscheint `no permissions`, fehlt die udev-Regel:

### udev-Regel anlegen

Vendor-ID aus `lsusb` ermitteln:

```bash
lsusb
# z.B.: Bus 009 Device 007: ID 04e8:6860 Samsung Electronics Co., Ltd
```

Regel anlegen:

```bash
echo 'SUBSYSTEM=="usb", ATTR{idVendor}=="04e8", MODE="0666", GROUP="plugdev"' \
  | sudo tee /etc/udev/rules.d/51-android.rules

sudo udevadm control --reload-rules
sudo udevadm trigger
```

Danach USB trennen und wieder verbinden.

Vendor-IDs gängiger Hersteller:

| Hersteller | Vendor-ID |
|------------|-----------|
| Samsung | `04e8` |
| Google / Pixel | `18d1` |
| OnePlus | `2a70` |
| Xiaomi | `2717` |

### USB-Passthrough in Proxmox

Da Entwicklung auf einer Proxmox-VM läuft, sieht die VM das Handy nicht automatisch:

1. Proxmox Web-UI → VM auswählen → Hardware → USB-Gerät hinzufügen
2. Gerät nach Vendor-ID/Device-ID auswählen (Samsung Galaxy A5: `04e8:6860`)
3. VM neu starten oder Gerät neu einstecken
4. In der VM mit `lsusb` prüfen ob das Gerät erscheint

---

## 9. BLE auf Android — Besonderheiten

### Standortdienst ist Pflicht

Für BLE-Scans unter Android muss nicht nur die App-Berechtigung `ACCESS_FINE_LOCATION` erteilt sein — der **Standortdienst muss systemweit eingeschaltet** sein (Einstellungen → Standort → Ein). Ohne aktivierten Standortdienst liefert `FlutterBluePlus.startScan()` lautlos keine Ergebnisse.

### Gerätename im Advertisement fehlt auf Android

Auf iOS wird der BLE-Gerätename zuverlässig aus dem Advertisement gelesen. Auf Android fehlt `advName` häufig, da er nur im Scan-Response-Paket übertragen wird. Robuste Lösung: **nach NUS Service UUID filtern** statt nach Name:

```dart
await FlutterBluePlus.startScan(withServices: [nusServiceUuid]);
```

Als Fallback-Anzeigename wird der Name aus den letzten 4 Zeichen der MAC generiert:

```dart
final macSuffix = id.replaceAll(':', '').toUpperCase();
final macShort  = macSuffix.substring(macSuffix.length - 4);
final name = advName.isNotEmpty ? advName
           : platName.isNotEmpty ? platName
           : 'GasCounter-$macShort';
```

### `neverForLocation` Flag — Konflikt vermeiden

Das Flag `android:usesPermissionFlags="neverForLocation"` auf `BLUETOOTH_SCAN` ist nicht mit `androidUsesFineLocation: true` in flutter_blue_plus kombinierbar — der Scan liefert dann gar nichts. Im Projekt: Flag aus AndroidManifest entfernt.

### Verbindungsverlust automatisch erkennen (FBP Code 6)

Bei unerwartetem Verbindungsabbruch (z.B. Geräte-Neustart per `reboot`-Befehl) wirft flutter_blue_plus eine Exception mit FBP-Code 6. Ohne Gegenmassnahme bleibt `isConnected = true` obwohl keine Verbindung mehr besteht. Lösung: `connectionState`-Listener im BleManager:

```dart
_connSub = device.connectionState.listen((state) {
  if (state == BluetoothConnectionState.disconnected && isConnected) {
    _txSub?.cancel();
    _connSub?.cancel();
    _rx = _tx = null;
    connectedDevice = null;
    isConnected = false;
    notifyListeners();
  }
});
```

---

## 10. Typische Fehler und Lösungen

| Fehler | Ursache | Lösung |
|--------|---------|--------|
| `sketch.yaml: invalid version` | Plattformversion angegeben | Version weglassen: nur `platform: esp32:esp32` |
| `Library not found` beim Compile | `libraries:` in sketch.yaml | Sektion entfernen, global installierte Libs werden automatisch gefunden |
| Firmware passt nicht (106%) | `PartitionScheme=default` | Auf `PartitionScheme=huge_app` wechseln |
| NimBLE Compile-Fehler | Alte 1.x Callback-Signaturen | `NimBLEConnInfo&`-Parameter ergänzen (Abschnitt 4) |
| `No Android SDK found` | `ANDROID_HOME` nicht gesetzt | `flutter config --android-sdk /home/jw/android-sdk` |
| `JAVA_HOME not set` | Java nicht im PATH der Session | `JAVA_HOME=...` beim Build-Befehl explizit setzen |
| `adb: no permissions` | Fehlende udev-Regel | udev-Regel für Hersteller-VendorID anlegen (Abschnitt 8) |
| `adb devices` leer, `lsusb` auch leer | Reines Ladekabel oder Proxmox-Passthrough fehlt | Datenkabel verwenden, Proxmox USB-Passthrough aktivieren |
| BLE-Scan findet nichts (Android) | Standortdienst aus | Einstellungen → Standort → Ein |
| Gerätename fehlt auf Android | `advName` leer im Scan | Nach NUS Service UUID filtern (Abschnitt 9) |
| FBP Exception Code 6 | Verbindungsabbruch nicht abgefangen | `connectionState`-Listener in BleManager einbauen |
| `flutter create` löscht `lib/` | — | Nein, vorhandene Dateien bleiben erhalten |
| Upload startet nicht (ESP32) | Board nicht im Bootloader-Modus | BOOT halten + RESET drücken + BOOT loslassen |
