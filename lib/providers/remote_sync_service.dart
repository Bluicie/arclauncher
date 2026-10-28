import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flauncher/providers/backup_service.dart';
import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

// "backup_" prefix: these keys are device-specific and never exported by BackupService.
const _urlKey = "backup_remote_url";
const _enabledKey = "backup_remote_enabled";
const _lastHashKey = "backup_remote_last_hash";
const _lastCheckKey = "backup_remote_last_check";

/// Keeps this device in sync with a backup file published at a URL
/// (e.g. on Home Assistant, a NAS or any web server): the file is downloaded
/// at startup and periodically, and restored whenever its content changed.
class RemoteSyncService extends ChangeNotifier {
  static const Duration interval = Duration(hours: 6);
  static const Duration startupDelay = Duration(seconds: 30);
  static const Duration timeout = Duration(seconds: 30);
  static const int maxDownloadBytes = 4 * 1024 * 1024;

  final SharedPreferences _sharedPreferences;
  final BackupService _backupService;
  final http.Client _client;

  Timer? _startupTimer;
  Timer? _periodicTimer;
  bool _syncing = false;
  String? _lastError;
  BackupImportResult? _lastResult;

  RemoteSyncService(this._sharedPreferences, this._backupService, {http.Client? client, bool schedule = true})
      : _client = client ?? http.Client() {
    if (schedule) {
      _reschedule(startup: true);
    }
  }

  String get url => _sharedPreferences.getString(_urlKey) ?? "";

  bool get enabled => url.isNotEmpty && (_sharedPreferences.getBool(_enabledKey) ?? false);

  bool get syncing => _syncing;

  /// Error of the last attempt, `null` when it succeeded.
  String? get lastError => _lastError;

  /// Result of the last restore done by this service, if any.
  BackupImportResult? get lastResult => _lastResult;

  DateTime? get lastCheck {
    final value = _sharedPreferences.getString(_lastCheckKey);
    return value == null ? null : DateTime.tryParse(value)?.toLocal();
  }

  Future<void> setUrl(String value) async {
    final trimmed = value.trim();
    if (trimmed.isNotEmpty && Uri.tryParse(trimmed)?.hasScheme != true) {
      throw FormatException("Invalid address: $trimmed");
    }
    await _sharedPreferences.setString(_urlKey, trimmed);
    await _sharedPreferences.remove(_lastHashKey);
    _lastError = null;
    _reschedule();
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    await _sharedPreferences.setBool(_enabledKey, value);
    _reschedule();
    notifyListeners();
    if (enabled) {
      await syncNow();
    }
  }

  void _reschedule({bool startup = false}) {
    _startupTimer?.cancel();
    _periodicTimer?.cancel();
    if (!enabled) {
      return;
    }
    if (startup) {
      _startupTimer = Timer(startupDelay, () => syncNow());
    }
    _periodicTimer = Timer.periodic(interval, (_) => syncNow());
  }

  @override
  void dispose() {
    _startupTimer?.cancel();
    _periodicTimer?.cancel();
    _client.close();
    super.dispose();
  }

  /// Downloads the backup and restores it when it changed since the last restore
  /// (or always, with [force]). Returns `true` when a backup was restored.
  /// Errors are kept in [lastError] instead of being thrown.
  Future<bool> syncNow({bool force = false}) async {
    if (_syncing || url.isEmpty) {
      return false;
    }
    _syncing = true;
    notifyListeners();
    try {
      final body = await _download();
      final hash = contentHash(body);
      await _sharedPreferences.setString(_lastCheckKey, DateTime.now().toUtc().toIso8601String());
      _lastError = null;

      if (!force && hash == _sharedPreferences.getString(_lastHashKey)) {
        return false;
      }
      _lastResult = await _backupService.importFromJson(body);
      await _sharedPreferences.setString(_lastHashKey, hash);
      return true;
    } catch (e) {
      _lastError = e.toString();
      return false;
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  /// Downloads [url], refusing responses larger than [maxDownloadBytes].
  Future<String> _download() async {
    final uri = Uri.parse(url);
    final response = await _client.send(http.Request("GET", uri)).timeout(timeout);
    if (response.statusCode != 200) {
      throw http.ClientException("HTTP ${response.statusCode}", uri);
    }
    if ((response.contentLength ?? 0) > maxDownloadBytes) {
      throw http.ClientException("Backup is too large", uri);
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream.timeout(timeout)) {
      bytes.add(chunk);
      if (bytes.length > maxDownloadBytes) {
        throw http.ClientException("Backup is too large", uri);
      }
    }
    return utf8.decode(bytes.takeBytes());
  }

  /// 32-bit FNV-1a, stable across runs (unlike [String.hashCode]).
  static String contentHash(String content) {
    var hash = 0x811c9dc5;
    for (final byte in utf8.encode(content)) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, "0");
  }
}
