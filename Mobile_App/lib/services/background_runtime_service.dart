import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:permission_handler/permission_handler.dart';

import 'alarm_service.dart';
import 'app_log_service.dart';
import 'bluetooth_service.dart';
import 'notification_service.dart';
import 'settings_service.dart';

String _buildAlarmMessage(String vehicleName) {
  return 'URGENT: A child has been left in $vehicleName!\n'
      'Return immediately to help your child!';
}

/// Keeps the Android process alive via a foreground service.
class BackgroundRuntimeService {
  BackgroundRuntimeService._();

  static final BackgroundRuntimeService _instance =
      BackgroundRuntimeService._();
  factory BackgroundRuntimeService() => _instance;

  static const String _notificationChannelId =
      'babycare_background_monitoring_v2';
  static const int _notificationId = 947;
  static const MethodChannel _powerChannel = MethodChannel('babycare/power');
  static const MethodChannel _bleChannel = MethodChannel('babycare/ble_scan');
  static const MethodChannel _alarmChannel = MethodChannel('babycare/alarm');

  final FlutterBackgroundService _service = FlutterBackgroundService();
  bool _configured = false;
  bool _startInProgress = false;
  final StreamController<bool> _alarmStateController =
      StreamController<bool>.broadcast();
  final StreamController<Map<String, String>> _alarmAlertController =
      StreamController<Map<String, String>>.broadcast();
  StreamSubscription<Map<String, dynamic>?>? _alarmStateSubscription;
  StreamSubscription<Map<String, dynamic>?>? _alarmAlertSubscription;

  Stream<bool> get alarmStateStream => _alarmStateController.stream;
  Stream<Map<String, String>> get alarmAlertStream =>
      _alarmAlertController.stream;

  Future<bool> _hasRequiredAndroidBlePermissions() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return true;
    }

    final scanGranted = await Permission.bluetoothScan.status;
    final connectGranted = await Permission.bluetoothConnect.status;
    final locationGranted = await Permission.locationWhenInUse.status;

    return scanGranted.isGranted &&
        connectGranted.isGranted &&
        locationGranted.isGranted;
  }

  void _log(String message) {
    AppLogService().log('BG', message);
  }

  Future<void> _acquireWakeLock() async {
    try {
      final held = await _powerChannel.invokeMethod<bool>(
        'acquirePartialWakeLock',
      );
      _log('Partial wake lock acquired: ${held == true}');
    } catch (e) {
      _log('Wake lock acquisition error: $e');
    }
  }

  Future<void> _releaseWakeLock() async {
    try {
      final released = await _powerChannel.invokeMethod<bool>(
        'releasePartialWakeLock',
      );
      _log('Partial wake lock released: ${released == true}');
    } catch (e) {
      _log('Wake lock release error: $e');
    }
  }

  Future<void> _startNativeBleScanBridge() async {
    try {
      final started = await _bleChannel.invokeMethod<bool>(
        'startNativeBLEScan',
      );
      _log('Native BLE scan bridge started: ${started == true}');
    } catch (e) {
      _log('Native BLE bridge start error: $e');
    }
  }

  Future<void> _stopNativeBleScanBridge() async {
    try {
      final stopped = await _bleChannel.invokeMethod<bool>('stopNativeBLEScan');
      _log('Native BLE scan bridge stopped: ${stopped == true}');
    } catch (e) {
      _log('Native BLE bridge stop error: $e');
    }
  }

  Future<void> configure() async {
    if (_configured || defaultTargetPlatform != TargetPlatform.android) {
      return;
    }

    try {
      await _service.configure(
        androidConfiguration: AndroidConfiguration(
          onStart: _onBackgroundServiceStart,
          autoStart: false,
          isForegroundMode: true,
          autoStartOnBoot: false,
          notificationChannelId: _notificationChannelId,
          initialNotificationTitle: 'BabyCare active',
          initialNotificationContent: 'Background BLE detection is running',
          foregroundServiceNotificationId: _notificationId,
          foregroundServiceTypes: <AndroidForegroundType>[
            AndroidForegroundType.connectedDevice,
          ],
        ),
        iosConfiguration: IosConfiguration(
          autoStart: false,
          onForeground: _onBackgroundServiceStart,
        ),
      );
      _alarmStateSubscription ??= _service.on('alarmState').listen((event) {
        final active = event?['active'] == true;
        _alarmStateController.add(active);
      });
      _alarmAlertSubscription ??= _service.on('alarmAlert').listen((event) {
        final vehicleName = (event?['vehicleName'] as String? ?? '').trim();
        final message = (event?['message'] as String? ?? '').trim();
        if (vehicleName.isEmpty && message.isEmpty) {
          return;
        }
        _alarmAlertController.add(<String, String>{
          'vehicleName': vehicleName,
          'message': message,
        });
      });
      _service.on('triggerAlarm').listen((_) async {
        final alarm = AlarmService();
        await alarm.startAlarm();
        _alarmStateController.add(alarm.isPlaying);
        _log('Alarm request handled by the main isolate');
      });
      _configured = true;
      _log('Foreground service configured');
    } catch (e) {
      _log('Background service configuration error: $e');
    }
  }

  Future<void> startIfNeeded() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }

    if (_startInProgress) {
      _log('Foreground service start already in progress: request ignored');
      return;
    }

    _startInProgress = true;

    try {
      await configure();

      // Ensure notification channel exists
      await NotificationService().createBackgroundServiceChannel();

      final isRunning = await _service.isRunning();
      final blePermissionsGranted = await _hasRequiredAndroidBlePermissions();
      if (!blePermissionsGranted) {
        _log('Foreground service start cancelled: missing BLE permissions');
        return;
      }

      if (isRunning) {
        await _startNativeBleScanBridge();
        _service.invoke('refreshMonitoringConfig');
        _service.invoke('requestAlarmState');
        return;
      }

      var notificationStatus = await Permission.notification.status;
      if (!notificationStatus.isGranted) {
        _log(
          'Foreground service start cancelled: notification permission not granted',
        );
        return;
      }

      var batteryOptStatus = await Permission.ignoreBatteryOptimizations.status;
      if (!batteryOptStatus.isGranted) {
        batteryOptStatus = await Permission.ignoreBatteryOptimizations
            .request();
      }
      if (!batteryOptStatus.isGranted) {
        _log(
          'Foreground service start cancelled: battery optimization exemption not granted',
        );
        return;
      }

      final started = await _service.startService();
      final isNowRunning = await _service.isRunning();
      if (!started || !isNowRunning) {
        _log(
          'Foreground service start failed: started=$started running=$isNowRunning',
        );
        return;
      }

      await _acquireWakeLock();
      await _startNativeBleScanBridge();
      _service.invoke('refreshMonitoringConfig');
      _service.invoke('requestAlarmState');

      _log('Foreground service started');
    } catch (e) {
      _log('Background service start error: $e');
    } finally {
      _startInProgress = false;
    }
  }

  Future<void> stopIfRunning() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }

    final isRunning = await _service.isRunning();
    if (!isRunning) {
      await _releaseWakeLock();
      _alarmStateController.add(false);
      return;
    }

    _service.invoke('stopAlarm');
    _service.invoke('stopService');
    await _stopNativeBleScanBridge();
    _alarmStateController.add(false);
    await _releaseWakeLock();
    _log('Foreground service stopped');
  }

  Future<void> stopAlarm() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    try {
      await configure();
      try {
        final nativeStopped = await _alarmChannel.invokeMethod<bool>(
          'stopNativeAlarm',
        );
        _log(
          'Direct native alarm stop (UI isolate): ${nativeStopped == true}',
        );
      } catch (e) {
        _log('Direct native alarm stop unavailable: $e');
      }
      _service.invoke('stopAlarm');
      _alarmStateController.add(false);
      _log('Stop alarm command sent to background service');
    } catch (e) {
      _log('Background alarm stop error: $e');
    }
  }

  Future<void> refreshAlarmState() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }

    try {
      await configure();
      final isNativePlaying =
          await _alarmChannel.invokeMethod<bool>('isNativeAlarmPlaying') ==
          true;
      _alarmStateController.add(isNativePlaying);
    } on MissingPluginException {
      // If channel is unavailable in this engine, ask the background service for its latest state.
      _service.invoke('requestAlarmState');
    } catch (e) {
      _log('Alarm state refresh error: $e');
    }
  }
}

@pragma('vm:entry-point')
void _onBackgroundServiceStart(ServiceInstance service) {
  try {
    DartPluginRegistrant.ensureInitialized();
    _bgNativeAlarmChannelAvailable = true;

    _startBackgroundBleMonitoring(service);

    service.on('refreshMonitoringConfig').listen((_) {
      _startBackgroundBleMonitoring(service);
    });

    service.on('requestAlarmState').listen((_) {
      _emitAlarmState(service, _bgAlarmActive);
    });

    service.on('stopAlarm').listen((_) async {
      _bgAlarmSilencedUntil = DateTime.now().add(const Duration(seconds: 5));
      _bgAlarmAutoStopTimer?.cancel();
      _bgAlarmAutoStopTimer = null;
      await AlarmService().stopAlarm();
      await NotificationService().cancel(0);
      await NotificationService().cancel(1);
      await SettingsService().saveLastAlarmSnapshot(
        vehicleName: '',
        alarmMessage: '',
        isActive: false,
      );
      _emitAlarmState(service, false);
      AppLogService().log(
        'BG',
        'Alarme stoppee par commande UI (silence 5s actif)',
      );
    });

    service.on('stopService').listen((_) async {
      await _stopBackgroundBleMonitoring();
      await _releaseWakeLockFromBackgroundIsolate();
      service.stopSelf();
    });
  } catch (e) {
    // Silently catch - AppLogService not available in isolate context
    debugPrint('Background service error: $e');
  }
}

StreamSubscription<String>? _bgAlertSubscription;
Timer? _bgContinuityTimer;
Timer? _bgAlarmStateSyncTimer;
Timer? _bgAlarmAutoStopTimer;
bool _bgMonitoringStarted = false;
bool _bgAlarmActive = false;
bool _bgNativeAlarmChannelAvailable = true;
DateTime? _bgAlarmSilencedUntil;
const Duration _bgAlarmAutoStopNoSignalDelay = Duration(milliseconds: 1500);

DateTime? _lastForegroundInfoUpdateAt;

Future<bool> _bgHasRequiredAndroidBlePermissions() async {
  if (defaultTargetPlatform != TargetPlatform.android) {
    return true;
  }

  final scanGranted = await Permission.bluetoothScan.status;
  final connectGranted = await Permission.bluetoothConnect.status;
  final locationGranted = await Permission.locationWhenInUse.status;

  return scanGranted.isGranted &&
      connectGranted.isGranted &&
      locationGranted.isGranted;
}

void _emitAlarmState(ServiceInstance service, bool active) {
  _bgAlarmActive = active;
  service.invoke('alarmState', <String, dynamic>{'active': active});
}

void _armBackgroundAlarmAutoStop(ServiceInstance service) {
  _bgAlarmAutoStopTimer?.cancel();
  _bgAlarmAutoStopTimer = Timer(_bgAlarmAutoStopNoSignalDelay, () async {
    AppLogService().log(
      'BG',
      'Aucun signal BLE recent: arret automatique de l alarme en fond',
    );

    await AlarmService().stopAlarm();
    await NotificationService().cancel(0);
    await NotificationService().cancel(1);
    _emitAlarmState(service, false);
  });
}

Future<void> _releaseWakeLockFromBackgroundIsolate() async {
  if (defaultTargetPlatform != TargetPlatform.android) {
    return;
  }

  try {
    const powerChannel = MethodChannel('babycare/power');
    final released = await powerChannel.invokeMethod<bool>(
      'releasePartialWakeLock',
    );
    AppLogService().log(
      'BG',
      'Wake lock relache depuis isolate: ${released == true}',
    );
  } catch (e) {
    AppLogService().log('BG', 'Erreur release wake lock depuis isolate: $e');
  }
}

Future<void> _syncNativeAlarmState(ServiceInstance service) async {
  if (defaultTargetPlatform != TargetPlatform.android) {
    return;
  }

  if (!_bgNativeAlarmChannelAvailable) {
    return;
  }

  try {
    const alarmChannel = MethodChannel('babycare/alarm');
    final isNativePlaying =
        await alarmChannel.invokeMethod<bool>('isNativeAlarmPlaying') == true;
    if (isNativePlaying != _bgAlarmActive) {
      _emitAlarmState(service, isNativePlaying);
      AppLogService().log(
        'BG',
        'Etat alarme synchro natif -> UI: $isNativePlaying',
      );
    }
  } on MissingPluginException {
    // The background isolate may run on a different engine without MainActivity channels.
    _bgNativeAlarmChannelAvailable = false;
    _bgAlarmStateSyncTimer?.cancel();
    _bgAlarmStateSyncTimer = null;
    AppLogService().log(
      'BG',
      'Channel natif alarme indisponible en isolate de fond: synchro desactivee',
    );
  } catch (e) {
    AppLogService().log('BG', 'Erreur synchro etat alarme natif: $e');
  }
}

Future<void> _startBackgroundBleMonitoring(ServiceInstance service) async {
  if (_bgMonitoringStarted) {
    AppLogService().log('BG', 'Refresh configuration monitoring BLE en fond');
  }

  final blePermissionsGranted = await _bgHasRequiredAndroidBlePermissions();
  if (!blePermissionsGranted) {
    AppLogService().log(
      'BG',
      'Monitoring BLE annule: permissions BLE manquantes',
    );
    return;
  }

  final settings = await SettingsService().load();
  final bluetooth = BluetoothService();
  final notification = NotificationService();
  final alarm = AlarmService();

  bluetooth.configureMonitoring(
    scanEvaluationInterval: Duration(
      seconds: settings.detectionIntervalSeconds,
    ),
    referenceName: settings.referenceName,
    referenceDeviceId: settings.referenceDeviceId,
  );

  await notification.initialize();
  await alarm.initialize();

  // Démarre le native BLE scanner pour capturer les résultats écran éteint
  try {
    if (defaultTargetPlatform == TargetPlatform.android) {
      const bleChannel = MethodChannel('babycare/ble_scan');
      await bleChannel.invokeMethod<bool>('startNativeBLEScan');
      AppLogService().log('BG', 'Native BLE scan channel invoqué');
    }
  } catch (e) {
    AppLogService().log('BG', 'Erreur native BLE: $e');
  }

  _bgAlertSubscription ??= bluetooth.alertStream.listen((alertMessage) async {
    final silencedUntil = _bgAlarmSilencedUntil;
    if (silencedUntil != null && DateTime.now().isBefore(silencedUntil)) {
      AppLogService().log('BG', 'Alerte ignoree pendant fenetre de silence');
      return;
    }

    _bgAlarmSilencedUntil = null;
    AppLogService().log('BG', 'Alerte BLE detectee en fond: $alertMessage');

    final personalizedMessage = _buildAlarmMessage(alertMessage);
    await SettingsService().saveLastAlarmSnapshot(
      vehicleName: alertMessage,
      alarmMessage: personalizedMessage,
      isActive: true,
    );

    service.invoke('alarmAlert', <String, dynamic>{
      'vehicleName': alertMessage,
      'message': personalizedMessage,
    });

    await notification.showAlertNotification(
      title: '⚠️ ALERT DETECTED',
      message: personalizedMessage,
    );

    await notification.showPersistentAlertNotification(
      title: '🚨 Alarm Active',
      message: 'Tap to stop the alarm',
    );

    service.invoke('triggerAlarm');
    _armBackgroundAlarmAutoStop(service);
  });

  if (!_bgMonitoringStarted) {
    final started = await bluetooth.startScanning();
    _bgMonitoringStarted = started;
    AppLogService().log(
      'BG',
      'Monitoring BLE service de fond demarre: $started',
    );
  }

  _bgContinuityTimer?.cancel();
  _bgContinuityTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
    await bluetooth.ensureScanContinuity();
    if (service is AndroidServiceInstance) {
      final now = DateTime.now();
      final last = _lastForegroundInfoUpdateAt;
      if (last == null || now.difference(last) >= const Duration(seconds: 60)) {
        service.setForegroundNotificationInfo(
          title: 'BabyCare active',
          content:
              'BLE detection running ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
        );
        _lastForegroundInfoUpdateAt = now;
      }
    }
  });

  _bgAlarmStateSyncTimer?.cancel();
  if (_bgNativeAlarmChannelAvailable) {
    _bgAlarmStateSyncTimer = Timer.periodic(const Duration(seconds: 2), (
      _,
    ) async {
      await _syncNativeAlarmState(service);
    });
  }

  await _syncNativeAlarmState(service);

  _emitAlarmState(service, _bgAlarmActive);
}

Future<void> _stopBackgroundBleMonitoring() async {
  _bgContinuityTimer?.cancel();
  _bgContinuityTimer = null;
  _bgAlarmStateSyncTimer?.cancel();
  _bgAlarmStateSyncTimer = null;
  _bgAlarmAutoStopTimer?.cancel();
  _bgAlarmAutoStopTimer = null;
  _lastForegroundInfoUpdateAt = null;

  await _bgAlertSubscription?.cancel();
  _bgAlertSubscription = null;

  await AlarmService().stopAlarm();
  await NotificationService().cancel(0);
  await NotificationService().cancel(1);

  await BluetoothService().stopScanning();
  _bgAlarmActive = false;
  _bgMonitoringStarted = false;
}
