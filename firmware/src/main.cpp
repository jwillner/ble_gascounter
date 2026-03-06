#include <Arduino.h>
#include <WiFi.h>
#include <PubSubClient.h>
#include <Preferences.h>
#include <Adafruit_NeoPixel.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include <NimBLEDevice.h>
#include <ArduinoJson.h>

//
// ============================================================
// ===================== CONFIGURATION ========================
// ============================================================
//

// -------- WLAN (mutable, overridden from NVS) ----------
static char WIFI_SSID[64] = "RouterJoachimWillner";
static char WIFI_PASS[64] = "JoWiBu-456";

// -------- MQTT ----------
static char MQTT_HOST[64]  = "192.168.1.16";
static const uint16_t MQTT_PORT = 1883;

static const char* MQTT_CLIENT_ID   = "gas_counter_esp32c6";
static const char* MQTT_TOPIC_STATE = "gas_counter/state";
static const char* MQTT_TOPIC_GPIO2 = "gas_counter/gpio2";
static const char* MQTT_TOPIC_AVAIL = "gas_counter/availability";

// -------- Hardware ----------
static const uint8_t PIN_SENSOR   = 3;
static const uint8_t PIN_NEOPIXEL = 8;
static const uint8_t PIN_BUTTON   = BOOT_PIN;
static const uint8_t NUM_PIXELS   = 1;

// -------- OLED ----------
static const uint8_t OLED_SDA     = 0;
static const uint8_t OLED_SCL     = 1;
static const uint8_t SCREEN_WIDTH  = 128;
static const uint8_t SCREEN_HEIGHT = 64;
static const uint8_t OLED_ADDRESS  = 0x3C;

// -------- BLE / NUS ----------
static const char* NUS_SERVICE_UUID = "6e400001-b5a3-f393-e0a9-e50e24dcca9e";
static const char* NUS_RX_UUID      = "6e400002-b5a3-f393-e0a9-e50e24dcca9e";
static const char* NUS_TX_UUID      = "6e400003-b5a3-f393-e0a9-e50e24dcca9e";

// -------- Gas Parameters (mutable, overridden from NVS) ----------
static float pulse_volume_m3 = 0.01f;
static float gas_kwh_per_m3  = 10.5f;

// -------- Timing ----------
static const uint32_t WIFI_TIMEOUT_MS     = 20000UL;
static const uint32_t WIFI_RETRY_DELAY_MS = 300UL;
static const uint32_t MQTT_RETRY_DELAY_MS = 2000UL;
static const uint32_t PUBLISH_INTERVAL_MS = 10000UL;
static const uint32_t PUBLISH_MIN_GAP_MS  = 1000UL;
static const uint32_t PERSIST_INTERVAL_MS = 60000UL;
static const uint32_t HOUR_INTERVAL_MS    = 3600000UL;
static const uint32_t MAIN_LOOP_DELAY_MS  = 10UL;
static const uint32_t DISPLAY_INTERVAL_MS = 2000UL;
static const uint32_t BLE_NOTIFY_INTERVAL = 2000UL;
static const uint32_t RED_PULSE_DURATION_MS = 1000UL;

// -------- LED ----------
static const uint8_t LED_BRIGHTNESS = 50;
static const uint8_t LED_GREEN_R  = 0,   LED_GREEN_G  = 150, LED_GREEN_B  = 0;
static const uint8_t LED_RED_R    = 150, LED_RED_G    = 0,   LED_RED_B    = 0;
static const uint8_t LED_BLUE_R   = 0,   LED_BLUE_G   = 0,   LED_BLUE_B   = 150;
static const uint8_t LED_YELLOW_R = 150, LED_YELLOW_G = 100, LED_YELLOW_B = 0;
static const uint8_t LED_WHITE_R  = 120, LED_WHITE_G  = 120, LED_WHITE_B  = 120;
static const uint8_t LED_OFF_R    = 0,   LED_OFF_G    = 0,   LED_OFF_B    = 0;
static const uint32_t BLE_BLINK_INTERVAL_MS  = 500UL;
static const uint32_t WHITE_PULSE_DURATION_MS = 200UL;

// -------- Forward declarations ----------
static inline float mWhToKWh(uint32_t mwh);
void publishState(bool force);

// -------- NVS Keys ----------
static const char* NVS_NAMESPACE     = "gas";
static const char* NVS_KEY_TOTAL_MWH = "total_mWh";
static const char* NVS_KEY_SSID      = "wifi_ssid";
static const char* NVS_KEY_PASS      = "wifi_pass";
static const char* NVS_KEY_MQTT_HOST = "mqtt_host";
static const char* NVS_KEY_PULSE_VOL = "pulse_vol";
static const char* NVS_KEY_KWH_M3    = "kwh_m3";

//
// ============================================================
// ===================== GLOBALS ==============================
// ============================================================
//

WiFiClient   wifiClient;
PubSubClient mqtt(wifiClient);
Preferences  prefs;

Adafruit_NeoPixel strip(NUM_PIXELS, PIN_NEOPIXEL, NEO_GRB + NEO_KHZ800);
Adafruit_SSD1306  display(SCREEN_WIDTH, SCREEN_HEIGHT, &Wire, -1);

bool oledOk = false;

// Pulse counters (ISR-safe)
volatile uint32_t pulses_total   = 0;
volatile uint32_t pulses_hour    = 0;
volatile uint32_t pending_pulses = 0;
volatile uint32_t last_isr_us    = 0;
volatile bool     red_pulse_pending = false;

// LED state
bool     redActive  = false;
uint32_t redStartMs = 0;

// Hour window
uint32_t hourStartMs = 0;

// Persistence offset
float total_kwh_offset = 0.0f;

// Sensor pin tracking
int last_gpio_state = -1;

// Connectivity
bool mqttOnline = false;

// BLE
NimBLEServer*         pServer  = nullptr;
NimBLECharacteristic* pTxChar  = nullptr;
bool bleConnected = false;

// BLE command queue (set from callback, consumed in loop)
volatile bool pendingBleCmd = false;
String        bleCmd        = "";

//
// ============================================================
// ===================== CONFIG NVS ===========================
// ============================================================
//

void loadConfig() {
  prefs.begin(NVS_NAMESPACE, true);
  prefs.getString(NVS_KEY_SSID,      WIFI_SSID, sizeof(WIFI_SSID));
  prefs.getString(NVS_KEY_PASS,      WIFI_PASS, sizeof(WIFI_PASS));
  prefs.getString(NVS_KEY_MQTT_HOST, MQTT_HOST, sizeof(MQTT_HOST));
  pulse_volume_m3 = prefs.getFloat(NVS_KEY_PULSE_VOL, pulse_volume_m3);
  gas_kwh_per_m3  = prefs.getFloat(NVS_KEY_KWH_M3,    gas_kwh_per_m3);
  total_kwh_offset = mWhToKWh(prefs.getUInt(NVS_KEY_TOTAL_MWH, 0));
  prefs.end();
}

void saveConfig() {
  prefs.begin(NVS_NAMESPACE, false);
  prefs.putString(NVS_KEY_SSID,      WIFI_SSID);
  prefs.putString(NVS_KEY_PASS,      WIFI_PASS);
  prefs.putString(NVS_KEY_MQTT_HOST, MQTT_HOST);
  prefs.putFloat(NVS_KEY_PULSE_VOL,  pulse_volume_m3);
  prefs.putFloat(NVS_KEY_KWH_M3,     gas_kwh_per_m3);
  prefs.end();
}

//
// ============================================================
// ===================== UTIL =================================
// ============================================================
//

static inline float pulsesToKwh(uint32_t p) {
  return (p * pulse_volume_m3) * gas_kwh_per_m3;
}

static inline uint32_t kWhToMWh(float kwh) {
  if (kwh <= 0.0f) return 0U;
  double v = (double)kwh * 1000000.0;
  if (v > 4294967295.0) v = 4294967295.0;
  return (uint32_t)(v + 0.5);
}

static inline float mWhToKWh(uint32_t mwh) {
  return (float)mwh / 1000000.0f;
}

static inline void setLed(uint8_t r, uint8_t g, uint8_t b) {
  strip.setPixelColor(0, strip.Color(r, g, b));
  strip.show();
}

//
// ============================================================
// ===================== ISR ==================================
// ============================================================
//

void IRAM_ATTR isrPulse() {
  uint32_t now = (uint32_t)micros();
  if ((uint32_t)(now - last_isr_us) < 20000UL) return;
  last_isr_us = now;
  pulses_total++;
  pulses_hour++;
  pending_pulses++;
  red_pulse_pending = true;
}

//
// ============================================================
// ===================== BLE / NUS ============================
// ============================================================
//

class BleServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* pSrv, NimBLEConnInfo& connInfo) override {
    bleConnected = true;
    Serial.print("BLE client connected\r\n");
  }
  void onDisconnect(NimBLEServer* pSrv, NimBLEConnInfo& connInfo, int reason) override {
    bleConnected = false;
    Serial.print("BLE client disconnected\r\n");
    NimBLEDevice::startAdvertising();
  }
};

class BleRxCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* pChar, NimBLEConnInfo& connInfo) override {
    std::string val = pChar->getValue();
    if (!val.empty()) {
      bleCmd        = String(val.c_str());
      pendingBleCmd = true;
    }
  }
};

void bleSend(const String& json) {
  if (!bleConnected || pTxChar == nullptr) return;
  pTxChar->setValue((json + "\n").c_str());
  pTxChar->notify();
}

void bleSendState() {
  uint32_t t, h;
  noInterrupts();
  t = pulses_total;
  h = pulses_hour;
  interrupts();

  float total_kwh = total_kwh_offset + pulsesToKwh(t);
  float hour_kwh  = pulsesToKwh(h);

  char buf[200];
  snprintf(buf, sizeof(buf),
    "{\"type\":\"state\","
    "\"total_kwh\":%.3f,\"hour_kwh\":%.3f,"
    "\"pulses_total\":%u,\"pulses_hour\":%u,"
    "\"rssi\":%d,\"mqtt\":%s}",
    total_kwh, hour_kwh, t, h,
    WiFi.RSSI(),
    mqttOnline ? "true" : "false");

  bleSend(String(buf));
}

void bleSendConfig() {
  char buf[256];
  snprintf(buf, sizeof(buf),
    "{\"type\":\"config\","
    "\"ssid\":\"%s\",\"pass\":\"%s\",\"mqtt_host\":\"%s\","
    "\"pulse_vol\":%.4f,\"kwh_m3\":%.3f}",
    WIFI_SSID, WIFI_PASS, MQTT_HOST, pulse_volume_m3, gas_kwh_per_m3);

  bleSend(String(buf));
}

void bleSendAck(const char* cmd, bool ok = true) {
  char buf[80];
  snprintf(buf, sizeof(buf),
    "{\"ack\":%s,\"cmd\":\"%s\"}",
    ok ? "true" : "false", cmd);
  bleSend(String(buf));
}

void handleBleCommand(const String& raw) {
  Serial.printf("BLE RX: %s\r\n", raw.c_str());

  JsonDocument doc;
  DeserializationError err = deserializeJson(doc, raw);
  if (err) {
    Serial.printf("BLE JSON parse error: %s\r\n", err.c_str());
    bleSend("{\"error\":\"invalid json\"}");
    return;
  }

  const char* cmd = doc["cmd"];
  if (!cmd) {
    bleSend("{\"error\":\"missing cmd\"}");
    return;
  }

  if (strcmp(cmd, "get_state") == 0) {
    bleSendState();

  } else if (strcmp(cmd, "get_config") == 0) {
    bleSendConfig();

  } else if (strcmp(cmd, "reset") == 0) {
    noInterrupts();
    pulses_total      = 0;
    pulses_hour       = 0;
    pending_pulses    = 0;
    red_pulse_pending = false;
    interrupts();
    total_kwh_offset = 0.0f;
    hourStartMs = millis();
    prefs.begin(NVS_NAMESPACE, false);
    prefs.putUInt(NVS_KEY_TOTAL_MWH, 0);
    prefs.end();
    Serial.print("BLE: reset counters\r\n");
    bleSendAck("reset");
    publishState(true);

  } else if (strcmp(cmd, "set_config") == 0) {
    bool changed = false;

    if (doc["ssid"].is<const char*>()) {
      strlcpy(WIFI_SSID, doc["ssid"], sizeof(WIFI_SSID));
      changed = true;
    }
    if (doc["pass"].is<const char*>()) {
      strlcpy(WIFI_PASS, doc["pass"], sizeof(WIFI_PASS));
      changed = true;
    }
    if (doc["mqtt_host"].is<const char*>()) {
      strlcpy(MQTT_HOST, doc["mqtt_host"], sizeof(MQTT_HOST));
      changed = true;
    }
    if (doc["pulse_vol"].is<float>()) {
      pulse_volume_m3 = doc["pulse_vol"].as<float>();
      changed = true;
    }
    if (doc["kwh_m3"].is<float>()) {
      gas_kwh_per_m3 = doc["kwh_m3"].as<float>();
      changed = true;
    }

    if (changed) {
      saveConfig();
      Serial.print("BLE: config saved -> reboot\r\n");
      bleSendAck("set_config");
      delay(500);
      ESP.restart();
    } else {
      bleSendAck("set_config", false);
    }

  } else if (strcmp(cmd, "reboot") == 0) {
    bleSendAck("reboot");
    delay(300);
    ESP.restart();

  } else {
    bleSend("{\"error\":\"unknown cmd\"}");
  }
}

void bleInit() {
  // Build device name from last 2 MAC bytes
  uint64_t mac = ESP.getEfuseMac();
  char bleName[32];
  snprintf(bleName, sizeof(bleName), "GasCounter-%02X%02X",
           (uint8_t)(mac >> 8), (uint8_t)(mac));

  NimBLEDevice::init(bleName);
  NimBLEDevice::setPower(ESP_PWR_LVL_P9);

  pServer = NimBLEDevice::createServer();
  pServer->setCallbacks(new BleServerCallbacks());

  NimBLEService* pService = pServer->createService(NUS_SERVICE_UUID);

  // TX: notify (device → app)
  pTxChar = pService->createCharacteristic(
    NUS_TX_UUID,
    NIMBLE_PROPERTY::NOTIFY);

  // RX: write (app → device)
  NimBLECharacteristic* pRxChar = pService->createCharacteristic(
    NUS_RX_UUID,
    NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
  pRxChar->setCallbacks(new BleRxCallbacks());

  pService->start();

  NimBLEAdvertising* pAdv = NimBLEDevice::getAdvertising();
  pAdv->addServiceUUID(NUS_SERVICE_UUID);
  pAdv->start();

  Serial.printf("BLE advertising as: %s\r\n", bleName);
}

//
// ============================================================
// ===================== WIFI =================================
// ============================================================
//

void wifiConnect() {
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  Serial.printf("WiFi connecting to %s\r\n", WIFI_SSID);

  uint32_t start = millis();
  while (WiFi.status() != WL_CONNECTED) {
    delay(WIFI_RETRY_DELAY_MS);
    if ((uint32_t)(millis() - start) > WIFI_TIMEOUT_MS) {
      Serial.print("WiFi timeout -> reboot\r\n");
      delay(500);
      ESP.restart();
    }
  }
  Serial.printf("WiFi connected, IP=%s\r\n", WiFi.localIP().toString().c_str());
}

//
// ============================================================
// ===================== MQTT =================================
// ============================================================
//

void mqttConnect() {
  mqtt.setServer(MQTT_HOST, MQTT_PORT);

  while (!mqtt.connected()) {
    mqttOnline = false;
    Serial.printf("MQTT connecting to %s:%u\r\n", MQTT_HOST, MQTT_PORT);

    if (mqtt.connect(MQTT_CLIENT_ID, MQTT_TOPIC_AVAIL, 1, true, "offline")) {
      Serial.print("MQTT connected\r\n");
      mqtt.publish(MQTT_TOPIC_AVAIL, "online", true);
      mqttOnline = true;
      int s = digitalRead(PIN_SENSOR);
      mqtt.publish(MQTT_TOPIC_GPIO2, (s == LOW) ? "LOW" : "HIGH", true);
    } else {
      Serial.printf("MQTT connect failed rc=%d -> retry\r\n", mqtt.state());
      delay(MQTT_RETRY_DELAY_MS);
    }
  }
}

//
// ============================================================
// ===================== PUBLISH ==============================
// ============================================================
//

void publishState(bool force) {
  static uint32_t lastPublishMs = 0;
  static uint32_t lastForceMs   = 0;

  uint32_t now = millis();
  if (!force) {
    if ((uint32_t)(now - lastPublishMs) < PUBLISH_INTERVAL_MS) return;
  } else {
    if ((uint32_t)(now - lastForceMs) < PUBLISH_MIN_GAP_MS) return;
    lastForceMs = now;
  }
  lastPublishMs = now;

  uint32_t t, h;
  noInterrupts();
  t = pulses_total;
  h = pulses_hour;
  interrupts();

  float total_kwh = total_kwh_offset + pulsesToKwh(t);
  float hour_kwh  = pulsesToKwh(h);

  char payload[256];
  snprintf(payload, sizeof(payload),
    "{\"total_kwh\":%.3f,\"hour_kwh\":%.3f,"
    "\"pulses_total\":%u,\"pulses_hour\":%u,"
    "\"rssi\":%d}",
    total_kwh, hour_kwh, t, h, WiFi.RSSI());

  if (mqtt.connected()) {
    bool ok = mqtt.publish(MQTT_TOPIC_STATE, payload, true);
    Serial.printf("MQTT -> %s %s\r\n", MQTT_TOPIC_STATE, ok ? "OK" : "FAILED");
  }

  static uint32_t lastPersistMs = 0;
  if ((uint32_t)(now - lastPersistMs) >= PERSIST_INTERVAL_MS) {
    lastPersistMs = now;
    prefs.begin(NVS_NAMESPACE, false);
    prefs.putUInt(NVS_KEY_TOTAL_MWH, kWhToMWh(total_kwh));
    prefs.end();
  }
}

//
// ============================================================
// ===================== SENSOR GPIO ==========================
// ============================================================
//

void handleSensorChange() {
  int s = digitalRead(PIN_SENSOR);
  if (s != last_gpio_state) {
    last_gpio_state = s;
    Serial.printf("Sensor state=%s\r\n", (s == LOW) ? "LOW" : "HIGH");
    if (mqtt.connected()) {
      mqtt.publish(MQTT_TOPIC_GPIO2, (s == LOW) ? "LOW" : "HIGH", true);
    }
  }
}

//
// ============================================================
// ===================== LED ==================================
// ============================================================
//

void updateStatusLed() {
  uint32_t now = millis();

  // Weisser Puls bei Impuls (höchste Priorität)
  if (red_pulse_pending) {
    noInterrupts();
    red_pulse_pending = false;
    interrupts();
    redActive  = true;
    redStartMs = now;
  }
  if (redActive) {
    if ((uint32_t)(now - redStartMs) < WHITE_PULSE_DURATION_MS) {
      setLed(LED_WHITE_R, LED_WHITE_G, LED_WHITE_B);
      return;
    }
    redActive = false;
  }

  // BLE verbunden → Blau blinkend
  if (bleConnected) {
    bool on = ((now / BLE_BLINK_INTERVAL_MS) % 2) == 0;
    if (on) setLed(LED_BLUE_R, LED_BLUE_G, LED_BLUE_B);
    else     setLed(LED_OFF_R,  LED_OFF_G,  LED_OFF_B);
    return;
  }

  // MQTT verbunden → Grün
  if (mqttOnline) {
    setLed(LED_GREEN_R, LED_GREEN_G, LED_GREEN_B);
    return;
  }

  // WiFi verbunden, aber kein MQTT → Gelb
  if (WiFi.status() == WL_CONNECTED) {
    setLed(LED_YELLOW_R, LED_YELLOW_G, LED_YELLOW_B);
    return;
  }

  // Kein WiFi → Rot
  setLed(LED_RED_R, LED_RED_G, LED_RED_B);
}

//
// ============================================================
// ===================== OLED =================================
// ============================================================
//

void updateDisplay() {
  if (!oledOk) return;

  static uint32_t lastDisplayMs = 0;
  uint32_t now = millis();
  if ((uint32_t)(now - lastDisplayMs) < DISPLAY_INTERVAL_MS) return;
  lastDisplayMs = now;

  uint32_t t, h;
  noInterrupts();
  t = pulses_total;
  h = pulses_hour;
  interrupts();

  float total_kwh = total_kwh_offset + pulsesToKwh(t);
  float hour_kwh  = pulsesToKwh(h);

  display.clearDisplay();
  display.setTextColor(SSD1306_WHITE);

  display.setTextSize(1);
  display.setCursor(0, 0);
  display.print("GasCounter");
  display.setCursor(72, 0);
  if (bleConnected) {
    display.print("BLE");
  } else if (mqttOnline) {
    display.printf("R:%ddB", WiFi.RSSI());
  } else {
    display.print("OFFLINE");
  }

  display.drawFastHLine(0, 10, SCREEN_WIDTH, SSD1306_WHITE);

  display.setTextSize(2);
  display.setCursor(0, 14);
  display.printf("%.2f kWh", total_kwh);

  display.setTextSize(1);
  display.setCursor(0, 32);
  display.print("Gesamt");

  display.drawFastHLine(0, 42, SCREEN_WIDTH, SSD1306_WHITE);

  display.setCursor(0, 46);
  display.printf("Std: %.3f kWh", hour_kwh);
  display.setCursor(0, 56);
  display.printf("Pulse: %u", t);

  display.display();
}

//
// ============================================================
// ===================== BOOT Button ==========================
// ============================================================
//

void handleBootButton() {
  static bool lastBtn = true;
  bool btn = digitalRead(PIN_BUTTON);

  if (lastBtn && !btn) {
    noInterrupts();
    pulses_total = pulses_hour = pending_pulses = 0;
    red_pulse_pending = false;
    interrupts();

    total_kwh_offset = 0.0f;
    hourStartMs = millis();

    prefs.begin(NVS_NAMESPACE, false);
    prefs.putUInt(NVS_KEY_TOTAL_MWH, 0);
    prefs.end();

    Serial.print("BOOT: reset counters\r\n");
    publishState(true);
  }
  lastBtn = btn;
}

//
// ============================================================
// ===================== SETUP ================================
// ============================================================
//

void setup() {
  Serial.begin(115200);
  delay(300);
  Serial.print("\r\n=== GasCounter BLE+MQTT ===\r\n");

  pinMode(PIN_SENSOR, INPUT_PULLUP);
  pinMode(PIN_BUTTON, INPUT_PULLUP);
  attachInterrupt(digitalPinToInterrupt(PIN_SENSOR), isrPulse, FALLING);

  strip.begin();
  strip.setBrightness(LED_BRIGHTNESS);
  setLed(LED_OFF_R, LED_OFF_G, LED_OFF_B);

  Wire.begin(OLED_SDA, OLED_SCL);
  if (display.begin(SSD1306_SWITCHCAPVCC, OLED_ADDRESS)) {
    oledOk = true;
    display.clearDisplay();
    display.setTextSize(1);
    display.setTextColor(SSD1306_WHITE);
    display.setCursor(0, 0);
    display.print("GasCounter");
    display.setCursor(0, 16);
    display.print("Connecting...");
    display.display();
    Serial.print("OLED OK\r\n");
  } else {
    Serial.print("OLED FAILED\r\n");
  }

  // Load config + counter from NVS
  loadConfig();
  Serial.printf("Config: SSID=%s MQTT=%s pulse=%.4f kwh/m3=%.3f\r\n",
    WIFI_SSID, MQTT_HOST, pulse_volume_m3, gas_kwh_per_m3);

  hourStartMs = millis();

  bleInit();
  wifiConnect();
  mqttConnect();

  last_gpio_state = digitalRead(PIN_SENSOR);
  publishState(true);
}

//
// ============================================================
// ===================== LOOP =================================
// ============================================================
//

void loop() {
  updateStatusLed();
  updateDisplay();
  handleSensorChange();
  handleBootButton();

  // Process pending BLE command
  if (pendingBleCmd) {
    pendingBleCmd = false;
    handleBleCommand(bleCmd);
  }

  // Periodic BLE state notify
  if (bleConnected) {
    static uint32_t lastBleNotifyMs = 0;
    if ((uint32_t)(millis() - lastBleNotifyMs) >= BLE_NOTIFY_INTERVAL) {
      lastBleNotifyMs = millis();
      bleSendState();
    }
  }

  // WiFi/MQTT keepalive
  if (WiFi.status() != WL_CONNECTED) {
    mqttOnline = false;
    wifiConnect();
  }
  if (!mqtt.connected()) {
    mqttOnline = false;
    mqttConnect();
  }
  mqtt.loop();

  // Publish on pulse
  if (pending_pulses) {
    noInterrupts();
    pending_pulses = 0;
    interrupts();
    publishState(true);
  }

  publishState(false);

  // Hour rollover
  uint32_t now = millis();
  if ((uint32_t)(now - hourStartMs) >= HOUR_INTERVAL_MS) {
    hourStartMs += HOUR_INTERVAL_MS;
    noInterrupts();
    pulses_hour = 0;
    interrupts();
    Serial.print("Hour rollover\r\n");
    publishState(true);
  }

  delay(MAIN_LOOP_DELAY_MS);
}
