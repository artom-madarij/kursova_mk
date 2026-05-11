#include <WiFi.h>
#include <HTTPClient.h>
#include "time.h"
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include <ESP32Servo.h>
#include <Preferences.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>

#define SCREEN_WIDTH 128
#define SCREEN_HEIGHT 64
Adafruit_SSD1306 display(SCREEN_WIDTH, SCREEN_HEIGHT, &Wire, -1);
bool displayConnected = false;

Servo feederServo;
const int servoPin = 13;
const int speakerPin = 32;
const int buttonPin = 4;   

#define SERVICE_UUID        "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define CHARACTERISTIC_UUID "beb5483e-36e1-4688-b7f5-ea07361b26a8"

Preferences preferences;
String ssid = "";
String password = "";
bool bleMode = false;

const char* cloudUrl = "https://puzzling-entomb-bunkmate.ngrok-free.dev/feeder";

const char* ntpServer = "pool.ntp.org";
const char* TZ_INFO = "EET-2EEST,M3.5.0/3,M10.5.0/4";  

bool feedExecutedThisMinute = false;
int lastFeedMinute = -1;

void feedCat() {
  Serial.println("Виконую годування...");
  
  if (displayConnected) {
    display.clearDisplay();
    display.setTextSize(2);
    display.setCursor(15, 25);
    display.println("Feeding");
    display.display();
  }

  for (int i = 0; i < 3; i++) {
    tone(speakerPin, 1000);
    delay(300);
    noTone(speakerPin);
    delay(200);
  }

  feederServo.attach(servoPin);
  feederServo.write(90);
  delay(2000);
  feederServo.write(0);
  delay(500);
  feederServo.detach();

  Serial.println("Годування завершено.");

  if (WiFi.status() == WL_CONNECTED) {
    HTTPClient http;
    String logUrl = String(cloudUrl) + "/feed.php?action=done";
    http.begin(logUrl);
    http.addHeader("ngrok-skip-browser-warning", "true");
    int httpCode = http.GET();
    if (httpCode > 0) {
      Serial.printf("Лог надіслано, код: %d\n", httpCode);
    } else {
      Serial.printf("Помилка відправки логу: %s\n", http.errorToString(httpCode).c_str());
    }
    http.end();
  }
}

class MyCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *pCharacteristic) {
    String rxValue = pCharacteristic->getValue().c_str();
    int newlinePos = rxValue.indexOf('\n');
    if (newlinePos != -1) {
      String newSSID = rxValue.substring(0, newlinePos);
      String newPASS = rxValue.substring(newlinePos + 1);
      newSSID.trim();
      newPASS.trim();

      preferences.begin("wifi-creds", false);
      preferences.putString("ssid", newSSID);
      preferences.putString("password", newPASS);
      preferences.end();

      Serial.println("Wi-Fi збережено. Перезавантаження...");
      delay(1000);
      ESP.restart();
    }
  }
};

void setup() {
  Serial.begin(115200);
  pinMode(buttonPin, INPUT_PULLUP);
  pinMode(speakerPin, OUTPUT);
  digitalWrite(speakerPin, LOW);

  if (display.begin(SSD1306_SWITCHCAPVCC, 0x3C)) {
    displayConnected = true;
    display.clearDisplay();
    display.setTextColor(WHITE);
    display.setTextSize(1);
    display.setCursor(0, 0);
    display.println("Loading...");
    display.display();
  }

  preferences.begin("wifi-creds", true);
  ssid = preferences.getString("ssid", "");
  password = preferences.getString("password", "");
  preferences.end();

  if (ssid == "" || password == "") {
    bleMode = true;
    BLEDevice::init("CatFeeder-Setup");
    BLEServer *pServer = BLEDevice::createServer();
    BLEService *pService = pServer->createService(SERVICE_UUID);
    BLECharacteristic *pChar = pService->createCharacteristic(
      CHARACTERISTIC_UUID,
      BLECharacteristic::PROPERTY_WRITE
    );
    pChar->setCallbacks(new MyCallbacks());
    pService->start();
    BLEDevice::startAdvertising();
    Serial.println("Режим BLE. Надішліть SSID та пароль через додаток.");
  } else {
    WiFi.begin(ssid.c_str(), password.c_str());
    int tries = 0;
    while (WiFi.status() != WL_CONNECTED && tries < 30) {
      delay(500);
      Serial.print(".");
      tries++;
    }

    if (WiFi.status() == WL_CONNECTED) {
      Serial.println("\nWi-Fi підключено!");
      Serial.print("IP: ");
      Serial.println(WiFi.localIP());
      configTzTime(TZ_INFO, ntpServer);

      if (displayConnected) {
        display.clearDisplay();
        display.setTextSize(2);
        display.setCursor(10, 25);
        display.println("Connected");
        display.display();
        delay(1500);
      }
    } else {
      Serial.println("Не вдалося підключитись до Wi-Fi. Перехід у BLE режим.");
      bleMode = true;
    }
  }
}

void loop() {
  if (bleMode) {
    delay(100);
    return;
  }

  if (digitalRead(buttonPin) == LOW) {
    delay(50);
    if (digitalRead(buttonPin) == LOW) {
      feedCat();
      while (digitalRead(buttonPin) == LOW);
    }
  }

  static unsigned long lastCheck = 0;
  if (millis() - lastCheck > 5000) {
    lastCheck = millis();

    struct tm timeinfo;
    if (getLocalTime(&timeinfo)) {
      if (displayConnected) {
        display.clearDisplay();
        display.setTextSize(3);
        display.setCursor(20, 20);
        char timeStr[10];
        sprintf(timeStr, "%02d:%02d", timeinfo.tm_hour, timeinfo.tm_min);
        display.println(timeStr);
        display.display();
      }

      if (timeinfo.tm_min != lastFeedMinute) {
        feedExecutedThisMinute = false;
        lastFeedMinute = timeinfo.tm_min;
      }

      if (WiFi.status() == WL_CONNECTED) {
        HTTPClient http;
        char timeParams[30];
        sprintf(timeParams, "?h=%02d&m=%02d", timeinfo.tm_hour, timeinfo.tm_min);
        String checkUrl = String(cloudUrl) + "/check.php" + String(timeParams);
        
        http.begin(checkUrl);
        http.addHeader("ngrok-skip-browser-warning", "true");

        int httpCode = http.GET();
        if (httpCode == 200) {
          String payload = http.getString();
          payload.trim();
          Serial.println("Відповідь check.php: " + payload);

          if (payload == "FEED" && !feedExecutedThisMinute) {
            feedCat();
            feedExecutedThisMinute = true;
          }
        } else {
          Serial.printf("Помилка запиту check.php: %d\n", httpCode);
        }
        http.end();
      }
    } else {
      Serial.println("Очікування синхронізації часу...");
    }
  }
}