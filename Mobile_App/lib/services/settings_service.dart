import 'package:shared_preferences/shared_preferences.dart';

class AppSettings {
  const AppSettings({
    required this.detectionEnabled,
    required this.runInBackground,
    required this.detectionIntervalSeconds,
    required this.referenceName,
    required this.referenceDeviceId,
  });

  final bool detectionEnabled;
  final bool runInBackground;
  final int detectionIntervalSeconds;
  final String referenceName;
  final String referenceDeviceId;

  AppSettings copyWith({
    bool? detectionEnabled,
    bool? runInBackground,
    int? detectionIntervalSeconds,
    String? referenceName,
    String? referenceDeviceId,
  }) {
    return AppSettings(
      detectionEnabled: detectionEnabled ?? this.detectionEnabled,
      runInBackground: runInBackground ?? this.runInBackground,
      detectionIntervalSeconds:
          detectionIntervalSeconds ?? this.detectionIntervalSeconds,
      referenceName: referenceName ?? this.referenceName,
      referenceDeviceId: referenceDeviceId ?? this.referenceDeviceId,
    );
  }

  static const AppSettings defaults = AppSettings(
    detectionEnabled: true,
    runInBackground: true,
    detectionIntervalSeconds: 2,
    referenceName: 'BabyCare_ESP32',
    referenceDeviceId: '',
  );
}

class SettingsService {
  SettingsService._();

  static final SettingsService _instance = SettingsService._();
  factory SettingsService() => _instance;

  static const _kDetectionEnabled = 'detection_enabled';
  static const _kRunInBackground = 'run_in_background';
  static const _kDetectionInterval = 'detection_interval_seconds';
  static const _kReferenceName = 'reference_name';
  static const _kReferenceDeviceId = 'reference_device_id';
  static const _kLastAlarmVehicleName = 'last_alarm_vehicle_name';
  static const _kLastAlarmMessage = 'last_alarm_message';
  static const _kLastAlarmActive = 'last_alarm_active';

  Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final storedReferenceName =
      prefs.getString(_kReferenceName) ?? AppSettings.defaults.referenceName;
    final normalizedStoredReferenceName = storedReferenceName.trim().toUpperCase();
    final migratedReferenceName =
      normalizedStoredReferenceName == 'ALERT_BABYCARE_ESP32' &&
        (prefs.getString(_kReferenceDeviceId) ?? '').trim().isEmpty
      ? AppSettings.defaults.referenceName
      : storedReferenceName;
    return AppSettings(
      detectionEnabled:
          prefs.getBool(_kDetectionEnabled) ?? AppSettings.defaults.detectionEnabled,
      runInBackground:
          prefs.getBool(_kRunInBackground) ?? AppSettings.defaults.runInBackground,
      detectionIntervalSeconds: prefs.getInt(_kDetectionInterval) ??
          AppSettings.defaults.detectionIntervalSeconds,
      referenceName: migratedReferenceName,
      referenceDeviceId:
          prefs.getString(_kReferenceDeviceId) ?? AppSettings.defaults.referenceDeviceId,
    );
  }

  Future<void> save(AppSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kDetectionEnabled, settings.detectionEnabled);
    await prefs.setBool(_kRunInBackground, settings.runInBackground);
    await prefs.setInt(_kDetectionInterval, settings.detectionIntervalSeconds);
    await prefs.setString(_kReferenceName, settings.referenceName);
    await prefs.setString(_kReferenceDeviceId, settings.referenceDeviceId);
  }

  Future<void> saveLastAlarmSnapshot({
    required String vehicleName,
    required String alarmMessage,
    required bool isActive,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLastAlarmVehicleName, vehicleName);
    await prefs.setString(_kLastAlarmMessage, alarmMessage);
    await prefs.setBool(_kLastAlarmActive, isActive);
  }

  Future<({String vehicleName, String alarmMessage, bool isActive})>
      loadLastAlarmSnapshot() async {
    final prefs = await SharedPreferences.getInstance();
    return (
      vehicleName: prefs.getString(_kLastAlarmVehicleName) ?? '',
      alarmMessage: prefs.getString(_kLastAlarmMessage) ?? '',
      isActive: prefs.getBool(_kLastAlarmActive) ?? false,
    );
  }
}
