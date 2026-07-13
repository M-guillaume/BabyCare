#include "SparkFun_UHF_RFID_Reader.h"

RFID nano;

void setup() {
  Serial.begin(115200);
  Serial.println("commencé");
  Serial2.begin(115200, SERIAL_8N1, 16, 17);
  
  nano.begin(Serial2);

  nano.setRegion(REGION_EUROPE);
  nano.setReadPower(2700);
  nano.startReading();
  Serial.println("Lecture en cours...");
}

void loop() {
  if (nano.check() == RESPONSE_IS_TAGFOUND) {
    byte tagEPCBytes = nano.getTagEPCBytes();

    Serial.print("Tag EPC : ");
    for (byte i = 0; i < tagEPCBytes; i++) {
      if (nano.msg[31 + i] < 0x10) Serial.print("0");
      Serial.print(nano.msg[31 + i], HEX);
      Serial.print(" ");
    }

    Serial.print(" | RSSI : ");
    Serial.print(nano.getTagRSSI());
    Serial.println(" dBm");
  }
}