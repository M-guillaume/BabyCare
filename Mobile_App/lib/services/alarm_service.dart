import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:vibration/vibration.dart';

import 'app_log_service.dart';

class AlarmService {
  static final AlarmService _instance = AlarmService._internal();
  factory AlarmService() => _instance;
  AlarmService._internal();

  final FlutterRingtonePlayer _ringtonePlayer = FlutterRingtonePlayer();
  static const MethodChannel _alarmChannel = MethodChannel('babycare/alarm');
  bool _isPlaying = false;

  void _log(String message) {
    AppLogService().log('ALARM', message);
  }

  bool get isPlaying => _isPlaying;

  // Initialize the alarm service.
  Future<void> initialize() async {
    try {
      _log('Alarm service initialized');
    } catch (e) {
      _log('Alarm initialization error: $e');
    }
  }

  // Start the alarm.
  Future<void> startAlarm() async {
    if (_isPlaying) return;

    try {
      _isPlaying = true;

      var started = false;

      if (defaultTargetPlatform == TargetPlatform.android) {
        try {
          final nativeStarted =
              await _alarmChannel.invokeMethod<bool>('startNativeAlarm');
          started = nativeStarted == true;
          _log('Android native alarm start: $started');
        } catch (e) {
          _log('Android native alarm start error: $e');
        }
      }

      if (!started) {
        await _ringtonePlayer.playAlarm(
          looping: true,
          volume: 1.0,
          asAlarm: true,
        );
        _log('Flutter alarm fallback active');
      }

      await _startVibration();
      _log('System alarm started');
    } catch (e) {
      _log('Alarm start error: $e');
      _isPlaying = false;
    }
  }

  // Enable repeated vibration while the alarm is active.
  Future<void> _startVibration() async {
    try {
      final hasVibrator = await Vibration.hasVibrator();
      if (!hasVibrator) {
        _log('No vibration motor available on this device');
        return;
      }

      await Vibration.vibrate(
        pattern: const [0, 1200, 350, 1200],
        repeat: 0,
        intensities: const [0, 255, 0, 255],
      );
    } catch (e) {
      _log('Vibration error: $e');
    }
  }

  // Stop the alarm.
  Future<void> stopAlarm() async {
    try {
      final wasPlaying = _isPlaying;
      _isPlaying = false;

      if (defaultTargetPlatform == TargetPlatform.android) {
        try {
          final nativeStopped =
              await _alarmChannel.invokeMethod<bool>('stopNativeAlarm');
          _log('Android native alarm stop requested: ${nativeStopped == true}');
        } catch (e) {
          _log('Android native alarm stop error: $e');
        }
      }

      await _ringtonePlayer.stop();
      await Vibration.cancel();
      _log(
        wasPlaying
        ? 'Alarm stopped'
        : 'Forced alarm stop (local state was inactive)',
      );
    } catch (e) {
      _log('Alarm stop error: $e');
    }
  }

  // Clean up resources.
  void dispose() {}
}
