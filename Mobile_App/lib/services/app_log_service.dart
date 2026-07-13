import 'package:flutter/foundation.dart';

class AppLogEntry {
  const AppLogEntry({
    required this.source,
    required this.message,
    required this.timestamp,
  });

  final String source;
  final String message;
  final DateTime timestamp;
}

class AppLogService {
  AppLogService._();

  static final AppLogService _instance = AppLogService._();
  factory AppLogService() => _instance;

  static const int _maxEntries = 500;

  final ValueNotifier<List<AppLogEntry>> _entries =
      ValueNotifier<List<AppLogEntry>>(<AppLogEntry>[]);

  ValueListenable<List<AppLogEntry>> get entries => _entries;

  void log(String source, String message) {
    final next = List<AppLogEntry>.from(_entries.value)
      ..insert(
        0,
        AppLogEntry(
          source: source,
          message: message,
          timestamp: DateTime.now(),
        ),
      );

    if (next.length > _maxEntries) {
      next.removeRange(_maxEntries, next.length);
    }

    _entries.value = next;
  }

  void clear() {
    _entries.value = <AppLogEntry>[];
  }
}
