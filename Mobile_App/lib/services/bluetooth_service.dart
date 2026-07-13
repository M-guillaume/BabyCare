import 'dart:async';
import 'dart:convert';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import 'app_log_service.dart';

class BluetoothService {
  static final BluetoothService _instance = BluetoothService._internal();
  factory BluetoothService() => _instance;
  BluetoothService._internal();

  static const Duration _alertCooldown = Duration(seconds: 5);
  static const String _expectedNamePrefix = "ALERT_BabyCare";
  static const String _expectedNativeEmitterName = 'ALERT_BABYCARE_ESP32';

  static const String _bleChannelId = 'babycare/ble_scan';
  static const String _prefsKeyResultsCount = 'ble_results_count';
  static const String _prefsKeyResultsCountPrefixed =
      'flutter.ble_results_count';
  static const String _prefsKeyNativeScanActive = 'ble_scan_active';
  static const String _prefsKeyNativeScanActivePrefixed =
      'flutter.ble_scan_active';
  static const String _prefsResultPrefix = 'ble_result_';
  static const String _prefsResultPrefixPrefixed = 'flutter.ble_result_';

  // Stream controller used to notify when an alert signal is received.
  final _alertStreamController = StreamController<String>.broadcast();
  Stream<String> get alertStream => _alertStreamController.stream;

  // Expected security code (can be customized)
  static const String securityCode = "ALERT_2024";

  final Map<String, DateTime> _lastAlertAtByDevice = {};
  // Per-device throttle: avoids processing the same device too often.
  final Map<String, DateTime> _lastEvaluationAtByDevice = {};
  int _scanResultCount = 0;
  StreamSubscription<List<ScanResult>>? _scanSubscription;
  Timer? _scanWatchdogTimer;
  Timer? _nativeBleResultsPollerTimer;
  bool _isScanning = false;
  bool _isRestartingScan = false;
  DateTime? _lastScanResultAt;
  Duration _scanEvaluationInterval = const Duration(seconds: 2);
  String _referenceName = 'BABYCARE_ESP32';
  String _referenceDeviceId = '';

  final MethodChannel _bleChannel = MethodChannel(_bleChannelId);

  bool get _androidNativePrimaryMode =>
      defaultTargetPlatform == TargetPlatform.android;

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
    AppLogService().log('BLE', message);
  }

  void configureMonitoring({
    required Duration scanEvaluationInterval,
    required String referenceName,
    required String referenceDeviceId,
  }) {
    final requestedMs = scanEvaluationInterval.inMilliseconds;
    final boundedMs = requestedMs.clamp(200, 1200);
    _scanEvaluationInterval = Duration(milliseconds: boundedMs);
    _referenceName = referenceName.trim().toUpperCase();
    _referenceDeviceId = referenceDeviceId.trim().toUpperCase();
    _log(
      'Configuration applied | interval=${_scanEvaluationInterval.inSeconds}s | '
      'refName=$_referenceName | refId=${_referenceDeviceId.isEmpty ? 'N/A' : _referenceDeviceId}',
    );
  }

  // Start Bluetooth scanning.
  Future<bool> startScanning() async {
    if (_isScanning) return true;

    try {
      final permissionsGranted = await _hasRequiredAndroidBlePermissions();
      if (!permissionsGranted) {
        _log('Missing BLE permissions: scan cancelled');
        return false;
      }

      // Check whether Bluetooth is enabled.
      final isSupported = await FlutterBluePlus.isSupported;
      _log('Bluetooth supported: $isSupported');
      if (!isSupported) {
        _log('Bluetooth is not supported on this device');
        return false;
      }

      // Check Bluetooth state.
      final adapterState = await FlutterBluePlus.adapterState.first;
      _log('Adapter state: $adapterState');
      if (adapterState != BluetoothAdapterState.on) {
        _log('Bluetooth is disabled');
        return false;
      }

      _log('Starting Bluetooth scan...');

      if (_androidNativePrimaryMode) {
        final nativeStarted = await _startNativeBleScanner();
        if (!nativeStarted) {
          _log('Unable to start the native Android BLE scanner');
          return false;
        }

        await _scanSubscription?.cancel();
        _scanSubscription = null;

        // Start polling native BLE results (SharedPreferences).
        _startNativeBleResultsPoller();
        _lastScanResultAt = DateTime.now();
        _startScanWatchdog();
      } else {
        await _scanSubscription?.cancel();
        _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
          if (results.isEmpty) return;
          _lastScanResultAt = DateTime.now();
          _scanResultCount += results.length;
          if (_scanResultCount % 25 == 0) {
            _log('Processed results: $_scanResultCount');
          }
          for (final result in results) {
            _handleScanResult(result);
          }
        });

        await _startPlatformScan();
        _startScanWatchdog();
      }

      _isScanning = true;
      _log('Bluetooth scan active');
      return true;
    } catch (e) {
      _log('Bluetooth scan error: $e');
      _isScanning = false;
      await _scanSubscription?.cancel();
      _scanSubscription = null;
      return false;
    }
  }

  Future<bool> _startNativeBleScanner() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }

    try {
      final success = await _bleChannel.invokeMethod<bool>(
        'startNativeBLEScan',
      );
      if (success == true) {
        _log('Native BLE scanner started');
        return true;
      }
      final stillActive = await _readNativeScanActiveFlag();
      if (stillActive) {
        _log('Native scanner already active (SharedPreferences fallback)');
        return true;
      }
      _log('Native BLE scanner start failed');
      return false;
    } catch (e) {
      final stillActive = await _readNativeScanActiveFlag();
      if (stillActive) {
        _log(
          'BLE channel unavailable but native scanner is already active (fallback)',
        );
        return true;
      }
      _log('Exception startNativeBleScanner: $e');
      return false;
    }
  }

  Future<bool> _readNativeScanActiveFlag() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return (prefs.getBool(_prefsKeyNativeScanActivePrefixed) ??
              prefs.getBool(_prefsKeyNativeScanActive)) ==
          true;
    } catch (_) {
      return false;
    }
  }

  void _startNativeBleResultsPoller() {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }

    _nativeBleResultsPollerTimer?.cancel();
    _nativeBleResultsPollerTimer = Timer.periodic(const Duration(seconds: 1), (
      _,
    ) async {
      await _pollNativeBleResults();
    });
  }

  Future<void> _pollNativeBleResults() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final currentCount =
          prefs.getInt(_prefsKeyResultsCount) ??
          prefs.getInt(_prefsKeyResultsCountPrefixed) ??
          0;

      // Le compteur peut être remis à 0 après chaque poll ; ne pas se baser
      // sur une progression monotone sinon les nouveaux résultats sont ignorés.
      if (currentCount <= 0) {
        return;
      }

      // Récupère tous les résultats BLE stockés
      final keys = prefs.getKeys();
      var processed = 0;
      for (final key in keys) {
        if (key.startsWith(_prefsResultPrefix) ||
            key.startsWith(_prefsResultPrefixPrefixed)) {
          final jsonStr = prefs.getString(key);
          if (jsonStr != null) {
            try {
              final data = jsonDecode(jsonStr) as Map<String, dynamic>;
              final name = data['name'] as String?;
              final address = data['address'] as String?;
              final rssi = data['rssi'] as int?;
              final payloadHint = data['payloadHint'] as String?;

              if (name != null && address != null && rssi != null) {
                _handleNativeBleResult(
                  name,
                  address,
                  rssi,
                  payloadHint: payloadHint,
                );
                processed++;
              }

              // Supprime le résultat après traitement
              await prefs.remove(key);
            } catch (e) {
              _log('Native BLE result parsing error: $e');
              await prefs.remove(key);
            }
          }
        }
      }

      // Reset le compteur
      await prefs.setInt(_prefsKeyResultsCount, 0);
      await prefs.setInt(_prefsKeyResultsCountPrefixed, 0);
      if (processed > 0) {
        _log('Native BLE poll: $processed results processed');
      }
    } catch (e) {
      _log('Native BLE results polling error: $e');
    }
  }

  void _handleNativeBleResult(
    String name,
    String address,
    int rssi, {
    String? payloadHint,
  }) {
    final normalizedName = name.trim().toUpperCase();
    final normalizedPayload = (payloadHint ?? '').trim().toUpperCase();
    final extractedVehicleName = _extractVehicleNameFromPayload(payloadHint);
    final hasValidPayload =
        normalizedPayload.isNotEmpty && _validateAlertSignal(normalizedPayload);

    final isExpectedEmitterName = normalizedName == _expectedNativeEmitterName;
    if (!isExpectedEmitterName && !hasValidPayload && extractedVehicleName == null) {
      _log(
        'Native BLE ignored: name=$name address=$address rssi=$rssi '
        '| invalidEmitter=true',
      );
      return;
    }

    if (!hasValidPayload) {
      _log(
        'Native BLE ignored: name=$name address=$address rssi=$rssi '
        '| validPayload=false payloadHint=${normalizedPayload.isEmpty ? 'N/A' : normalizedPayload}',
      );
      return;
    }

    final now = DateTime.now();
    final lastEval = _lastEvaluationAtByDevice[address];
    if (lastEval != null &&
        now.difference(lastEval) < _scanEvaluationInterval) {
      return;
    }
    _lastEvaluationAtByDevice[address] = now;

    _lastScanResultAt = now;
    _log(
      'Native BLE result accepted: name=$name address=$address rssi=$rssi '
      '| validPayload=$hasValidPayload',
    );

    _emitAlertIfAllowed(address, extractedVehicleName ?? name);
  }

  Future<void> _startPlatformScan() async {
    await FlutterBluePlus.startScan(
      androidUsesFineLocation: true,
      androidScanMode: AndroidScanMode.lowLatency,
      continuousUpdates: true,
      continuousDivisor: 1,
      removeIfGone: const Duration(seconds: 10),
    );
  }

  Future<void> ensureScanContinuity() async {
    if (_isRestartingScan) {
      return;
    }

    if (!_isScanning) {
      _log('Scan continuity: scan inactive, attempting full restart');
      await startScanning();
      return;
    }

    if (_androidNativePrimaryMode) {
      final nativeRunning = await _isNativeBleScannerRunning();
      if (!nativeRunning) {
        _isRestartingScan = true;
        try {
          _log('Scan continuity: native scanner inactive, restarting immediately');
          await _startNativeBleScanner();
        } catch (e) {
          _log('Scan continuity: native scanner restart failed: $e');
        } finally {
          _isRestartingScan = false;
        }
      }
      return;
    }

    if (!FlutterBluePlus.isScanningNow) {
      _isRestartingScan = true;
      try {
        _log('Continuite scan: scan Android interrompu, relance immediate');
        await FlutterBluePlus.stopScan();
        await _startPlatformScan();
      } catch (e) {
        _log('Continuite scan: echec relance scan: $e');
      } finally {
        _isRestartingScan = false;
      }
    }
  }

  Future<bool> _isNativeBleScannerRunning() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }
    try {
      final scanning = await _bleChannel.invokeMethod<bool>(
        'isNativeBLEScanning',
      );
      return scanning == true;
    } catch (e) {
      final fallback = await _readNativeScanActiveFlag();
      _log('Erreur lecture etat scanner natif: $e | fallback=$fallback');
      return fallback;
    }
  }

  void _startScanWatchdog() {
    _scanWatchdogTimer?.cancel();
    _scanWatchdogTimer = Timer.periodic(const Duration(seconds: 20), (_) async {
      if (!_isScanning || _isRestartingScan) {
        return;
      }

      if (_androidNativePrimaryMode) {
        final nativeRunning = await _isNativeBleScannerRunning();
        if (!nativeRunning) {
          _isRestartingScan = true;
          try {
            _log('Watchdog BLE: scanner natif inactif, redemarrage en cours');
            await _startNativeBleScanner();
            _lastScanResultAt = DateTime.now();
            _log('Watchdog BLE: scanner natif redemarre avec succes');
          } catch (e) {
            _log('Watchdog BLE: echec redemarrage scanner natif: $e');
          } finally {
            _isRestartingScan = false;
          }
          return;
        }

        final lastResultAt = _lastScanResultAt;
        if (lastResultAt != null &&
            DateTime.now().difference(lastResultAt) >
                const Duration(seconds: 30)) {
          _isRestartingScan = true;
          try {
            _log(
              'Watchdog BLE: aucun resultat natif recu depuis >30s, relance scanner natif',
            );
            await _startNativeBleScanner();
            _log(
              'Watchdog BLE: relance scanner natif apres inactivite reussie',
            );
          } catch (e) {
            _log(
              'Watchdog BLE: echec relance scanner natif apres inactivite: $e',
            );
          } finally {
            _isRestartingScan = false;
          }
        }
        return;
      }

      if (!FlutterBluePlus.isScanningNow) {
        _isRestartingScan = true;
        try {
          _log('Watchdog BLE: scan inactif detecte, redemarrage en cours');
          await FlutterBluePlus.stopScan();
          await _startPlatformScan();
          _lastScanResultAt = DateTime.now();
          _log('Watchdog BLE: scan redemarre avec succes');
        } catch (e) {
          _log('Watchdog BLE: echec redemarrage scan: $e');
        } finally {
          _isRestartingScan = false;
        }
        return;
      }

      // Certains appareils gardent isScanningNow=true ecran eteint mais cessent
      // de livrer des resultats. On force une relance defensive.
      final lastResultAt = _lastScanResultAt;
      if (lastResultAt != null &&
          DateTime.now().difference(lastResultAt) >
              const Duration(seconds: 20)) {
        _isRestartingScan = true;
        try {
          _log('Watchdog BLE: aucun resultat recu depuis >20s, relance scan');
          if (defaultTargetPlatform == TargetPlatform.android) {
            try {
              final nativeRestarted = await _bleChannel.invokeMethod<bool>(
                'startNativeBLEScan',
              );
              _log(
                'Watchdog BLE: relance scan natif Android: ${nativeRestarted == true}',
              );
            } catch (e) {
              _log('Watchdog BLE: echec relance scan natif Android: $e');
            }
          }
          await FlutterBluePlus.stopScan();
          await _startPlatformScan();
          _lastScanResultAt = DateTime.now();
          _log('Watchdog BLE: relance apres inactivite des resultats reussie');
        } catch (e) {
          _log('Watchdog BLE: echec relance apres inactivite: $e');
        } finally {
          _isRestartingScan = false;
        }
      }
    });
  }

  // Traite un résultat de scan
  void _handleScanResult(ScanResult result) {
    final deviceId = result.device.remoteId.toString();
    final device = result.device;
    final deviceName = _displayName(
      device.platformName,
      result.advertisementData.advName,
    );
    final advertisementData = result.advertisementData;
    final normalizedNames = <String>[
      device.platformName,
      advertisementData.advName,
    ].map((name) => name.trim().toUpperCase());
    final isExpectedEmitter = normalizedNames.any(
      (name) => name.startsWith(_expectedNamePrefix.toUpperCase()),
    );
    final mentionsAlert = normalizedNames.any((name) => name.contains('ALERT'));

    // Ignore les appareils trop éloignés et ceux qui ne ressemblent pas à un émetteur BabyCare.
    if (!isExpectedEmitter) {
      if (mentionsAlert) {
        _log(
          'Signal ignoré | nom=$deviceName | rssi=${result.rssi} | '
          'isExpected=$isExpectedEmitter',
        );
      }
      return;
    }

    final now = DateTime.now();
    final lastEval = _lastEvaluationAtByDevice[deviceId];
    if (lastEval != null &&
        now.difference(lastEval) < _scanEvaluationInterval) {
      return;
    }
    _lastEvaluationAtByDevice[deviceId] = now;

    var hasValidPayload = false;
    String? extractedVehicleName;

    // Regarde dans les manufacturer data
    if (advertisementData.manufacturerData.isNotEmpty) {
      advertisementData.manufacturerData.forEach((key, value) {
        final dataString = _parseData(value);
        if (_validateAlertSignal(dataString)) {
          hasValidPayload = true;
          extractedVehicleName ??= _extractVehicleNameFromPayload(dataString);
        } else if (isExpectedEmitter) {
          _log('Payload manufacturer non reconnu (key=$key): $dataString');
        }
      });
    }

    // Regarde dans les service data
    if (advertisementData.serviceData.isNotEmpty) {
      advertisementData.serviceData.forEach((key, value) {
        final dataString = _parseData(value);
        if (_validateAlertSignal(dataString)) {
          hasValidPayload = true;
          extractedVehicleName ??= _extractVehicleNameFromPayload(dataString);
        } else if (isExpectedEmitter) {
          _log('Payload serviceData non reconnu (key=$key): $dataString');
        }
      });
    }

    if (!hasValidPayload) {
      if (mentionsAlert) {
        _log('Nom valide mais payload non valide pour $deviceName');
      }
      return;
    }

    _log(
      'Signal accepté | nom=$deviceName | rssi=${result.rssi} | '
      'payloadValide=$hasValidPayload',
    );
    _emitAlertIfAllowed(deviceId, extractedVehicleName ?? deviceName);
  }

  String _displayName(String primaryName, String fallbackName) {
    if (primaryName.trim().isNotEmpty) {
      return primaryName;
    }
    if (fallbackName.trim().isNotEmpty) {
      return fallbackName;
    }
    return 'appareil inconnu';
  }

  void _emitAlertIfAllowed(String deviceId, String deviceName) {
    final now = DateTime.now();
    final lastAlertAt = _lastAlertAtByDevice[deviceId];

    if (lastAlertAt != null && now.difference(lastAlertAt) < _alertCooldown) {
      return;
    }

    _lastAlertAtByDevice[deviceId] = now;
    final isReference = _isReferenceEmitter(deviceId, deviceName);
    final sourceTag = isReference ? ' [reference]' : '';
    _log("Signal d'alerte valide recu de $deviceName$sourceTag");
    _alertStreamController.add(deviceName);
  }

  bool _isReferenceEmitter(String deviceId, String deviceName) {
    final normalizedName = deviceName.trim().toUpperCase();
    final normalizedId = deviceId.trim().toUpperCase();

    final byId =
        _referenceDeviceId.isNotEmpty && normalizedId == _referenceDeviceId;
    final byName =
        _referenceName.isNotEmpty && normalizedName.startsWith(_referenceName);

    return byId || byName;
  }

  // Convertit les bytes en string
  String _parseData(List<int> data) {
    try {
      return utf8.decode(data).replaceAll('\u0000', '').trim();
    } catch (e) {
      // Si ce n'est pas de l'UTF-8, retourne la représentation hex
      return data.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    }
  }

  String? _extractVehicleNameFromPayload(String? payload) {
    final raw = (payload ?? '').trim();
    if (raw.isEmpty) {
      return null;
    }

    const prefix = 'BABYCARE|';
    if (!raw.toUpperCase().startsWith(prefix)) {
      return null;
    }

    final vehicleName = raw.substring(prefix.length).trim();
    if (vehicleName.isEmpty) {
      return null;
    }

    return vehicleName;
  }

  // Valide le nouveau format: BABYCARE|NomVehicule
  bool _validateAlertSignal(String data) {
    final normalized = data.trim().toUpperCase();
    if (normalized.isEmpty) {
      return false;
    }

    const prefix = 'BABYCARE|';
    if (!normalized.startsWith(prefix)) {
      return false;
    }

    final vehicleName = normalized.substring(prefix.length).trim();
    return vehicleName.isNotEmpty;
  }

  // Arrête le scan
  Future<void> stopScanning() async {
    _isScanning = false;
    _scanWatchdogTimer?.cancel();
    _scanWatchdogTimer = null;
    _nativeBleResultsPollerTimer?.cancel();
    _nativeBleResultsPollerTimer = null;

    await _scanSubscription?.cancel();
    _scanSubscription = null;
    if (!_androidNativePrimaryMode) {
      await FlutterBluePlus.stopScan();
    }

    // Arrête le scanner natif
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        await _bleChannel.invokeMethod<bool>('stopNativeBLEScan');
        _log('Native BLE scanner arrêté');
      } catch (e) {
        _log('Erreur arrêt native BLE scanner: $e');
      }
    }

    _lastAlertAtByDevice.clear();
    _lastEvaluationAtByDevice.clear();
    _lastScanResultAt = null;
    _scanResultCount = 0;

    _log('Scan Bluetooth arrêté');
  }

  void dispose() {
    _alertStreamController.close();
    stopScanning();
  }
}
