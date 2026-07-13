import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import 'data/project_members.dart';
import 'services/app_log_service.dart';
import 'services/alert_coordinator.dart';
import 'services/background_runtime_service.dart';
import 'services/bluetooth_service.dart';
import 'services/settings_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BabyCareApp());
}

class BabyCareApp extends StatelessWidget {
  const BabyCareApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BabyCare Alert',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0B8F7A)),
        useMaterial3: true,
      ),
      home: const MainShell(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> with WidgetsBindingObserver {
  final AlertCoordinator _coordinator = AlertCoordinator();
  final BackgroundRuntimeService _backgroundRuntimeService =
      BackgroundRuntimeService();
  final BluetoothService _bluetoothService = BluetoothService();
  final SettingsService _settingsService = SettingsService();
  final AppLogService _logService = AppLogService();

  AppSettings _settings = AppSettings.defaults;
  bool _isMonitoring = false;
  bool _isAlarmActive = false;
  bool _isInitializing = true;
  bool _isRequestingPermissions = false;
  DateTime? _permissionLifecycleCooldownUntil;
  String _statusMessage = 'Preparing detection...';
  String _latestAlarmMessage =
      'URGENT: A child has been left in your vehicle!\nReturn immediately to help your child!';
  String _latestVehicleName = '';
  int _selectedTab = 0;
  Timer? _alarmPollTimer;
  StreamSubscription<bool>? _backgroundAlarmSubscription;
  StreamSubscription<Map<String, String>>? _backgroundAlertSubscription;
  StreamSubscription<String>? _uiAlertSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bindUiAlertMessages();
    _bindBackgroundAlertMessages();
    _bindBackgroundAlarmState();
    _bootstrapMonitoring();
  }

  String _buildAlarmMessage(String vehicleName) {
    return 'URGENT: A child has been left in $vehicleName!\n'
        'Return immediately to help your child!';
  }

  String _extractVehicleNameFromAlarmMessage(String message) {
    final pattern = RegExp(r'left in (.+)!\n');
    final match = pattern.firstMatch(message);
    if (match != null && match.groupCount >= 1) {
      final extracted = (match.group(1) ?? '').trim();
      if (extracted.isNotEmpty) {
        return extracted;
      }
    }
    return 'your vehicle';
  }

  void _bindUiAlertMessages() {
    _uiAlertSubscription?.cancel();
    _uiAlertSubscription = _bluetoothService.alertStream.listen((vehicleName) {
      if (!mounted) {
        return;
      }

      final cleanedVehicle = vehicleName.trim().isEmpty
          ? 'your vehicle'
          : vehicleName.trim();
      final nextMessage = _buildAlarmMessage(cleanedVehicle);
      setState(() {
        _latestVehicleName = cleanedVehicle;
        _latestAlarmMessage = nextMessage;
        if (_isAlarmActive) {
          _statusMessage = nextMessage;
        }
      });
    });
  }

  void _bindBackgroundAlarmState() {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }

    _backgroundAlarmSubscription?.cancel();
    _backgroundAlarmSubscription = _backgroundRuntimeService.alarmStateStream
        .listen((isActive) {
          if (!mounted) {
            return;
          }

          if (_isAlarmActive != isActive) {
            setState(() {
              _isAlarmActive = isActive;
              if (isActive) {
                _statusMessage = _latestAlarmMessage;
              } else if (_isMonitoring) {
                _statusMessage = 'Detection is active';
              }
            });
          }
        });
  }

  void _bindBackgroundAlertMessages() {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }

    _backgroundAlertSubscription?.cancel();
    _backgroundAlertSubscription = _backgroundRuntimeService.alarmAlertStream
        .listen((payload) {
          if (!mounted) {
            return;
          }

          final incomingVehicle = (payload['vehicleName'] ?? '').trim();
          final incomingMessage = (payload['message'] ?? '').trim();

          final cleanedVehicle = incomingVehicle.isEmpty
              ? 'your vehicle'
              : incomingVehicle;
          final nextMessage = incomingMessage.isEmpty
              ? _buildAlarmMessage(cleanedVehicle)
              : incomingMessage;
          final resolvedVehicleName = incomingVehicle.isNotEmpty
              ? incomingVehicle
              : _extractVehicleNameFromAlarmMessage(nextMessage);

          setState(() {
            _latestVehicleName = resolvedVehicleName;
            _latestAlarmMessage = nextMessage;
            if (_isAlarmActive) {
              _statusMessage = nextMessage;
            }
          });
        });
  }

  Future<void> _bootstrapMonitoring() async {
    _settings = await _settingsService.load();
    _applySettings();
    final lastAlarmSnapshot = await _settingsService.loadLastAlarmSnapshot();

    _isRequestingPermissions = true;
    final permissionsGranted = await _checkPermissions();
    _isRequestingPermissions = false;
    _permissionLifecycleCooldownUntil = DateTime.now().add(
      const Duration(seconds: 3),
    );
    if (!mounted) return;

    if (lastAlarmSnapshot.vehicleName.isNotEmpty ||
        lastAlarmSnapshot.alarmMessage.isNotEmpty ||
        lastAlarmSnapshot.isActive) {
      setState(() {
        _latestVehicleName = lastAlarmSnapshot.vehicleName;
        if (lastAlarmSnapshot.alarmMessage.isNotEmpty) {
          _latestAlarmMessage = lastAlarmSnapshot.alarmMessage;
        }
        _isAlarmActive = lastAlarmSnapshot.isActive;
      });
    }

    if (!permissionsGranted) {
      setState(() {
        _isInitializing = false;
        _statusMessage = 'Permissions denied. Detection cannot start.';
      });
      _logService.log('APP', 'Permissions denied by user');
      return;
    }

    if (_settings.detectionEnabled) {
      await _startMonitoring(automatic: true);
    } else {
      setState(() {
        _isInitializing = false;
        _statusMessage = 'Detection is disabled in settings';
      });
    }
  }

  void _applySettings() {
    _bluetoothService.configureMonitoring(
      scanEvaluationInterval: Duration(
        seconds: _settings.detectionIntervalSeconds,
      ),
      referenceName: _settings.referenceName,
      referenceDeviceId: _settings.referenceDeviceId,
    );
  }

  // Check and request the required permissions.
  Future<bool> _checkPermissions() async {
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
      Permission.notification,
    ].request();

    var batteryOptimizationGranted = true;
    if (defaultTargetPlatform == TargetPlatform.android) {
      final batteryStatus = await Permission.ignoreBatteryOptimizations
          .request();
      batteryOptimizationGranted = batteryStatus.isGranted;
    }

    final allGranted =
        statuses[Permission.bluetoothScan]?.isGranted == true &&
        statuses[Permission.bluetoothConnect]?.isGranted == true &&
        statuses[Permission.locationWhenInUse]?.isGranted == true &&
        statuses[Permission.notification]?.isGranted == true &&
        batteryOptimizationGranted;

    if (!allGranted) {
      _logService.log('APP', 'Permissions denied or incomplete: $statuses');
      return false;
    }

    return true;
  }

  // Start monitoring.
  Future<void> _startMonitoring({bool automatic = false}) async {
    if (_isMonitoring) return;

    final permissionsGranted = await _checkPermissions();
    if (!permissionsGranted) {
      if (!mounted) return;
      setState(() {
        _isInitializing = false;
        _statusMessage =
            'Missing permissions. Allow Bluetooth, location, notifications and battery optimization exemption.';
      });
      _logService.log(
        'APP',
        'Monitoring start cancelled: missing BLE/runtime permissions',
      );
      return;
    }

    // Let Android fully propagate the runtime state right after the popup.
    await Future<void>.delayed(const Duration(milliseconds: 300));

    setState(() {
      _isInitializing = true;
      _statusMessage = automatic
          ? 'Automatically enabling detection...'
          : 'Restarting detection...';
    });

    try {
      // On Android, force the runtime into the foreground to ensure
      // detection works even with the screen off / phone locked.
      if (_settings.runInBackground ||
          defaultTargetPlatform == TargetPlatform.android) {
        await _backgroundRuntimeService.startIfNeeded();
      }

      await _coordinator.start();
      if (!mounted) return;

      setState(() {
        _isMonitoring = true;
        _isInitializing = false;
        _statusMessage = 'Detection is active';
      });
      _logService.log('APP', 'Monitoring started');
      _checkAlarmStatus();
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _isInitializing = false;
        _statusMessage = 'Error: $e';
      });
      _logService.log('APP', 'Monitoring start failed: $e');
    }
  }

  Future<void> _stopMonitoring({bool byUser = true}) async {
    await _coordinator.stop();
    await _backgroundRuntimeService.stopIfRunning();
    _alarmPollTimer?.cancel();
    _alarmPollTimer = null;

    if (!mounted) return;

    setState(() {
      _isMonitoring = false;
      _isAlarmActive = false;
      _isInitializing = false;
      _statusMessage = byUser
          ? 'Detection stopped manually'
          : 'Detection stopped automatically';
    });

    _logService.log(
      'APP',
      byUser ? 'Detection stopped by user' : 'Detection stopped automatically',
    );
  }

  void _checkAlarmStatus() {
    if (defaultTargetPlatform == TargetPlatform.android) {
      _alarmPollTimer?.cancel();
      // The background stream can sometimes miss a state transition.
      // Light polling keeps the Stop button synced with the native alarm.
      _alarmPollTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
        if (!mounted || !_isMonitoring) {
          return;
        }
        await _backgroundRuntimeService.refreshAlarmState();
      });
      return;
    }

    _alarmPollTimer?.cancel();
    _alarmPollTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted || !_isMonitoring) {
        return;
      }

      final alarmActive = _coordinator.isAlarmPlaying;
      if (_isAlarmActive != alarmActive) {
        setState(() {
          _isAlarmActive = alarmActive;
        });
      }
    });
  }

  Future<void> _stopAlarm() async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      await _backgroundRuntimeService.stopAlarm();
    } else {
      await _coordinator.stopAlarm();
    }
    if (!mounted) return;

    setState(() {
      _isAlarmActive = false;
      if (_isMonitoring) {
        _statusMessage = 'Detection is active';
      }
    });

    _logService.log('APP', 'Alarm stopped from UI');
  }

  Future<void> _saveSettings(AppSettings next) async {
    final clampedInterval = next.detectionIntervalSeconds.clamp(1, 30);
    final safeSettings = next.copyWith(
      detectionIntervalSeconds: clampedInterval,
    );

    await _settingsService.save(safeSettings);
    _settings = safeSettings;
    _applySettings();

    if (!_settings.detectionEnabled && _isMonitoring) {
      await _stopMonitoring(byUser: true);
    }

    if (_settings.detectionEnabled &&
        _isMonitoring &&
        !_isInitializing &&
        (_settings.runInBackground ||
            defaultTargetPlatform == TargetPlatform.android)) {
      await _backgroundRuntimeService.startIfNeeded();
    }

    if (_isMonitoring &&
        !_settings.runInBackground &&
        defaultTargetPlatform != TargetPlatform.android) {
      await _backgroundRuntimeService.stopIfRunning();
    }

    if (_settings.detectionEnabled && !_isMonitoring && !_isInitializing) {
      await _startMonitoring();
    }

    if (mounted) {
      setState(() {});
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_isInitializing || _isRequestingPermissions) {
      return;
    }

    final cooldownUntil = _permissionLifecycleCooldownUntil;
    if (cooldownUntil != null && DateTime.now().isBefore(cooldownUntil)) {
      return;
    }

    if (!_settings.detectionEnabled) {
      return;
    }

    // Android 14+ blocks background-triggered FGS starts from lifecycle transitions.
    // Start/refresh is now only done while the app is in the foreground/user flow.

    if (!_settings.runInBackground &&
        defaultTargetPlatform != TargetPlatform.android &&
        (state == AppLifecycleState.paused ||
            state == AppLifecycleState.inactive ||
            state == AppLifecycleState.detached)) {
      if (_isMonitoring) {
        _stopMonitoring(byUser: false);
      }
      return;
    }

    if (state == AppLifecycleState.resumed && _settings.detectionEnabled) {
      if (!_isMonitoring && !_isInitializing) {
        _startMonitoring(automatic: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final effectiveVehicleName = _latestVehicleName.trim().isNotEmpty
        ? _latestVehicleName.trim()
        : _extractVehicleNameFromAlarmMessage(_latestAlarmMessage);

    final tabs = <Widget>[
      _HomeTab(
        isMonitoring: _isMonitoring,
        isAlarmActive: _isAlarmActive,
        isInitializing: _isInitializing,
        statusMessage: _statusMessage,
        alarmMessage: _latestAlarmMessage,
        vehicleName: effectiveVehicleName,
        onStopAlarm: _stopAlarm,
        onToggleMonitoring: () async {
          if (_isMonitoring) {
            await _stopMonitoring();
          } else {
            await _saveSettings(_settings.copyWith(detectionEnabled: true));
            await _startMonitoring();
          }
        },
      ),
      _LogsTab(logService: _logService),
      _SettingsTab(settings: _settings, onChanged: _saveSettings),
      const _MembersTab(),
    ];

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text(_tabTitle(_selectedTab)),
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[
              Color(0xFF072A3A),
              Color(0xFF0B8F7A),
              Color(0xFFF6B73C),
            ],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: tabs[_selectedTab],
          ),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedTab,
        onDestinationSelected: (value) {
          setState(() {
            _selectedTab = value;
          });
        },
        destinations: const <NavigationDestination>[
          NavigationDestination(icon: Icon(Icons.home_rounded), label: 'Home'),
          NavigationDestination(
            icon: Icon(Icons.receipt_long_rounded),
            label: 'Logs',
          ),
          NavigationDestination(
            icon: Icon(Icons.tune_rounded),
            label: 'Settings',
          ),
          NavigationDestination(
            icon: Icon(Icons.groups_rounded),
            label: 'Members',
          ),
        ],
      ),
    );
  }

  String _tabTitle(int index) {
    switch (index) {
      case 0:
        return 'BabyCare';
      case 1:
        return 'Logs';
      case 2:
        return 'Settings';
      case 3:
        return 'Project Members';
      default:
        return 'BabyCare';
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _alarmPollTimer?.cancel();
    _backgroundAlarmSubscription?.cancel();
    _backgroundAlertSubscription?.cancel();
    _uiAlertSubscription?.cancel();
    _coordinator.stop();
    _backgroundRuntimeService.stopIfRunning();
    super.dispose();
  }
}

class _GlassPanel extends StatelessWidget {
  const _GlassPanel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
      ),
      child: child,
    );
  }
}

class _HomeTab extends StatelessWidget {
  const _HomeTab({
    required this.isMonitoring,
    required this.isAlarmActive,
    required this.isInitializing,
    required this.statusMessage,
    required this.alarmMessage,
    required this.vehicleName,
    required this.onStopAlarm,
    required this.onToggleMonitoring,
  });

  final bool isMonitoring;
  final bool isAlarmActive;
  final bool isInitializing;
  final String statusMessage;
  final String alarmMessage;
  final String vehicleName;
  final Future<void> Function() onStopAlarm;
  final Future<void> Function() onToggleMonitoring;

  @override
  Widget build(BuildContext context) {
    final displayMessage = isAlarmActive ? alarmMessage : statusMessage;
    final displayVehicleName = vehicleName.trim().isNotEmpty
      ? vehicleName.trim()
      : 'your vehicle';
    final icon = isMonitoring
        ? (isAlarmActive
              ? Icons.notification_important_rounded
              : Icons.radar_rounded)
        : Icons.bluetooth_disabled_rounded;

    final color = isAlarmActive
        ? const Color(0xFFD7263D)
        : (isMonitoring ? const Color(0xFF0B8F7A) : const Color(0xFF5F6B73));

    return ListView(
      children: <Widget>[
        const SizedBox(height: 16),
        _GlassPanel(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: <Widget>[
                TweenAnimationBuilder<double>(
                  tween: Tween<double>(begin: 0.85, end: 1),
                  duration: const Duration(milliseconds: 900),
                  curve: Curves.easeOutBack,
                  builder: (context, value, child) {
                    return Transform.scale(scale: value, child: child);
                  },
                  child: Icon(icon, size: 92, color: color),
                ),
                const SizedBox(height: 16),
                if (isAlarmActive)
                  Column(
                    children: [
                      Text(
                        'Vehicle Info:',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: Colors.white70,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        displayVehicleName,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(
                              color: const Color(0xFFF6B73C),
                              fontWeight: FontWeight.w800,
                            ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'URGENT: A child has been left in the vehicle!\nReturn immediately to help your child!',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                    ],
                  )
                else
                  Text(
                    displayMessage,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  children: <Widget>[
                    Chip(
                      avatar: Icon(
                        isMonitoring
                            ? Icons.check_circle_rounded
                            : Icons.pause_circle_rounded,
                        size: 18,
                        color: Colors.white,
                      ),
                      label: Text(
                        isMonitoring
                            ? 'Detection active'
                            : 'Detection inactive',
                      ),
                      labelStyle: const TextStyle(color: Colors.white),
                      backgroundColor: Colors.black26,
                    ),
                    if (isAlarmActive)
                      const Chip(
                        avatar: Icon(
                          Icons.warning_amber_rounded,
                          color: Colors.white,
                          size: 18,
                        ),
                        label: Text('Alarm is active'),
                        labelStyle: TextStyle(color: Colors.white),
                        backgroundColor: Color(0x88D7263D),
                      ),
                  ],
                ),
                if (isInitializing) ...<Widget>[
                  const SizedBox(height: 12),
                  const CircularProgressIndicator(color: Colors.white),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        Row(
          children: <Widget>[
            Expanded(
              child: FilledButton.icon(
                onPressed: isInitializing ? null : onToggleMonitoring,
                icon: Icon(
                  isMonitoring ? Icons.stop_rounded : Icons.play_arrow_rounded,
                ),
                label: Text(
                  isMonitoring ? 'Stop detection' : 'Enable detection',
                ),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                  backgroundColor: isMonitoring
                      ? const Color(0xFF402D2D)
                      : const Color(0xFF094E58),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                onPressed: isAlarmActive ? onStopAlarm : null,
                icon: const Icon(Icons.notifications_off_rounded),
                label: const Text('Stop alarm'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                  backgroundColor: isAlarmActive
                      ? const Color(0xFFD7263D)
                      : const Color(0xFF6E7781),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        const _GlassPanel(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Monitoring can stay active in the background based on your settings. '
              'If detection is disabled in Settings, the app automatically stops scanning.',
              style: TextStyle(color: Colors.white, height: 1.45),
            ),
          ),
        ),
      ],
    );
  }
}

class _LogsTab extends StatelessWidget {
  const _LogsTab({required this.logService});

  final AppLogService logService;

  String _formatTime(DateTime value) {
    final h = value.hour.toString().padLeft(2, '0');
    final m = value.minute.toString().padLeft(2, '0');
    final s = value.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Row(
          children: <Widget>[
            const Expanded(
              child: Text(
                'Application logs',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            FilledButton.tonalIcon(
              onPressed: logService.clear,
              icon: const Icon(Icons.delete_sweep_rounded),
              label: const Text('Clear'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Expanded(
          child: _GlassPanel(
            child: ValueListenableBuilder<List<AppLogEntry>>(
              valueListenable: logService.entries,
              builder: (context, entries, _) {
                if (entries.isEmpty) {
                  return const Center(
                    child: Text(
                      'No logs yet',
                      style: TextStyle(color: Colors.white),
                    ),
                  );
                }

                return ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: entries.length,
                  separatorBuilder: (_, index) => Divider(
                    color: Colors.white.withValues(alpha: 0.2),
                    height: 10,
                  ),
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black26,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            entry.source,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                _formatTime(entry.timestamp),
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.8),
                                  fontSize: 12,
                                ),
                              ),
                              Text(
                                entry.message,
                                style: const TextStyle(color: Colors.white),
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _SettingsTab extends StatefulWidget {
  const _SettingsTab({required this.settings, required this.onChanged});

  final AppSettings settings;
  final Future<void> Function(AppSettings settings) onChanged;

  @override
  State<_SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<_SettingsTab> {
  static const MethodChannel _configChannel = MethodChannel('babycare/config');
  late TextEditingController _referenceNameController;
  late TextEditingController _referenceIdController;

  @override
  void initState() {
    super.initState();
    _referenceNameController = TextEditingController(
      text: widget.settings.referenceName,
    );
    _referenceIdController = TextEditingController(
      text: widget.settings.referenceDeviceId,
    );
  }

  @override
  void didUpdateWidget(covariant _SettingsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settings.referenceName != widget.settings.referenceName) {
      _referenceNameController.text = widget.settings.referenceName;
    }
    if (oldWidget.settings.referenceDeviceId !=
        widget.settings.referenceDeviceId) {
      _referenceIdController.text = widget.settings.referenceDeviceId;
    }
  }

  @override
  void dispose() {
    _referenceNameController.dispose();
    _referenceIdController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: <Widget>[
        _GlassPanel(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: <Widget>[
                SwitchListTile(
                  value: widget.settings.detectionEnabled,
                  activeThumbColor: const Color(0xFFF6B73C),
                  title: const Text(
                    'Enable continuous detection',
                    style: TextStyle(color: Colors.white),
                  ),
                  subtitle: const Text(
                    'If disabled, monitoring is stopped.',
                    style: TextStyle(color: Colors.white70),
                  ),
                  onChanged: (value) {
                    widget.onChanged(
                      widget.settings.copyWith(detectionEnabled: value),
                    );
                  },
                ),
                SwitchListTile(
                  value: widget.settings.runInBackground,
                  activeThumbColor: const Color(0xFFF6B73C),
                  title: const Text(
                    'Keep running in background',
                    style: TextStyle(color: Colors.white),
                  ),
                  subtitle: const Text(
                    'If disabled, monitoring stops when the app goes to background.',
                    style: TextStyle(color: Colors.white70),
                  ),
                  onChanged: (value) {
                    widget.onChanged(
                      widget.settings.copyWith(runInBackground: value),
                    );
                  },
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    onPressed: () async {
                      try {
                        await _configChannel.invokeMethod(
                          'openVehicleConfiguration',
                        );
                      } on PlatformException {
                        if (!context.mounted) {
                          return;
                        }
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Unable to open vehicle configuration.',
                            ),
                          ),
                        );
                      }
                    },
                    icon: const Icon(Icons.directions_car_rounded),
                    label: const Text('Configure vehicle name (ESP32)'),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        _GlassPanel(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  'Interval between evaluations (1-30s)',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Slider(
                  value: widget.settings.detectionIntervalSeconds.toDouble(),
                  min: 1,
                  max: 30,
                  divisions: 29,
                  activeColor: const Color(0xFFF6B73C),
                  label: '${widget.settings.detectionIntervalSeconds}s',
                  onChanged: (value) {
                    widget.onChanged(
                      widget.settings.copyWith(
                        detectionIntervalSeconds: value.round(),
                      ),
                    );
                  },
                ),
                Text(
                  'Current value: ${widget.settings.detectionIntervalSeconds}s',
                  style: const TextStyle(color: Colors.white70),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        _GlassPanel(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  'Reference ESP32',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _referenceNameController,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: 'BLE name (prefix)',
                    labelStyle: TextStyle(color: Colors.white70),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _referenceIdController,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: 'Optional MAC address',
                    labelStyle: TextStyle(color: Colors.white70),
                    hintText: 'Ex: 5C:01:3B:96:B0:8E',
                    hintStyle: TextStyle(color: Colors.white54),
                  ),
                ),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.icon(
                    onPressed: () {
                      widget.onChanged(
                        widget.settings.copyWith(
                          referenceName: _referenceNameController.text.trim(),
                          referenceDeviceId: _referenceIdController.text.trim(),
                        ),
                      );
                    },
                    icon: const Icon(Icons.save_rounded),
                    label: const Text('Save'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _MembersTab extends StatefulWidget {
  const _MembersTab();

  @override
  State<_MembersTab> createState() => _MembersTabState();
}

class _MembersTabState extends State<_MembersTab> {
  late final PageController _membersPageController;

  @override
  void initState() {
    super.initState();
    final memberCount = projectMembers.length;
    final initialPage = memberCount > 0 ? memberCount * 1000 : 0;
    _membersPageController = PageController(
      viewportFraction: 0.9,
      initialPage: initialPage,
    );
  }

  @override
  void dispose() {
    _membersPageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (projectMembers.isEmpty) {
      return const Center(
        child: Text(
          'No configured members.',
          style: TextStyle(color: Colors.white),
        ),
      );
    }

    return Column(
      children: <Widget>[
        const _GlassPanel(
          child: Padding(
            padding: EdgeInsets.all(14),
            child: Text(
              'Swipe horizontally to browse project members.',
              style: TextStyle(color: Colors.white),
              textAlign: TextAlign.center,
            ),
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: PageView.builder(
            controller: _membersPageController,
            itemBuilder: (context, index) {
              final safeIndex = index % projectMembers.length;
              final member = projectMembers[safeIndex];
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: _GlassPanel(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Center(
                          child: CircleAvatar(
                            radius: 50,
                            backgroundColor: Colors.white24,
                            foregroundImage: member.imageAsset != null
                                ? AssetImage(member.imageAsset!)
                                : null,
                            child: member.imageAsset == null
                                ? const Icon(
                                    Icons.person_rounded,
                                    size: 56,
                                    color: Colors.white,
                                  )
                                : null,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          member.name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          member.role,
                          style: const TextStyle(
                            color: Color(0xFFFFE28A),
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 14),
                        Expanded(
                          child: SingleChildScrollView(
                            child: Text(
                              member.description,
                              style: const TextStyle(
                                color: Colors.white,
                                height: 1.45,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
