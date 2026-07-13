#include <BLEDevice.h>
#include <BLEUtils.h>
#include <BLEServer.h>
#include <BLEAdvertising.h>
#include <BLE2902.h>
#include <Preferences.h>
#include <esp_bt.h>
#include "SparkFun_UHF_RFID_Reader.h"
#include <Adafruit_NeoPixel.h>

// ============================================================================
// BABYCARE ESP32-S3
// Cyclic state machine: RFID_MONITORING -> RADAR_MEASUREMENT -> BLE_ALERT
//
// Main rule:
//   - The radar starts only when SEAT_TAG is present AND BABY_TAG is absent.
//   - After breathing is confirmed, the BLE alert remains active until
//     a NEW BABY_TAG reading is received.
//   - Reading the BABY_TAG acknowledges the alert and fully rearms the cycle.
// ============================================================================

// =========================== CONFIGURATION AREA =============================
// 1) RFID EPC IDENTIFIERS
const byte SEAT_TAG[] = {
    0xE2, 0x80, 0x11, 0x60, 0x60, 0x00, 0x02, 0x05, 0x2A, 0x10, 0x18, 0x3B
};

const byte BABY_TAG[] = {
    0xE2, 0x80, 0x11, 0x60, 0x60, 0x00, 0x02, 0x05, 0x2A, 0x10, 0x18, 0x39
};

// 2) EXISTING HARDWARE PINS
#define RFID_RX_PIN 18
#define RFID_TX_PIN 17
#define RESPIRATION_ADC_PIN 12

#define LED_PIN     48
#define NUM_LEDS    1
#define LED_STATUS  LED_BUILTIN

// 3) OPTIONAL POWER / ENABLE CONTROL PINS
// The original code did not include separate control pins for
// the PIFA antenna, patch antenna, or radar.
//
// Keep -1 when the function is controlled only by the RFID/radar module.
// Replace -1 with the actual GPIO if the board has an EN, RF_SWITCH,
// MOSFET, or dedicated load switch.
#define PIFA_ENABLE_PIN   -1
#define PATCH_ENABLE_PIN  -1
#define RADAR_ENABLE_PIN  -1

// Adjust the active levels if the hardware is active LOW.
static const uint8_t PIFA_ACTIVE_LEVEL  = HIGH;
static const uint8_t PATCH_ACTIVE_LEVEL = HIGH;
static const uint8_t RADAR_ACTIVE_LEVEL = HIGH;

// 4) RADAR THRESHOLDS
// Values retained from the original project.
static const int RADAR_THRESHOLD_HIGH = 1800;
static const int RADAR_THRESHOLD_LOW  = 1000;

// Number of required valid amplitude windows.
// Three 100 ms windows prevent an isolated value from triggering the alert.
static const uint8_t RADAR_REQUIRED_VALID_WINDOWS = 3;
// ============================================================================

// ============================== BLE ========================================
static const char* DEVICE_NAME_IDLE  = "BabyCare_ESP32";
static const char* DEVICE_NAME_ALERT = "ALERT_BabyCare_ESP32";

static const char* SERVICE_UUID          = "4fafc201-1fb5-459e-8fcc-c5c9c331914b";
static const char* WRITE_CHAR_UUID       = "beb5483e-36e1-4688-b7f5-ea07361c26a8";
static const char* STATE_CHAR_UUID       = "2a6d1c20-3a4e-4d3b-9f10-3e6e0f2f1111";
static const char* BABY_STATUS_CHAR_UUID = "b4e3f9a0-1c2d-4e5f-8a9b-0c1d2e3f4a5b";

static const char* NVS_NAMESPACE   = "babycare";
static const char* NVS_KEY_VEHICLE = "vehicle_name";
static const char* PAYLOAD_PREFIX  = "BABYCARE|";
static const char* ACK_PREFIX      = "ACK|";

static const size_t MAX_VEHICLE_NAME_LEN = 15;

// The GATT alert is repeated without saturating the link.
// ALERT advertising remains continuously active between notifications.
static const unsigned long BLE_ALERT_REPEAT_MS = 2500;
static const unsigned long HEARTBEAT_MS         = 8000;

// Disconnects the GATT client before radar acquisition to eliminate BLE
// connection events during measurement. The client can reconnect afterward.
static const bool DISCONNECT_BLE_CLIENT_DURING_RADAR = true;

// ============================== RFID =======================================
#define RFID_BAUD_RATE   115200
#define RFID_MODULE_TYPE ThingMagic_M7E_HECTO

static const int16_t RFID_READ_POWER_CDBM = 1500;

// Duty cycle retained from the original project.
static const bool          RFID_CONTINUOUS_SCAN = false;
static const unsigned long RFID_SCAN_PERIOD_MS  = 2000;
static const unsigned long RFID_SCAN_ON_MS      = 200;

// A tag is considered present only if it was read recently.
// This value must remain longer than the RFID scan period.
static const unsigned long TAG_PRESENCE_TIMEOUT_MS = 4500;

// The "seat present / baby absent" combination must remain stable before radar acquisition.
static const unsigned long RFID_COMBINATION_STABLE_MS = 1000;

static const unsigned long TAG_LOG_COOLDOWN_MS = 1500;
static const unsigned long RFID_STATUS_LOG_MS  = 5000;

// After a radar window with no breathing, the system returns to RFID monitoring and
// waits before starting another window. It never remains permanently blocked.
static const unsigned long RADAR_RETRY_INTERVAL_MS = 20000;

// ============================== RADAR ======================================
// Sliding median filter applied to raw ADC samples.
static const int RADAR_MEDIAN_WINDOW = 9;  // must be odd

// Arithmetic moving average applied to successive amplitudes.
// Each smoothed value uses exactly the latest 15 radar amplitudes.
// Threshold validation begins only when these 15 values are
// available, so the decision always relies on a complete window.
static const uint8_t RADAR_MOVING_AVERAGE_WINDOW = 15;

static const unsigned long RADAR_SAMPLE_PERIOD_MS  = 2;
static const unsigned long RADAR_AMPLITUDE_WINDOW_MS = 100;
static const unsigned long RADAR_SETTLE_MS          = 2000;
static const unsigned long RADAR_MEASURE_MS         = 10000;

// ============================ STATE MACHINE =================================
enum SystemState {
    RFID_MONITORING,
    RADAR_MEASUREMENT,
    BLE_ALERT
};

enum RadarPhase {
    RADAR_SETTLING,
    RADAR_ACQUIRING
};

// =========================== HARDWARE OBJECTS ================================
RFID rfidModule;
Adafruit_NeoPixel pixel(NUM_LEDS, LED_PIN, NEO_GRB + NEO_KHZ800);

BLEServer*         pServer                   = nullptr;
BLECharacteristic* pWriteCharacteristic      = nullptr;
BLECharacteristic* pStateCharacteristic      = nullptr;
BLECharacteristic* pBabyStatusCharacteristic = nullptr;
Preferences        preferences;

// ============================ GLOBAL VARIABLES ===============================
SystemState systemState = RFID_MONITORING;
RadarPhase  radarPhase  = RADAR_SETTLING;

unsigned long stateEnteredMs = 0;

// --- RFID ---
bool rfidReady      = false;
bool rfidEnabled    = false;
bool rfidScanActive = false;

bool          seatTagHasCurrentReading = false;
bool          babyTagHasCurrentReading = false;
unsigned long lastSeatTagSeenMs        = 0;
unsigned long lastBabyTagSeenMs        = 0;
unsigned long seatOnlyConditionSinceMs = 0;

unsigned long lastRfidScanToggleMs = 0;
unsigned long lastRfidStatusLogMs  = 0;
unsigned long lastRadarAttemptMs   = 0;

String        lastLoggedTagEpc = "";
unsigned long lastLoggedTagMs  = 0;

bool babyTagDetectedThisLoop = false;

// --- BLE ---
String vehicleName = "Unknown Vehicle";

bool bleConnected        = false;
bool blePausedForRadar   = false;
bool bleAlertActive      = false;
bool alarmBlinkState     = false;

unsigned long lastBleAlertMs   = 0;
unsigned long lastAlarmBlinkMs = 0;
unsigned long lastHeartbeatMs  = 0;

// --- Radar ---
bool radarRunning               = false;
bool radarBreathingConfirmed  = false;
bool radarThresholdActive       = false;

unsigned long radarPhaseStartedMs    = 0;
unsigned long lastRadarSampleMs      = 0;
unsigned long radarAmplitudeWindowMs = 0;

int radarSamples[RADAR_MEDIAN_WINDOW];
int radarSampleIndex = 0;
bool radarWindowFull = false;

int radarMinValue = 4095;
int radarMaxValue = 0;

// Raw amplitude from the latest 100 ms window.
int radarRawAmplitude = 0;

// Moving average of 15 successive amplitudes. This smoothed value is
// compared with the RADAR_THRESHOLD_HIGH and
// RADAR_THRESHOLD_LOW thresholds when the buffer is full.
int radarAmplitude = 0;
int radarAmplitudeHistory[RADAR_MOVING_AVERAGE_WINDOW];
uint8_t radarAmplitudeHistoryIndex = 0;
uint8_t radarAmplitudeHistoryCount = 0;
int32_t radarAmplitudeHistorySum = 0;

uint8_t radarValidWindowCount = 0;

// ============================== PROTOTYPES =================================
boolean setupRfidModule(long baudRate);

void activateRfid();
void deactivateRfidAndAntennas();
void startRadar();
void stopRadar();
void startBleAlert();
void stopBleAlert();
void resetCompleteCycle();

void updateRfidDutyCycle(unsigned long now);
void processRfidResponses(unsigned long now);
void updateStateMachine(unsigned long now);
void updateRadarAcquisition(unsigned long now);
void updateBleAlert(unsigned long now);
void updateAlarmLed(unsigned long now);

void enterRfidMonitoringAfterNoBreathing(unsigned long now);
void enterRadarMeasurement(unsigned long now);
void enterBleAlert(unsigned long now);
void acknowledgeAlertWithBabyTag(unsigned long now);

void pauseBleForRadar();
void resumeBleAfterRadar();
void updateAdvertising();
void publishBleState(bool isAlert, bool notifyClient);
void publishBabyStatus(const char* status);

void clearRfidPresenceCache();
bool isSeatTagPresent(unsigned long now);
bool isBabyTagPresent(unsigned long now);

void resetRadarData();
int medianValue(const int* values, int count);
int updateRadarAmplitudeMovingAverage(int newAmplitude);

bool tagMatches(const byte* expectedTag, byte expectedLen);
String currentTagEpcHex();
bool shouldLogTag(const String& epc, unsigned long now);

// ============================== GPIO HELPERS =================================
void configureOptionalOutput(int pin, uint8_t activeLevel) {
    if (pin < 0) return;
    pinMode(pin, OUTPUT);
    digitalWrite(pin, activeLevel == HIGH ? LOW : HIGH);
}

void setOptionalOutput(int pin, uint8_t activeLevel, bool enabled) {
    if (pin < 0) return;
    digitalWrite(pin, enabled ? activeLevel : (activeLevel == HIGH ? LOW : HIGH));
}

void setRfidAntennasEnabled(bool enabled) {
    setOptionalOutput(PIFA_ENABLE_PIN,  PIFA_ACTIVE_LEVEL,  enabled);
    setOptionalOutput(PATCH_ENABLE_PIN, PATCH_ACTIVE_LEVEL, enabled);
}

// =============================== LED =======================================
void setColor(uint8_t r, uint8_t g, uint8_t b) {
    pixel.setPixelColor(0, pixel.Color(r, g, b));
    pixel.show();
}

void ledOff()   { setColor(0, 0, 0); }
void ledRed()   { setColor(255, 0, 0); }
void ledGreen() { setColor(0, 255, 0); }
void ledBlue()  { setColor(0, 0, 255); }

// ============================== BLE CALLBACKS ================================
class ServerCallbacks : public BLEServerCallbacks {
    void onConnect(BLEServer* server) override {
        (void)server;
        bleConnected = true;
        Serial.println("[BLE] Client connected");
    }

    void onDisconnect(BLEServer* server) override {
        (void)server;
        bleConnected = false;
        Serial.println("[BLE] Client disconnected");

        // Never restart advertising during radar measurement.
        if (!blePausedForRadar) {
            BLEDevice::startAdvertising();
        }
    }
};

String sanitizeVehicleName(String value) {
    value.trim();

    if (value.length() == 0) {
        value = "Unknown Vehicle";
    }

    if (value.length() > MAX_VEHICLE_NAME_LEN) {
        value = value.substring(0, MAX_VEHICLE_NAME_LEN);
    }

    return value;
}

void saveVehicleName(const String& value) {
    vehicleName = sanitizeVehicleName(value);
    preferences.putString(NVS_KEY_VEHICLE, vehicleName);
}

class NameWriteCallbacks : public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic* characteristic) override {
        String writtenUuid = String(characteristic->getUUID().toString().c_str());

        if (!writtenUuid.equalsIgnoreCase(WRITE_CHAR_UUID)) {
            Serial.print("[BLE] Write ignored for UUID: ");
            Serial.println(writtenUuid);
            return;
        }

        String receivedValue = characteristic->getValue();
        if (receivedValue.length() == 0) return;

        saveVehicleName(receivedValue);

        String acknowledgement = String(ACK_PREFIX) + vehicleName;
        characteristic->setValue(acknowledgement.c_str());

        Serial.print("[BLE] Vehicle name updated: ");
        Serial.println(vehicleName);

        updateAdvertising();
    }
};

// =============================== BLE =======================================
void updateAdvertising() {
    if (blePausedForRadar) {
        return;
    }

    BLEAdvertising* advertising = BLEDevice::getAdvertising();

    String payload = String(PAYLOAD_PREFIX) + vehicleName;
    const char* advertisedName = bleAlertActive
        ? DEVICE_NAME_ALERT
        : DEVICE_NAME_IDLE;

    BLEAdvertisementData advertisementData;
    advertisementData.setManufacturerData(payload.c_str());
    advertisementData.setFlags(0x06);

    BLEAdvertisementData scanResponseData;
    scanResponseData.setName(advertisedName);

    advertising->stop();
    advertising->setAdvertisementData(advertisementData);
    advertising->setScanResponseData(scanResponseData);
    advertising->setScanResponse(true);
    advertising->start();

    Serial.print("[BLE] Advertising: ");
    Serial.print(advertisedName);
    Serial.print(" | payload=");
    Serial.println(payload);
}

void publishBleState(bool isAlert, bool notifyClient) {
    const char* value = isAlert ? "ALERT" : "IDLE";

    if (pStateCharacteristic != nullptr) {
        pStateCharacteristic->setValue(value);

        if (notifyClient && bleConnected && !blePausedForRadar) {
            pStateCharacteristic->notify();
        }
    }

    Serial.print("[BLE] State=");
    Serial.println(value);
}

void publishBabyStatus(const char* status) {
    if (pBabyStatusCharacteristic == nullptr) return;

    pBabyStatusCharacteristic->setValue(status);

    if (bleConnected && !blePausedForRadar) {
        pBabyStatusCharacteristic->notify();
    }

    Serial.print("[BLE] Baby status=");
    Serial.println(status);
}

void pauseBleForRadar() {
    if (blePausedForRadar) return;

    blePausedForRadar = true;
    BLEDevice::getAdvertising()->stop();

    // A connected client would normally continue generating radio events.
    // It is disconnected before radar settling. The callback
    // onDisconnect() does not restart advertising because blePausedForRadar=true.
    if (DISCONNECT_BLE_CLIENT_DURING_RADAR &&
        bleConnected &&
        pServer != nullptr) {
        pServer->disconnect(pServer->getConnId());
        Serial.println("[BLE] Client disconnected for radar measurement");
    }

    Serial.println("[BLE] Advertising and notifications suspended for radar measurement");
}

void resumeBleAfterRadar() {
    if (!blePausedForRadar) return;

    blePausedForRadar = false;
    updateAdvertising();

    Serial.println("[BLE] Communication resumed");
}

void startBleAlert() {
    if (bleAlertActive) return;

    bleAlertActive = true;
    lastBleAlertMs = 0;

    // The advertising name becomes ALERT_BabyCare_ESP32.
    updateAdvertising();

    // Send the first alert immediately.
    publishBleState(true, true);
    publishBabyStatus("UNKNOWN|BPM=0|NORMAL");

    lastBleAlertMs = millis();

    Serial.println("[ALERT] BLE alert active until BABY_TAG returns");
}

void stopBleAlert() {
    if (!bleAlertActive) return;

    bleAlertActive = false;

    publishBleState(false, true);
    publishBabyStatus("UNKNOWN|BPM=0|NORMAL");
    updateAdvertising();

    digitalWrite(LED_STATUS, HIGH);
    ledGreen();

    Serial.println("[ALERT] BLE alert stopped by BABY_TAG");
}

void updateBleAlert(unsigned long now) {
    if (systemState != BLE_ALERT || !bleAlertActive) return;

    if (now - lastBleAlertMs < BLE_ALERT_REPEAT_MS) return;

    lastBleAlertMs = now;

    // ALERT advertising is already transmitted continuously.
    // This GATT notification is repeated for connected clients.
    publishBleState(true, true);

    Serial.println("[ALERT] BLE ALERT notification repeated");
}

// =============================== RFID ======================================
String currentTagEpcHex() {
    String epc = "";
    byte epcLength = rfidModule.getTagEPCBytes();

    for (byte i = 0; i < epcLength; i++) {
        if (rfidModule.msg[31 + i] < 0x10) {
            epc += "0";
        }

        epc += String(rfidModule.msg[31 + i], HEX);
    }

    epc.toUpperCase();
    return epc;
}

bool tagMatches(const byte* expectedTag, byte expectedLen) {
    byte epcLength = rfidModule.getTagEPCBytes();

    if (epcLength != expectedLen) {
        return false;
    }

    for (byte i = 0; i < epcLength; i++) {
        if (rfidModule.msg[31 + i] != expectedTag[i]) {
            return false;
        }
    }

    return true;
}

bool shouldLogTag(const String& epc, unsigned long now) {
    if (epc == lastLoggedTagEpc &&
        now - lastLoggedTagMs < TAG_LOG_COOLDOWN_MS) {
        return false;
    }

    lastLoggedTagEpc = epc;
    lastLoggedTagMs  = now;
    return true;
}

void clearRfidSerialBuffer() {
    while (Serial1.available() > 0) {
        Serial1.read();
    }
}

void clearRfidPresenceCache() {
    seatTagHasCurrentReading = false;
    babyTagHasCurrentReading = false;

    lastSeatTagSeenMs = 0;
    lastBabyTagSeenMs = 0;

    seatOnlyConditionSinceMs = 0;
}

bool isSeatTagPresent(unsigned long now) {
    if (!seatTagHasCurrentReading) return false;

    if (now - lastSeatTagSeenMs > TAG_PRESENCE_TIMEOUT_MS) {
        seatTagHasCurrentReading = false;
        return false;
    }

    return true;
}

bool isBabyTagPresent(unsigned long now) {
    if (!babyTagHasCurrentReading) return false;

    if (now - lastBabyTagSeenMs > TAG_PRESENCE_TIMEOUT_MS) {
        babyTagHasCurrentReading = false;
        return false;
    }

    return true;
}

void activateRfid() {
    if (!rfidReady || rfidEnabled) return;

    setRfidAntennasEnabled(true);
    clearRfidSerialBuffer();

    rfidModule.startReading();

    rfidEnabled          = true;
    rfidScanActive       = true;
    lastRfidScanToggleMs = millis();

    Serial.println("[RFID] Reader + antennas enabled");
}

void deactivateRfidAndAntennas() {
    if (!rfidReady) return;

    if (rfidScanActive || rfidEnabled) {
        rfidModule.stopReading();
    }

    rfidEnabled    = false;
    rfidScanActive = false;

    clearRfidSerialBuffer();
    setRfidAntennasEnabled(false);

    Serial.println("[RFID] Reader + antennas disabled");
}

void updateRfidDutyCycle(unsigned long now) {
    if (!rfidReady || !rfidEnabled) return;

    if (RFID_CONTINUOUS_SCAN) {
        if (!rfidScanActive) {
            rfidModule.startReading();
            rfidScanActive = true;
            lastRfidScanToggleMs = now;
        }
        return;
    }

    const unsigned long offDurationMs =
        RFID_SCAN_PERIOD_MS - RFID_SCAN_ON_MS;

    if (rfidScanActive) {
        if (now - lastRfidScanToggleMs >= RFID_SCAN_ON_MS) {
            rfidModule.stopReading();
            rfidScanActive = false;
            lastRfidScanToggleMs = now;
        }
    } else {
        if (now - lastRfidScanToggleMs >= offDurationMs) {
            rfidModule.startReading();
            rfidScanActive = true;
            lastRfidScanToggleMs = now;
        }
    }
}

void processRfidResponses(unsigned long now) {
    if (!rfidReady || !rfidEnabled) return;

    while (rfidModule.check() == true) {
        byte responseType = rfidModule.parseResponse();

        if (responseType == RESPONSE_IS_TAGFOUND) {
            String epc = currentTagEpcHex();
            int rssi = rfidModule.getTagRSSI();
            bool logTag = shouldLogTag(epc, now);

            if (logTag) {
                Serial.print("[RFID] EPC=");
                Serial.print(epc);
                Serial.print(" | RSSI=");
                Serial.println(rssi);
            }

            if (tagMatches(SEAT_TAG, sizeof(SEAT_TAG))) {
                seatTagHasCurrentReading = true;
                lastSeatTagSeenMs = now;

                if (logTag) {
                    Serial.println("[RFID] SEAT_TAG present");
                }
            } else if (tagMatches(BABY_TAG, sizeof(BABY_TAG))) {
                babyTagHasCurrentReading = true;
                lastBabyTagSeenMs = now;
                babyTagDetectedThisLoop = true;

                if (logTag) {
                    Serial.println("[RFID] BABY_TAG present");
                }
            } else if (logTag) {
                Serial.println("[RFID] Unknown tag ignored");
            }
        } else if (responseType != RESPONSE_IS_KEEPALIVE) {
            Serial.print("[RFID] Non-tag response: 0x");
            Serial.println(responseType, HEX);
        }
    }
}

// =============================== RADAR =====================================
int updateRadarAmplitudeMovingAverage(int newAmplitude) {
    // When the buffer is full, subtract the oldest value from the sum
    // before replacing it with the new amplitude.
    if (radarAmplitudeHistoryCount == RADAR_MOVING_AVERAGE_WINDOW) {
        radarAmplitudeHistorySum -=
            radarAmplitudeHistory[radarAmplitudeHistoryIndex];
    } else {
        radarAmplitudeHistoryCount++;
    }

    radarAmplitudeHistory[radarAmplitudeHistoryIndex] = newAmplitude;
    radarAmplitudeHistorySum += newAmplitude;

    radarAmplitudeHistoryIndex =
        (radarAmplitudeHistoryIndex + 1) %
        RADAR_MOVING_AVERAGE_WINDOW;

    return static_cast<int>(
        radarAmplitudeHistorySum / radarAmplitudeHistoryCount
    );
}

int medianValue(const int* values, int count) {
    if (count <= 0) return 0;

    int copy[RADAR_MEDIAN_WINDOW];

    for (int i = 0; i < count; i++) {
        copy[i] = values[i];
    }

    for (int i = 1; i < count; i++) {
        int key = copy[i];
        int j = i - 1;

        while (j >= 0 && copy[j] > key) {
            copy[j + 1] = copy[j];
            j--;
        }

        copy[j + 1] = key;
    }

    return copy[count / 2];
}

void resetRadarData() {
    for (int i = 0; i < RADAR_MEDIAN_WINDOW; i++) {
        radarSamples[i] = 2048;
    }

    radarSampleIndex = 0;
    radarWindowFull  = false;

    radarMinValue = 4095;
    radarMaxValue = 0;
    radarRawAmplitude = 0;
    radarAmplitude = 0;

    for (int i = 0; i < RADAR_MOVING_AVERAGE_WINDOW; i++) {
        radarAmplitudeHistory[i] = 0;
    }

    radarAmplitudeHistoryIndex = 0;
    radarAmplitudeHistoryCount = 0;
    radarAmplitudeHistorySum   = 0;

    radarThresholdActive      = false;
    radarBreathingConfirmed = false;
    radarValidWindowCount     = 0;

    lastRadarSampleMs      = 0;
    radarAmplitudeWindowMs = millis();
}

void startRadar() {
    if (radarRunning) return;

    resetRadarData();

    setOptionalOutput(
        RADAR_ENABLE_PIN,
        RADAR_ACTIVE_LEVEL,
        true
    );

    radarRunning        = true;
    radarPhase          = RADAR_SETTLING;
    radarPhaseStartedMs = millis();

    Serial.println("[RADAR] Enabled - settling phase");
}

void stopRadar() {
    if (!radarRunning) return;

    radarRunning = false;

    setOptionalOutput(
        RADAR_ENABLE_PIN,
        RADAR_ACTIVE_LEVEL,
        false
    );

    Serial.println("[RADAR] Stopped");
}

void updateRadarAcquisition(unsigned long now) {
    if (!radarRunning || radarPhase != RADAR_ACQUIRING) return;

    if (now - lastRadarSampleMs < RADAR_SAMPLE_PERIOD_MS) return;
    lastRadarSampleMs = now;

    int rawValue = analogRead(RESPIRATION_ADC_PIN);

    radarSamples[radarSampleIndex] = rawValue;
    radarSampleIndex =
        (radarSampleIndex + 1) % RADAR_MEDIAN_WINDOW;

    if (radarSampleIndex == 0) {
        radarWindowFull = true;
    }

    int activeSampleCount = radarWindowFull
        ? RADAR_MEDIAN_WINDOW
        : radarSampleIndex;

    int filteredValue = medianValue(
        radarSamples,
        activeSampleCount
    );

    if (filteredValue < radarMinValue) {
        radarMinValue = filteredValue;
    }

    if (filteredValue > radarMaxValue) {
        radarMaxValue = filteredValue;
    }

    if (now - radarAmplitudeWindowMs <
        RADAR_AMPLITUDE_WINDOW_MS) {
        return;
    }

    radarRawAmplitude = radarMaxValue - radarMinValue;

    // Smooth successive amplitudes before applying the thresholds.
    radarAmplitude = updateRadarAmplitudeMovingAverage(
        radarRawAmplitude
    );

    const bool radarMovingAverageReady =
        radarAmplitudeHistoryCount == RADAR_MOVING_AVERAGE_WINDOW;

    // Noise-resistant validation only when all 15 required amplitudes
    // are available for the moving average.
    if (radarMovingAverageReady) {
        // - above the high threshold: one additional valid smoothed window;
        // - below the low threshold: reset;
        // - between both thresholds: hysteresis, without a new confirmation.
        if (radarAmplitude >= RADAR_THRESHOLD_HIGH) {
            radarThresholdActive = true;

            if (radarValidWindowCount < 255) {
                radarValidWindowCount++;
            }
        } else {
            // A smoothed window below the high threshold breaks the consecutive sequence.
            radarValidWindowCount = 0;

            if (radarAmplitude <= RADAR_THRESHOLD_LOW) {
                radarThresholdActive = false;
            }
        }
    } else {
        radarValidWindowCount = 0;
    }

    Serial.print("[RADAR] raw_amplitude=");
    Serial.print(radarRawAmplitude);
    Serial.print(" | moving_average_15=");
    Serial.print(radarAmplitude);
    Serial.print(" | average_values=");
    Serial.print(radarAmplitudeHistoryCount);
    Serial.print("/");
    Serial.print(RADAR_MOVING_AVERAGE_WINDOW);
    Serial.print(" | confirmations=");
    Serial.print(radarValidWindowCount);
    Serial.print("/");
    Serial.println(RADAR_REQUIRED_VALID_WINDOWS);

    if (radarValidWindowCount >=
        RADAR_REQUIRED_VALID_WINDOWS) {
        radarBreathingConfirmed = true;
    }

    radarMinValue = 4095;
    radarMaxValue = 0;
    radarAmplitudeWindowMs = now;
}

// ============================ STATE TRANSITIONS =============================
const char* stateName(SystemState state) {
    switch (state) {
        case RFID_MONITORING:   return "RFID_MONITORING";
        case RADAR_MEASUREMENT: return "RADAR_MEASUREMENT";
        case BLE_ALERT:         return "BLE_ALERT";
        default:                return "UNKNOWN";
    }
}

void logStateTransition(
    SystemState oldState,
    SystemState newState,
    const char* reason
) {
    Serial.print("[STATE] ");
    Serial.print(stateName(oldState));
    Serial.print(" -> ");
    Serial.print(stateName(newState));
    Serial.print(" | ");
    Serial.println(reason);
}

void enterRadarMeasurement(unsigned long now) {
    SystemState oldState = systemState;
    systemState = RADAR_MEASUREMENT;
    stateEnteredMs = now;

    logStateTransition(
        oldState,
        systemState,
        "only SEAT_TAG is present"
    );

    // Only one radar measurement can be active.
    lastRadarAttemptMs = now;
    seatOnlyConditionSinceMs = 0;

    // Previous RFID readings are never reused after radar measurement.
    clearRfidPresenceCache();

    // Required order: RFID/antennas OFF, BLE silent, then radar.
    deactivateRfidAndAntennas();
    pauseBleForRadar();
    startRadar();

    digitalWrite(LED_STATUS, HIGH);
    ledBlue();
}

void enterBleAlert(unsigned long now) {
    SystemState oldState = systemState;
    systemState = BLE_ALERT;
    stateEnteredMs = now;

    logStateTransition(
        oldState,
        systemState,
        "breathing confirmed"
    );

    stopRadar();

    // The BABY_TAG must be read again AFTER entering the alert state.
    clearRfidPresenceCache();

    // Resume communications before sending the first alert.
    resumeBleAfterRadar();
    activateRfid();
    startBleAlert();
}

void enterRfidMonitoringAfterNoBreathing(unsigned long now) {
    SystemState oldState = systemState;
    systemState = RFID_MONITORING;
    stateEnteredMs = now;

    logStateTransition(
        oldState,
        systemState,
        "radar window ended with no breathing"
    );

    stopRadar();
    resetRadarData();

    // Restart with fresh RFID readings.
    clearRfidPresenceCache();

    resumeBleAfterRadar();
    activateRfid();

    digitalWrite(LED_STATUS, HIGH);
    ledGreen();

    // lastRadarAttemptMs is intentionally preserved:
    // it enforces RADAR_RETRY_INTERVAL_MS before a new window.
}

void resetCompleteCycle() {
    // This function clears all cycle locks and data.
    stopRadar();
    stopBleAlert();

    resetRadarData();
    clearRfidPresenceCache();

    lastRadarAttemptMs = 0;
    seatOnlyConditionSinceMs = 0;
    babyTagDetectedThisLoop = false;

    alarmBlinkState = false;
    lastAlarmBlinkMs = 0;
    lastBleAlertMs = 0;

    Serial.println("[CYCLE] Cycle variables fully reset");
}

void acknowledgeAlertWithBabyTag(unsigned long now) {
    if (systemState != BLE_ALERT) return;

    SystemState oldState = systemState;

    // The only normal exit from BLE_ALERT is a current BABY_TAG reading.
    stopBleAlert();
    resetCompleteCycle();

    // The reading that acknowledged the alert is a current presence,
    // not an old value. It is retained to prevent radar from restarting
    // while the baby tag remains physically present.
    babyTagHasCurrentReading = true;
    lastBabyTagSeenMs = now;

    resumeBleAfterRadar();
    activateRfid();

    systemState = RFID_MONITORING;
    stateEnteredMs = now;

    logStateTransition(
        oldState,
        systemState,
        "BABY_TAG detected: acknowledgment and rearming"
    );

    digitalWrite(LED_STATUS, HIGH);
    ledGreen();
}

// ======================== STATE MACHINE HANDLING =============================
void handleRfidMonitoring(unsigned long now) {
    bool seatPresent = isSeatTagPresent(now);
    bool babyPresent = isBabyTagPresent(now);

    // ONLY condition that allows radar measurement:
    // SEAT_TAG present AND BABY_TAG absent.
    if (seatPresent && !babyPresent) {
        if (seatOnlyConditionSinceMs == 0) {
            seatOnlyConditionSinceMs = now;
        }

        bool combinationStable =
            now - seatOnlyConditionSinceMs >=
            RFID_COMBINATION_STABLE_MS;

        bool retryAllowed =
            lastRadarAttemptMs == 0 ||
            now - lastRadarAttemptMs >=
            RADAR_RETRY_INTERVAL_MS;

        if (combinationStable && retryAllowed) {
            enterRadarMeasurement(now);
        }
    } else {
        // Any other combination cancels the current validation:
        // - seat + baby;
        // - no seat;
        // - no valid tag.
        seatOnlyConditionSinceMs = 0;
    }
}

void handleRadarMeasurement(unsigned long now) {
    if (!radarRunning) return;

    if (radarPhase == RADAR_SETTLING) {
        if (now - radarPhaseStartedMs >= RADAR_SETTLE_MS) {
            // Reset again after settling to remove
            // transients caused by disabling the radios.
            resetRadarData();

            radarPhase = RADAR_ACQUIRING;
            radarPhaseStartedMs = now;
            radarAmplitudeWindowMs = now;

            Serial.println("[RADAR] Clean measurement window started");
        }
        return;
    }

    updateRadarAcquisition(now);

    if (radarBreathingConfirmed) {
        // Transition immediately when multiple windows confirm breathing.
        enterBleAlert(now);
        return;
    }

    if (now - radarPhaseStartedMs >= RADAR_MEASURE_MS) {
        // No permanent lockup: return cleanly to RFID monitoring.
        enterRfidMonitoringAfterNoBreathing(now);
    }
}

void handleBleAlert(unsigned long now) {
    (void)now;

    // Seat absence, timeouts, and all other conditions
    // cannot stop the alert.
    if (babyTagDetectedThisLoop) {
        acknowledgeAlertWithBabyTag(millis());
    }
}

void updateStateMachine(unsigned long now) {
    switch (systemState) {
        case RFID_MONITORING:
            handleRfidMonitoring(now);
            break;

        case RADAR_MEASUREMENT:
            handleRadarMeasurement(now);
            break;

        case BLE_ALERT:
            handleBleAlert(now);
            break;
    }
}

// ============================== ALARM SIGNAL =================================
void updateAlarmLed(unsigned long now) {
    if (systemState != BLE_ALERT || !bleAlertActive) return;

    if (now - lastAlarmBlinkMs < 120) return;

    lastAlarmBlinkMs = now;
    alarmBlinkState = !alarmBlinkState;

    digitalWrite(
        LED_STATUS,
        alarmBlinkState ? HIGH : LOW
    );

    if (alarmBlinkState) {
        ledRed();
    } else {
        ledOff();
    }
}

// ================================ SETUP ====================================
void setup() {
    Serial.begin(115200);
    delay(1000);

    Serial.println();
    Serial.println("==================================================");
    Serial.println("BabyCare ESP32-S3 - cyclic state machine");
    Serial.println("==================================================");

    pinMode(LED_STATUS, OUTPUT);

    pixel.begin();
    ledBlue();

    configureOptionalOutput(
        PIFA_ENABLE_PIN,
        PIFA_ACTIVE_LEVEL
    );

    configureOptionalOutput(
        PATCH_ENABLE_PIN,
        PATCH_ACTIVE_LEVEL
    );

    configureOptionalOutput(
        RADAR_ENABLE_PIN,
        RADAR_ACTIVE_LEVEL
    );

    // ------------------------------ NVS ------------------------------------
    preferences.begin(NVS_NAMESPACE, false);

    vehicleName = preferences.getString(
        NVS_KEY_VEHICLE,
        "Unknown Vehicle"
    );

    vehicleName = sanitizeVehicleName(vehicleName);

    Serial.print("[NVS] Vehicle=");
    Serial.println(vehicleName);

    // ------------------------------ BLE ------------------------------------
    BLEDevice::init(DEVICE_NAME_IDLE);

    esp_ble_tx_power_set(
        ESP_BLE_PWR_TYPE_DEFAULT,
        ESP_PWR_LVL_P18
    );

    esp_ble_tx_power_set(
        ESP_BLE_PWR_TYPE_ADV,
        ESP_PWR_LVL_P18
    );

    pServer = BLEDevice::createServer();
    pServer->setCallbacks(new ServerCallbacks());

    BLEService* service =
        pServer->createService(SERVICE_UUID);

    pWriteCharacteristic =
        service->createCharacteristic(
            WRITE_CHAR_UUID,
            BLECharacteristic::PROPERTY_WRITE |
            BLECharacteristic::PROPERTY_READ
        );

    pWriteCharacteristic->setCallbacks(
        new NameWriteCallbacks()
    );

    pWriteCharacteristic->setValue(
        vehicleName.c_str()
    );

    pStateCharacteristic =
        service->createCharacteristic(
            STATE_CHAR_UUID,
            BLECharacteristic::PROPERTY_READ |
            BLECharacteristic::PROPERTY_NOTIFY
        );

    pStateCharacteristic->addDescriptor(new BLE2902());
    pStateCharacteristic->setValue("IDLE");

    pBabyStatusCharacteristic =
        service->createCharacteristic(
            BABY_STATUS_CHAR_UUID,
            BLECharacteristic::PROPERTY_READ |
            BLECharacteristic::PROPERTY_NOTIFY
        );

    pBabyStatusCharacteristic->addDescriptor(new BLE2902());
    pBabyStatusCharacteristic->setValue(
        "UNKNOWN|BPM=0|NORMAL"
    );

    service->start();

    BLEAdvertising* advertising =
        BLEDevice::getAdvertising();

    advertising->setMinInterval(0x20);
    advertising->setMaxInterval(0x40);

    updateAdvertising();

    // ------------------------------ RFID -----------------------------------
    Serial.printf(
        "[RFID] UART %ld baud | RX=%d TX=%d\n",
        (long)RFID_BAUD_RATE,
        RFID_RX_PIN,
        RFID_TX_PIN
    );

    Serial1.begin(
        RFID_BAUD_RATE,
        SERIAL_8N1,
        RFID_RX_PIN,
        RFID_TX_PIN
    );

    delay(500);

    if (!setupRfidModule(RFID_BAUD_RATE)) {
        Serial.println("[RFID] INITIALIZATION ERROR");

        // Fatal hardware error: normal operation is impossible.
        while (true) {
            ledRed();
            digitalWrite(LED_STATUS, HIGH);
            delay(100);

            ledOff();
            digitalWrite(LED_STATUS, LOW);
            delay(100);
        }
    }

    rfidReady = true;

    rfidModule.setRegion(REGION_NORTHAMERICA);
    rfidModule.setReadPower(RFID_READ_POWER_CDBM);

    Serial.printf(
        "[RFID] Power=%.1f dBm\n",
        RFID_READ_POWER_CDBM / 100.0f
    );

    // ------------------------------ RADAR ----------------------------------
    analogReadResolution(12);

    resetRadarData();
    clearRfidPresenceCache();

    // ------------------------- INITIAL STATE -------------------------------
    systemState = RFID_MONITORING;
    stateEnteredMs = millis();

    activateRfid();
    publishBleState(false, false);

    digitalWrite(LED_STATUS, HIGH);
    ledGreen();

    Serial.println("[STATE] Initial state = RFID_MONITORING");
    Serial.println("[RULE] Radar only when seat is present AND baby is absent");
    Serial.println("[RULE] Alert remains active until a new BABY_TAG reading");
    Serial.println("==================================================");
}

// ================================= LOOP ====================================
void loop() {
    unsigned long now = millis();

    babyTagDetectedThisLoop = false;

    // RFID is processed only in states where it is explicitly enabled.
    if (systemState == RFID_MONITORING ||
        systemState == BLE_ALERT) {
        updateRfidDutyCycle(now);
        processRfidResponses(now);
    }

    // The state machine never blocks the main loop.
    updateStateMachine(now);

    // A single alert sequence is managed by one timer.
    updateBleAlert(now);
    updateAlarmLed(now);

    // Expire and log current tag presence states.
    if (now - lastRfidStatusLogMs >= RFID_STATUS_LOG_MS) {
        lastRfidStatusLogMs = now;

        bool seatPresent = isSeatTagPresent(now);
        bool babyPresent = isBabyTagPresent(now);

        Serial.printf(
            "[STATUS] state=%s | RFID=%d scan=%d | seat=%d baby=%d | "
            "radar=%d amplitude=%d confirmations=%u | alert=%d\n",
            stateName(systemState),
            rfidEnabled,
            rfidScanActive,
            seatPresent,
            babyPresent,
            radarRunning,
            radarAmplitude,
            radarValidWindowCount,
            bleAlertActive
        );
    }

    if (now - lastHeartbeatMs >= HEARTBEAT_MS) {
        lastHeartbeatMs = now;

        Serial.printf(
            "[HEARTBEAT] uptime=%lu ms | vehicle=%s\n",
            now,
            vehicleName.c_str()
        );
    }
}

// =========================== RFID INITIALIZATION =============================
boolean setupRfidModule(long baudRate) {
    Serial.println("[RFID] Initializing module");

    rfidModule.begin(Serial1, RFID_MODULE_TYPE);
    delay(100);

    clearRfidSerialBuffer();

    rfidModule.getVersion();

    if (rfidModule.msg[0] ==
        ERROR_WRONG_OPCODE_RESPONSE) {
        // The module may already have been reading.
        rfidModule.stopReading();
        delay(1500);
    } else {
        Serial1.begin(
            baudRate,
            SERIAL_8N1,
            RFID_RX_PIN,
            RFID_TX_PIN
        );

        rfidModule.setBaud(baudRate);
        delay(250);
    }

    rfidModule.getVersion();

    if (rfidModule.msg[0] != ALL_GOOD) {
        Serial.print("[RFID] Failure, code=0x");
        Serial.println(rfidModule.msg[0], HEX);
        return false;
    }

    rfidModule.setTagProtocol();
    rfidModule.setAntennaPort();

    Serial.println("[RFID] Module initialized");
    return true;
}
