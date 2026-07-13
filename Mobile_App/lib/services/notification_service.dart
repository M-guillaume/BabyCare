import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/foundation.dart';

import 'app_log_service.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  // Android channels are immutable once created: bump IDs when alarm behavior changes.
  static const String _alertChannelId = 'alert_channel_v4';
  static const String _persistentAlertChannelId = 'alarm_persistent_channel_v3';
  static const String _backgroundChannelId = 'babycare_background_monitoring_v2';

  final FlutterLocalNotificationsPlugin _notifications = 
      FlutterLocalNotificationsPlugin();
  
  bool _initialized = false;

  void _log(String message) {
    AppLogService().log('NOTIF', message);
  }

  Future<bool> _ensureAndroidNotificationsReady({
    bool requestFullScreenIntent = false,
  }) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return true;
    }

    final androidImplementation =
        _notifications.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    if (androidImplementation == null) {
      _log('Android notifications plugin unavailable');
      return false;
    }

    final granted = await androidImplementation.areNotificationsEnabled();
    final enabled = await androidImplementation.areNotificationsEnabled();
    bool? fullScreenAllowed;
    if (requestFullScreenIntent) {
      fullScreenAllowed =
          await androidImplementation.requestFullScreenIntentPermission();
    }

    _log(
      'Android notification state -> permission: ${granted ?? true} | enabled: ${enabled ?? false} | fullScreen: ${fullScreenAllowed ?? 'n/a'}',
    );

    // Si le système bloque les notifications, les appels show() sont silencieux.
    if (enabled != true) {
      _log('Android notifications are disabled at the system level');
      return false;
    }

    if (granted != true) {
      _log('POST_NOTIFICATIONS permission denied');
      return false;
    }

    return true;
  }

  // Initialize the notification service.
  Future<void> initialize() async {
    if (_initialized) return;

    try {
      // Android configuration.
      const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
      
      // iOS configuration.
      const iosSettings = DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      );

      const initSettings = InitializationSettings(
        android: androidSettings,
        iOS: iosSettings,
      );

      await _notifications.initialize(
        settings: initSettings,
        onDidReceiveNotificationResponse: _onNotificationTapped,
      );

      if (defaultTargetPlatform == TargetPlatform.android) {
        final androidImplementation =
            _notifications.resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>();
        if (androidImplementation != null) {
          final enabled = await androidImplementation.areNotificationsEnabled();
          _log('Android notification state (init): ${enabled ?? false}');
          await _createNotificationChannels(androidImplementation);
        }
      }

      _initialized = true;
      _log('Notification service initialized');
    } catch (e) {
      _log('Notification initialization error: $e');
    }
  }

  // Handle notification taps.
  void _onNotificationTapped(NotificationResponse response) {
    _log('Notification tapped: ${response.payload}');
    // A specific app page could be opened here.
  }

  // Request permissions (mainly for iOS).
  Future<bool> requestPermissions() async {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      final result = await _notifications
          .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(
            alert: true,
            badge: true,
            sound: true,
          );
      _log('iOS notification permission: ${result ?? false}');
      return result ?? false;
    } else if (defaultTargetPlatform == TargetPlatform.android) {
      final androidImplementation =
          _notifications.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      
      if (androidImplementation != null) {
        final granted = await androidImplementation.areNotificationsEnabled();
        _log('Android notification permission: ${granted ?? false}');
        return granted ?? false;
      }
    }
    _log('Notification permissions: not required on this platform');
    return true;
  }

  // Envoie une notification d'alerte
  Future<void> showAlertNotification({
    required String title,
    required String message,
  }) async {
    if (!_initialized) {
      await initialize();
    }

    try {
      final canNotify = await _ensureAndroidNotificationsReady(
        requestFullScreenIntent: true,
      );
      if (!canNotify) {
        _log('Alert notification ignored: permissions/system not ready');
        return;
      }

      _log('Alert notification request: title=$title | message=$message');
      // Android-specific configuration for a high-priority notification.
      final androidDetails = AndroidNotificationDetails(
        _alertChannelId,
        'Alerts',
        channelDescription: 'Important alert notifications',
        importance: Importance.max,
        priority: Priority.max,
        audioAttributesUsage: AudioAttributesUsage.alarm,
        channelBypassDnd: true,
        showWhen: true,
        enableVibration: true,
        vibrationPattern: Int64List.fromList([0, 1000, 500, 1000]),
        enableLights: true,
        playSound: true,
        category: AndroidNotificationCategory.call,
        fullScreenIntent: true, // Show even when the screen is locked.
        ongoing: false,
        autoCancel: true,
        timeoutAfter: 30000,
        visibility: NotificationVisibility.public,
        additionalFlags: Int32List.fromList([16]), // FLAG_HIGH_PRIORITY for heads-up.
      );

      // iOS configuration.
      const iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        interruptionLevel: InterruptionLevel.critical,
      );

      final notificationDetails = NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      );

      await _notifications.show(
        id: 0,
        title: title,
        body: message,
        notificationDetails: notificationDetails,
        payload: 'alert_notification',
      );

      _log('Alert notification sent (id=0)');
    } catch (e) {
      _log('Notification send error: $e');
    }
  }

  // Send a persistent notification (for the alarm).
  Future<void> showPersistentAlertNotification({
    required String title,
    required String message,
  }) async {
    if (!_initialized) {
      await initialize();
    }

    try {
      final canNotify = await _ensureAndroidNotificationsReady();
      if (!canNotify) {
        _log('Persistent notification ignored: permissions/system not ready');
        return;
      }

      _log('Persistent notification request: title=$title | message=$message');
      final androidDetails = AndroidNotificationDetails(
        _persistentAlertChannelId,
        'Alarm Active',
        channelDescription: 'Persistent notification while alarm is ringing',
        importance: Importance.max,
        priority: Priority.max,
        audioAttributesUsage: AudioAttributesUsage.alarm,
        channelBypassDnd: true,
        ongoing: true,
        autoCancel: false,
        enableVibration: true,
        vibrationPattern: Int64List.fromList([0, 500, 250, 500]),
        playSound: true,
        category: AndroidNotificationCategory.alarm,
        fullScreenIntent: true,
        visibility: NotificationVisibility.public,
        additionalFlags: Int32List.fromList(<int>[4, 16]), // FLAG_INSISTENT=4, FLAG_HIGH_PRIORITY=16
        colorized: true,
      );

      const iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        interruptionLevel: InterruptionLevel.critical,
      );

      final notificationDetails = NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      );

      await _notifications.show(
        id: 1,
        title: title,
        body: message,
        notificationDetails: notificationDetails,
        payload: 'persistent_alarm',
      );
      _log('Persistent notification sent (id=1)');
    } catch (e) {
      _log('Persistent notification error: $e');
    }
  }

  Future<void> _createNotificationChannels(
    AndroidFlutterLocalNotificationsPlugin androidImplementation,
  ) async {
    try {
      // Channel for alert notifications (urgent popups).
      const alertChannel = AndroidNotificationChannel(
        _alertChannelId,
        'Alerts',
        description: 'Important alert notifications',
        importance: Importance.max,
        enableLights: true,
        enableVibration: true,
        playSound: true,
        bypassDnd: true,
      );

      // Channel for persistent alarm notifications.
      const persistentAlertChannel = AndroidNotificationChannel(
        _persistentAlertChannelId,
        'Alarm Active',
        description: 'Persistent notification while alarm is ringing',
        importance: Importance.max,
        enableLights: true,
        enableVibration: true,
        playSound: true,
        bypassDnd: true,
      );

      // Channel for background monitoring (silent).
      const backgroundChannel = AndroidNotificationChannel(
        _backgroundChannelId,
        'Background Monitoring',
        description: 'Notifications for background BLE monitoring',
        importance: Importance.low,
        enableLights: false,
        enableVibration: false,
        playSound: false,
      );

      await androidImplementation.createNotificationChannel(alertChannel);
      await androidImplementation.createNotificationChannel(persistentAlertChannel);
      await androidImplementation.createNotificationChannel(backgroundChannel);
      _log('All notification channels created');
    } catch (e) {
      _log('Notification channel creation error: $e');
    }
  }

  // Crée le canal de notification pour le service de fond (legacy, canaux créés dans init)
  Future<void> createBackgroundServiceChannel() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }

    try {
      final androidImplementation =
          _notifications.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      if (androidImplementation == null) {
        _log('createBackgroundServiceChannel: plugin Android indisponible');
        return;
      }

      const backgroundChannel = AndroidNotificationChannel(
        _backgroundChannelId,
        'Background Monitoring',
        description: 'Notifications for background BLE monitoring',
        importance: Importance.low,
        enableLights: false,
        enableVibration: false,
        playSound: false,
      );

      await androidImplementation.createNotificationChannel(backgroundChannel);
      _log('createBackgroundServiceChannel: canal de fond cree');
    } catch (e) {
      _log('Erreur createBackgroundServiceChannel: $e');
    }
  }

  // Annule toutes les notifications
  Future<void> cancelAll() async {
    await _notifications.cancelAll();
    _log('Toutes les notifications annulées');
  }

  // Annule une notification spécifique
  Future<void> cancel(int id) async {
    await _notifications.cancel(id: id);
  }
}
