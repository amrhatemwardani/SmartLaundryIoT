# Zewail City Dorm Laundry — IoT & Embedded Hardware Plan (STM32 & ESP32)

## 1. System Overview & Architecture

The IoT system connects physical laundry room hardware to the Supabase PostgreSQL backend via secure Supabase Edge Functions.

```
+-------------------------------------------------------------+
|                      STUDENT APP                            |
|             (Generates Single-Use QR Token)                 |
+------------------------------+------------------------------+
                               |
                               v (Visual scan)
+-------------------------------------------------------------+
|                  ESP32 DOOR SCANNER NODE                    |
|  - ESP32-CAM / Barcode Scanner Module                       |
|  - Relay Module -> Solenoid Door Strike (12V)               |
|  - Status Buzzer & NeoPixel Indicator                       |
+------------------------------+------------------------------+
                               |
                               | HTTPS POST /functions/v1/door-scan
                               v
+-------------------------------------------------------------+
|                     SUPABASE BACKEND                        |
|  - Door Scan RPC (`iot_consume_door_qr`)                    |
|  - Access Window & Single-Use Verification                  |
|  - Telemetry Logger (`iot_report_machine_state`)            |
+------------------------------+------------------------------+
                               ^
                               | HTTPS POST /functions/v1/iot-event
+-------------------------------------------------------------+
|                STM32 / ESP32 WASHER SENSOR NODE             |
|  - STM32F4 / ESP32 micro-controller                         |
|  - Non-invasive CT Current Sensor (SCT-013)                 |
|  - Vibration Sensor (SW-420 or MPU6050)                     |
|  - Reports: idle | running | fault | offline                |
+-------------------------------------------------------------+
```

---

## 2. Component 1: Door Access Controller (ESP32)

### Hardware Requirements:
- **MCU:** ESP32-WROOM-32 or ESP32-CAM.
- **Scanner:** UART QR/Barcode Scanner Module (e.g. GM65, GM67, or Barcode 2D reader) or OV2640 camera running `quirc`.
- **Locking Mechanism:** 12V Fail-Secure Door Solenoid Strike or Magnetic Lock.
- **Actuation:** 5V Relay module with optocoupler isolation + Flyback diode (1N4007) across lock coil.
- **Emergency Hardware Exit:** Physical mechanical push-bar / inside knob that works with zero electricity or network (safety compliance).

### Protocol & Flow:
1. Student holds their confirmed Ticket QR code in front of the scanner.
2. Scanner reads the 64-character hex token string: `5f8a...`
3. ESP32 connects to WiFi (WPA2-Enterprise / Campus WiFi) and issues:
   ```http
   POST https://qggmohpbanqugnmmqwnx.supabase.co/functions/v1/door-scan
   Content-Type: application/json
   x-device-key: door_dorm_c
   x-device-secret: <PER_DEVICE_SECRET>

   {
     "deviceKey": "door_dorm_c",
     "apiKey": "<SECRET_KEY>",
     "token": "5f8a..."
   }
   ```
4. Backend executes `iot_consume_door_qr`:
   - Checks SHA-256 digest of token against `access_credentials`.
   - Validates that token is not already used (`used_at IS NULL`).
   - Validates that time is within the access window: `[starts_at - 10 min, starts_at + 40 min]`.
   - Checks that dorm room matches and washer is not out of order.
5. Response:
   - If `{"granted": true}`: ESP32 activates relay GPIO for 8 seconds, plays positive chime, and records door event.
   - If `{"granted": false, "reason": "..."}`: ESP32 plays warning tone, leaves door locked, and flashes red LED.

---

## 3. Component 2: Washing Machine State Monitor (STM32 & ESP32)

### Hardware Requirements:
- **MCU:** STM32 (e.g. STM32F103 "BluePill" or STM32F401 "BlackPill") or ESP32.
- **Current Sensing:** SCT-013-000 Non-invasive AC Current Transformer clamped around the live wire of each washer.
- **Vibration Sensing:** SW-420 digital vibration sensor or MPU6050 I2C accelerometer attached to the machine drum outer chassis.

### Sensing Logic:
- **Idle State:** Power draw < 5 Watts and no continuous vibration.
- **Running State:** Power draw > 80 Watts (motor spinning / water pump running) with vibration frequencies above 5 Hz.
- **Finished State:** Machine drops from running power to idle power for > 90 seconds.
- **Fault State:** Machine draws abnormally high stall current or abruptly disconnects while cycle is incomplete.

### Telemetry Reporting:
Reports telemetry every 60 seconds (or immediately on state transition) to:
```http
POST https://qggmohpbanqugnmmqwnx.supabase.co/functions/v1/iot-event
Content-Type: application/json

{
  "deviceKey": "washer_monitor_c",
  "apiKey": "<DEVICE_SECRET>",
  "machineKey": "washer_c01",
  "state": "running",
  "details": {
    "currentAmps": 3.8,
    "powerWatts": 830,
    "vibrationLevel": "high",
    "cycleStartedAt": "2026-11-17T14:02:00Z"
  }
}
```

---

## 4. Database & Backend Readiness (Already Implemented)

The backend schema already has full support for these devices:
1. `public.iot_devices`: Stores device registrations and SHA-256 hashed API keys.
2. `public.access_credentials`: Stores single-use ticket hashes with strict `valid_from` and `valid_until` windows.
3. `public.door_events`: Real-time audit log of all granted and denied scans.
4. `public.machine_telemetry`: Real-time state of each washer with timestamps and details.
5. `public.device_events`: Hardware event history.
6. Edge Functions `door-scan` and `iot-event` are ready in `supabase/functions/`.

---

## 5. Security & Safety Rules

1. **Fail-Closed for Network, Fail-Open for Safety:**
   - If the backend is unreachable, the door stays locked to unauthorized outside entry.
   - The physical interior door release (handle / panic bar) is purely mechanical and opens the door at any time without power or WiFi.
2. **Never store Supabase Service Role Key on microcontrollers:**
   - Devices only possess their own individual per-device API key (`api_key_hash`).
   - If an ESP32 is stolen, only that single device key is revoked from the Admin dashboard without compromising the platform.
3. **Single-Use Replay Protection:**
   - As soon as a token is accepted, `used_at` is set to `now()`. Any replayed QR scan is immediately denied.
