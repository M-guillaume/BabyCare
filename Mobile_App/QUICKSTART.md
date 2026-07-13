# Quick Start Guide - BabyCare Alert System

## 🚀 Installation and First Launch

## 1. Install Dependencies

Open a terminal in the project directory and run:

```bash
flutter pub get
```

---

## 2. Check Your Environment

Run:

```bash
flutter doctor
```

Make sure that:

- ✅ Flutter is correctly installed
- ✅ Android Studio / Xcode is properly configured
- ✅ At least one device is connected or an emulator is available

---

## 3. Add the Alarm Audio File (Important!)

The application requires an audio file for the alarm system.

Steps:

1. Create the `assets` folder if it does not already exist
2. Download an alarm sound in MP3 format (suggestions are available in `assets/README.md`)
3. Rename it to `alarm.mp3` and place it here:

```text
assets/alarm.mp3
```

⚠️ **Without this file, the alarm will only trigger vibrations.**

---

## 4. Launch the Application

### Android

Run:

```bash
flutter run --release
```

or in debug mode:

```bash
flutter run
```

---

### iOS

Install CocoaPods dependencies:

```bash
cd ios
pod install
cd ..
```

Then run:

```bash
flutter run --release
```

---

# 📊 Functional Verification

When the application is running correctly, you should observe:

## 1. At Application Startup

- Permission requests appear (allow all required permissions)
- The interface displays the status:

```
Inactive
```

---

## 2. After Pressing "Start Monitoring"

- Status changes to:

```
Monitoring Active 🟢
```

- Bluetooth activity indicator is displayed

---

## 3. When an Alert Signal Is Detected

The application should:

- Trigger an immediate push notification
- Play the alarm sound
- Activate continuous vibration
- Display:

```
🚨 ALARM ACTIVE 🚨
```

in red

- Show the button:

```
STOP ALARM
```

---

## 4. After Stopping the Alarm

- Sound and vibration stop
- Persistent notification disappears
- Monitoring continues if it is still enabled

---

# 🎓 Presentation Guidelines

## Key Points to Highlight

### 1. Cross-platform Development

- One codebase for both Android and iOS platforms

### 2. Security

- Signal validation using an authentication code

### 3. Communication Range

- Bluetooth Low Energy communication can reach several hundred meters depending on environmental conditions

### 4. Real-Time Response

- Near-instantaneous alert detection (< 1 second)

### 5. Reliability

- Background operation support for continuous monitoring

---

## Suggested Demonstration Flow

1. Present the application interface
2. Explain the required permissions
3. Start the monitoring system
4. Trigger an alert using the Bluetooth transmitter
5. Demonstrate the notification and alarm activation
6. Stop the alarm

---

# 🔮 Possible Future Improvements

Possible improvements include:

- Cloud server integration
- Persistent alert history
- Alert geolocation
- Custom alarm volume settings
- "Do Not Disturb" mode with configurable schedules
- Emergency SMS notifications

---

# 📞 Support

If you encounter issues:

1. Check application logs:

```bash
flutter logs
```

2. Inspect errors in the console
3. Test the application on different devices
4. Refer to the main `README.md`

---

# 🎯 Presentation Checklist

Before the demonstration:

- [ ] Application builds successfully
- [ ] All required permissions are granted
- [ ] `alarm.mp3` file is present
- [ ] A working Bluetooth transmitter is available
- [ ] Full workflow has been tested (monitoring → detection → alarm → stop)
- [ ] Phone is not in silent mode
- [ ] Battery is sufficiently charged (Bluetooth consumes power!)
