import 'dart:async';
import 'package:flutter/foundation.dart';
import 'bluetooth_service.dart';
import 'notification_service.dart';
import 'alarm_service.dart';

import 'app_log_service.dart';

class AlertCoordinator {
  static const String _forgottenChildAlertMessage =
      'URGENT: A child has been left in your vehicle!\nReturn immediately to help your child!';
  static const Duration _alarmAutoStopNoSignalDelay = Duration(milliseconds: 1500);

  static final AlertCoordinator _instance = AlertCoordinator._internal();
  factory AlertCoordinator() => _instance;
  AlertCoordinator._internal();

  final BluetoothService _bluetoothService = BluetoothService();
  final NotificationService _notificationService = NotificationService();
  final AlarmService _alarmService = AlarmService();

  StreamSubscription? _alertSubscription;
  Timer? _alarmAutoStopTimer;
  bool _isActive = false;

  void _log(String message) {
    AppLogService().log('COORD', message);
  }

  // Initialize all services.
  Future<void> initialize() async {
    _log('Initializing services...');
    await _notificationService.initialize();
    await _alarmService.initialize();
    
    // Request permissions.
    final notifGranted = await _notificationService.requestPermissions();
    _log('Notification permission: $notifGranted');
    
    _log('AlertCoordinator initialized');
  }

  // Start monitoring.
  Future<void> start() async {
    if (_isActive) return;
    _log('Monitoring start requested');

    if (defaultTargetPlatform == TargetPlatform.android) {
      _isActive = true;
      _log('Android monitoring delegated to the background service');
      return;
    }

    // Listen for Bluetooth alerts.
    _alertSubscription = _bluetoothService.alertStream.listen((alertMessage) {
      _log('Alert message received from BLE stream: $alertMessage');
      _handleAlert(alertMessage);
    });
    
    // Start Bluetooth scanning.
    final started = await _bluetoothService.startScanning();
    if (!started) {
      await _alertSubscription?.cancel();
      _alertSubscription = null;
      throw Exception('Unable to start detection. Check Bluetooth and permissions.');
    }

    _isActive = true;
    
    _log('Monitoring active');
  }

  // Gère une alerte reçue
  Future<void> _handleAlert(String alertMessage) async {
    _log('ALERT RECEIVED: $alertMessage');

    // Envoie d'abord le popup urgent (heads-up/full-screen), puis la persistante.
    await _notificationService.showAlertNotification(
      title: '⚠️ ALERT DETECTED',
      message: _forgottenChildAlertMessage,
    );
    _log('Alert notification requested from service');

    await _notificationService.showPersistentAlertNotification(
      title: '🚨 Alarm Active',
      message: 'Tap to stop the alarm',
    );
    _log('Persistent notification requested from service');
    
    // Start the alarm.
    await _alarmService.startAlarm();
    _armAlarmAutoStopTimer();
    _log('Alarm started');
  }

  void _armAlarmAutoStopTimer() {
    _alarmAutoStopTimer?.cancel();
    _alarmAutoStopTimer = Timer(_alarmAutoStopNoSignalDelay, () async {
      if (!_isActive) {
        return;
      }

      _log('No recent BLE signal: automatic alarm stop');
      await stopAlarm();
    });
  }

  // Stop the alarm.
  Future<void> stopAlarm() async {
    _alarmAutoStopTimer?.cancel();
    _alarmAutoStopTimer = null;
    await _alarmService.stopAlarm();
    await _notificationService.cancel(1); // Cancel the persistent notification.
    _log('Alarm stopped');
  }

  // Stop monitoring.
  Future<void> stop() async {
    _log('Monitoring stop requested');
    _isActive = false;
    _alarmAutoStopTimer?.cancel();
    _alarmAutoStopTimer = null;
    await _alertSubscription?.cancel();
    _alertSubscription = null;
    if (defaultTargetPlatform != TargetPlatform.android) {
      await _bluetoothService.stopScanning();
    }
    await stopAlarm();
    _log('Monitoring stopped');
  }

  // Alarm state.
  bool get isAlarmPlaying => _alarmService.isPlaying;
  
  // Monitoring state.
  bool get isActive => _isActive;

  void dispose() {
    stop();
    _bluetoothService.dispose();
    _alarmService.dispose();
  }
}
