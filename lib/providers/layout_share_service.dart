import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flauncher/providers/backup_service.dart';
import 'package:flauncher/providers/backup_web_page.dart';
import 'package:flauncher/providers/quick_actions_service.dart';
import 'package:flauncher/providers/remote_sync_service.dart';
import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

// "backup_" prefix: device-specific, never exported by BackupService.
const _shareEnabledKey = "backup_share_enabled";
const _controlEnabledKey = "backup_control_enabled";
const _clientsKey = "backup_api_clients";
const _deviceIdKey = "backup_device_id";
const _webEnabledKey = "backup_web_enabled";

const int layoutSharePort = 47474;
const int localApiVersion = 1;
const String localApiServiceType = "_arclauncher._tcp";
const String _apiPrefix = "/arc-launcher/v1";
const String layoutShareInfoPath = "$_apiPrefix/info";
const String layoutShareBackupPath = "$_apiPrefix/backup";
const String _webBackupPath = "/arc-launcher/web/backup.json";
const String _webRestorePath = "/arc-launcher/web/restore";

/// A device on the local network that shares its layout.
class SharedLayoutSource {
  final String name;

  /// Stable id of the device, `null` for devices that do not report one.
  final String? id;
  final String host;
  final Uri backupUrl;

  const SharedLayoutSource({required this.name, this.id, required this.host, required this.backupUrl});
}

/// An app (e.g. Home Assistant) that was paired with this device and may control it.
class PairedClient {
  final String name;
  final String token;
  final DateTime created;

  const PairedClient({required this.name, required this.token, required this.created});

  Map<String, dynamic> toJson() => {"name": name, "token": token, "created": created.toUtc().toIso8601String()};

  static PairedClient? fromJson(Object? json) {
    if (json is! Map || json["name"] is! String || json["token"] is! String) {
      return null;
    }
    return PairedClient(
      name: json["name"] as String,
      token: json["token"] as String,
      created: DateTime.tryParse(json["created"] as String? ?? "") ?? DateTime.now(),
    );
  }
}

/// A pairing in progress: [code] is shown on screen and has to be entered in the client.
class PairingRequest {
  final String client;
  final String code;
  final DateTime expires;

  const PairingRequest({required this.client, required this.code, required this.expires});
}

/// A settings file uploaded through the web page, waiting to be confirmed on the TV.
class WebRestoreRequest {
  final String source;
  final int sections;
  final DateTime expires;

  const WebRestoreRequest({required this.source, required this.sections, required this.expires});
}

class _ApiException implements Exception {
  final int status;
  final String message;

  const _ApiException(this.status, this.message);
}

/// Local network API of the launcher (HTTP on [layoutSharePort], announced via mDNS as [localApiServiceType]):
///
/// * **Layout sharing** ("Share this layout"): anyone on the network can read this device's layout
///   (`GET /arc-launcher/v1/backup`) and follow it with [RemoteSyncService].
/// * **Control** ("Allow control from other apps"): paired apps such as Home Assistant can read the status,
///   start a sync or backup, restore a layout and change the sync settings. Pairing shows a code on screen
///   that has to be entered in the app, which then gets its own token.
///
/// * **Web page** ("Download & upload in a browser"): `http://<device>:47474/` lets a phone or computer download
///   the settings file or upload one; an upload is only applied after it is confirmed on the TV.
///
/// Only `GET /arc-launcher/v1/info` is public; it tells which features are enabled.
class LayoutShareService extends ChangeNotifier {
  static const Duration pairingTimeout = Duration(minutes: 2);
  static const int maxPairingAttempts = 5;
  static const Duration pairingBlockTime = Duration(minutes: 5);
  static const Duration _maxPairingBlockTime = Duration(hours: 1);
  static const int _maxClientNameLength = 40;
  static const int _maxBodyBytes = 16 * 1024;
  static const int _maxRestoreBytes = 4 * 1024 * 1024;
  static const int _maxQuickActionsBytes = 64 * 1024;
  static const Duration _bodyTimeout = Duration(seconds: 15);
  static const int _maxConcurrentRequests = 8;
  static const Duration webRestoreTimeout = Duration(minutes: 2);

  final SharedPreferences _sharedPreferences;
  final BackupService _backupService;
  final RemoteSyncService? _remoteSyncService;
  final QuickActionsService? _quickActionsService;
  final Future<String> Function() _deviceName;
  final Future<void> Function(String name, int port, Map<String, String> attributes)? _advertise;
  final Future<void> Function()? _stopAdvertising;
  final int _port;
  final Random _random = Random.secure();

  HttpServer? _server;
  String? _name;
  String? _error;
  PairingRequest? _pairingRequest;
  int _failedPairingAttempts = 0;
  int _pairingBlocks = 0;
  DateTime? _pairingBlockedUntil;
  int _requestsInFlight = 0;
  WebRestoreRequest? _webRestoreRequest;
  Completer<bool>? _webRestoreAnswer;

  LayoutShareService(
    this._sharedPreferences,
    this._backupService,
    this._deviceName, {
    RemoteSyncService? remoteSyncService,
    QuickActionsService? quickActionsService,
    Future<void> Function(String name, int port, Map<String, String> attributes)? advertise,
    Future<void> Function()? stopAdvertising,
    int port = layoutSharePort,
    bool start = true,
  })  : _remoteSyncService = remoteSyncService,
        _quickActionsService = quickActionsService,
        _advertise = advertise,
        _stopAdvertising = stopAdvertising,
        _port = port {
    if (start) {
      _updateServer();
    }
  }

  /// "Share this layout".
  bool get enabled => _sharedPreferences.getBool(_shareEnabledKey) ?? false;

  /// "Allow control from other apps".
  bool get controlEnabled => _sharedPreferences.getBool(_controlEnabledKey) ?? false;

  /// "Download & upload in a browser".
  bool get webEnabled => _sharedPreferences.getBool(_webEnabledKey) ?? false;

  /// The uploaded settings file waiting for confirmation on the TV, if any.
  WebRestoreRequest? get webRestoreRequest => _webRestoreRequest;

  /// Addresses of the web page on this device's local networks.
  Future<List<String>> webAddresses() async {
    final port = _server?.port;
    if (port == null) {
      return const [];
    }
    final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
    return [
      for (final interface in interfaces)
        for (final address in interface.addresses)
          if (!address.isLoopback) "http://${address.address}:$port"
    ];
  }

  bool get running => _server != null;

  /// The port actually listened on (differs from the requested one when that was 0).
  int? get port => _server?.port;

  /// Name other devices see, available once the server runs.
  String? get name => _name;

  String? get error => _error;

  /// The pairing waiting for its code to be entered, if any.
  PairingRequest? get pairingRequest {
    final request = _pairingRequest;
    return request != null && request.expires.isAfter(DateTime.now()) ? request : null;
  }

  List<PairedClient> get clients => (_sharedPreferences.getStringList(_clientsKey) ?? const [])
      .map((value) {
        try {
          return PairedClient.fromJson(jsonDecode(value));
        } catch (_) {
          return null;
        }
      })
      .whereType<PairedClient>()
      .toList();

  /// Stable random id of this device, so clients recognise it when its name or address changes.
  String get deviceId => deviceIdFor(_sharedPreferences);

  static String deviceIdFor(SharedPreferences sharedPreferences) {
    var id = sharedPreferences.getString(_deviceIdKey);
    if (id == null) {
      final random = Random.secure();
      id = List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, "0")).join();
      sharedPreferences.setString(_deviceIdKey, id);
    }
    return id;
  }

  Future<void> setEnabled(bool value) async {
    await _sharedPreferences.setBool(_shareEnabledKey, value);
    await _updateServer();
  }

  Future<void> setControlEnabled(bool value) async {
    await _sharedPreferences.setBool(_controlEnabledKey, value);
    if (!value) {
      // Turning control off revokes every paired app; they have to pair again.
      _pairingRequest = null;
      await _sharedPreferences.remove(_clientsKey);
    }
    await _updateServer();
  }

  Future<void> removeClient(String token) async {
    await _saveClients(clients.where((client) => client.token != token).toList());
    notifyListeners();
  }

  Future<void> setWebEnabled(bool value) async {
    await _sharedPreferences.setBool(_webEnabledKey, value);
    if (!value) {
      answerWebRestore(false);
    }
    await _updateServer();
  }

  /// Applies ([approved]) or rejects the uploaded settings file shown in [webRestoreRequest].
  void answerWebRestore(bool approved) {
    final answer = _webRestoreAnswer;
    if (answer != null && !answer.isCompleted) {
      answer.complete(approved);
    }
  }

  void cancelPairing() {
    _pairingRequest = null;
    notifyListeners();
  }

  Future<void> _saveClients(List<PairedClient> clients) => _sharedPreferences.setStringList(
      _clientsKey, clients.map((client) => jsonEncode(client.toJson())).toList());

  Future<void> _updateServer() async {
    if (enabled || controlEnabled || webEnabled) {
      await startServer();
      await _announce();
    } else {
      await stopServer();
    }
    notifyListeners();
  }

  Future<void> startServer() async {
    if (_server != null) {
      return;
    }
    try {
      _name = await _deviceName();
      if (_name!.trim().isEmpty) {
        _name = Platform.localHostname;
      }
      final server = await HttpServer.bind(InternetAddress.anyIPv4, _port);
      server.listen(_handle);
      _server = server;
      _error = null;
    } catch (e) {
      _error = e.toString();
    }
    notifyListeners();
  }

  Future<void> stopServer() async {
    final server = _server;
    _server = null;
    if (server != null) {
      await _stopAdvertisingSafely();
    }
    await server?.close(force: true);
    notifyListeners();
  }

  Future<void> _announce() async {
    final port = _server?.port;
    if (port == null || _advertise == null) {
      return;
    }
    try {
      await _advertise(_name ?? deviceId, port, {
        "id": deviceId,
        "api": "$localApiVersion",
        "share": enabled ? "1" : "0",
        "control": controlEnabled ? "1" : "0",
        "web": webEnabled ? "1" : "0",
      });
    } catch (_) {
      // Discovery is a convenience; the API keeps working without it.
    }
  }

  Future<void> _stopAdvertisingSafely() async {
    try {
      await _stopAdvertising?.call();
    } catch (_) {}
  }

  @override
  void dispose() {
    _stopAdvertisingSafely();
    _server?.close(force: true);
    super.dispose();
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    _requestsInFlight++;
    try {
      if (_requestsInFlight > _maxConcurrentRequests) {
        throw const _ApiException(HttpStatus.serviceUnavailable, "Busy");
      }
      _checkRequestSource(request);
      if (!await _handleWeb(request)) {
        final result = await _route(request);
        response.statusCode = result.$1;
        if (result.$2 != null) {
          response.headers.contentType = ContentType.json;
          response.write(result.$2);
        }
      }
    } on _ApiException catch (e) {
      response.statusCode = e.status;
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode({"error": e.message}));
    } catch (_) {
      response.statusCode = HttpStatus.internalServerError;
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode({"error": "Internal error"}));
    } finally {
      _requestsInFlight--;
    }
    await response.close();
  }

  /// Only answers clients that talk to this device directly: other web pages cannot use the API, neither
  /// cross-site (they send a foreign Origin header) nor through DNS rebinding (their Host is a domain name).
  /// The device's own web page (same origin) is allowed.
  static void _checkRequestSource(HttpRequest request) {
    final origin = request.headers.value("origin");
    if (origin != null && origin != "http://${request.headers.value(HttpHeaders.hostHeader)}") {
      throw const _ApiException(HttpStatus.forbidden, "Not available to web pages");
    }
    final host = request.headers.host;
    if (host != null &&
        host != "localhost" &&
        !host.endsWith(".local") &&
        InternetAddress.tryParse(host.replaceAll("[", "").replaceAll("]", "")) == null) {
      throw const _ApiException(HttpStatus.forbidden, "Unknown host");
    }
  }

  /// Serves the web page and its download/upload routes; returns whether [request] was one of them.
  Future<bool> _handleWeb(HttpRequest request) async {
    if (!webEnabled) {
      return false;
    }
    final route = "${request.method} ${request.uri.path}";
    final response = request.response;
    if (route == "GET /") {
      response.headers.contentType = ContentType.html;
      response.headers.set(HttpHeaders.cacheControlHeader, "no-store");
      response.write(backupWebPage(_name ?? "Arc Launcher"));
      return true;
    }
    if (route == "GET $_webBackupPath") {
      final backup = BackupService.encode(await _backupService.createBackup());
      final name =
          (_name ?? "tv").toLowerCase().replaceAll(RegExp(r"[^a-z0-9]+"), "-").replaceAll(RegExp(r"^-+|-+$"), "");
      final date = DateTime.now().toIso8601String().substring(0, 10);
      response.headers.contentType = ContentType.json;
      response.headers.set("Content-Disposition", 'attachment; filename="arc-launcher-$name-$date.json"');
      response.write(backup);
      return true;
    }
    if (route == "POST $_webRestorePath") {
      final body = await _readJson(request, maxBytes: _maxRestoreBytes);
      final result = await _confirmAndRestore(body, request.connectionInfo?.remoteAddress.address ?? "?");
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode(result));
      return true;
    }
    return false;
  }

  /// Asks for confirmation on the TV and restores [backup] when it is given.
  Future<Map<String, dynamic>> _confirmAndRestore(Map<String, dynamic> backup, String source) async {
    if (backup["format"] != BackupService.format) {
      throw const _ApiException(HttpStatus.badRequest, "This is not an Arc Launcher settings file");
    }
    if (_webRestoreRequest != null) {
      throw const _ApiException(HttpStatus.conflict, "Another upload is waiting for confirmation on the TV");
    }
    final answer = Completer<bool>();
    _webRestoreAnswer = answer;
    _webRestoreRequest = WebRestoreRequest(
      source: source,
      sections: backup["sections"] is List ? (backup["sections"] as List).length : 0,
      expires: DateTime.now().add(webRestoreTimeout),
    );
    notifyListeners();
    bool approved;
    try {
      approved = await answer.future.timeout(webRestoreTimeout);
    } on TimeoutException {
      throw const _ApiException(HttpStatus.requestTimeout, "Not confirmed on the TV in time");
    } finally {
      _webRestoreRequest = null;
      _webRestoreAnswer = null;
      notifyListeners();
    }
    if (!approved) {
      throw const _ApiException(HttpStatus.forbidden, "The restore was cancelled on the TV");
    }
    try {
      final result = await _backupService.applyBackup(backup);
      return {
        "categories": result.categories,
        "spacers": result.spacers,
        "settings": result.settings,
        "placedApps": result.placedApps,
        "missingApps": result.missingApps,
      };
    } on FormatException catch (e) {
      throw _ApiException(HttpStatus.badRequest, e.message);
    }
  }

  /// Returns the status code and the JSON body (if any).
  Future<(int, String?)> _route(HttpRequest request) async {
    final route = "${request.method} ${request.uri.path}";
    if (route == "GET $layoutShareInfoPath") {
      return (HttpStatus.ok, jsonEncode(_info()));
    } else if (route == "GET $layoutShareBackupPath") {
      if (!enabled) {
        _authorize(request);
      }
      return (HttpStatus.ok, BackupService.encode(await _backupService.createBackup()));
    } else if (route == "POST $_apiPrefix/pair") {
      _checkPairingAllowed();
      return _startPairing(await _readJson(request));
    } else if (route == "POST $_apiPrefix/pair/confirm") {
      if (!controlEnabled) {
        throw const _ApiException(HttpStatus.forbidden, "Control from other apps is turned off on this device");
      }
      return _confirmPairing(await _readJson(request));
    } else if (route == "GET $_apiPrefix/status") {
      _authorize(request);
      return (HttpStatus.ok, jsonEncode(await status()));
    } else if (route == "POST $_apiPrefix/sync") {
      _authorize(request);
      final body = await _readJson(request, optional: true);
      final remoteSync = _requireRemoteSync();
      final restored = await remoteSync.syncNow(force: body["force"] == true);
      return (HttpStatus.ok, jsonEncode({"restored": restored, "error": remoteSync.lastError}));
    } else if (route == "POST $layoutShareBackupPath") {
      _authorize(request);
      final file = await _backupService.exportToFile();
      return (HttpStatus.ok, jsonEncode({"file": path.basename(file.path)}));
    } else if (route == "POST $_apiPrefix/restore") {
      _authorize(request);
      try {
        final result = await _backupService.applyBackup(await _readJson(request, maxBytes: _maxRestoreBytes));
        return (
          HttpStatus.ok,
          jsonEncode({
            "categories": result.categories,
            "spacers": result.spacers,
            "settings": result.settings,
            "placedApps": result.placedApps,
            "missingApps": result.missingApps,
          })
        );
      } on FormatException catch (e) {
        throw _ApiException(HttpStatus.badRequest, e.message);
      }
    } else if (route == "PUT $_apiPrefix/quick-actions") {
      _authorize(request);
      final quickActions = _quickActionsService;
      if (quickActions == null) {
        throw const _ApiException(HttpStatus.notImplemented, "Quick actions are not available");
      }
      final body = await _readJson(request, maxBytes: _maxQuickActionsBytes);
      try {
        final count = await quickActions.setActionsFromJson(body["actions"]);
        return (HttpStatus.ok, jsonEncode({"quickActions": count}));
      } on FormatException catch (e) {
        throw _ApiException(HttpStatus.badRequest, e.message);
      }
    } else if (route == "PUT $_apiPrefix/settings") {
      _authorize(request);
      await _applySettings(await _readJson(request));
      return (HttpStatus.ok, jsonEncode(await status()));
    }
    throw const _ApiException(HttpStatus.notFound, "Not found");
  }

  Map<String, dynamic> _info() => {
        "app": "arc-launcher",
        "name": _name,
        "id": deviceId,
        "api": localApiVersion,
        "sharing": enabled,
        "control": controlEnabled,
        "web": webEnabled,
      };

  /// What paired clients see: sharing/sync settings, last sync and a fingerprint of the current layout.
  Future<Map<String, dynamic>> status() async {
    final backup = await _backupService.createBackup();
    final sections = (backup["sections"] as List).cast<Map<String, dynamic>>();
    final remoteSync = _remoteSyncService;
    return {
      ..._info(),
      "appVersion": backup["appVersion"],
      "autoBackup": _backupService.autoExportEnabled,
      "quickActions": [
        for (final action in _quickActionsService?.actions ?? const <QuickAction>[])
          {"id": action.id, "label": action.label, "icon": action.icon},
      ],
      "sync": remoteSync == null
          ? null
          : {
              "url": remoteSync.url,
              "following": remoteSync.followedName,
              "enabled": remoteSync.enabled,
              "syncing": remoteSync.syncing,
              "lastCheck": remoteSync.lastCheck?.toUtc().toIso8601String(),
              "lastError": remoteSync.lastError,
            },
      "layout": {
        "hash": RemoteSyncService.contentHash(
            jsonEncode(Map.of(backup)..remove("exportedAt")..remove("appVersion"))),
        "sections": sections.length,
        "apps": sections.fold<int>(0, (count, section) => count + ((section["apps"] as List?)?.length ?? 0)),
      },
    };
  }

  Future<void> _applySettings(Map<String, dynamic> settings) async {
    if (settings["share"] is bool) {
      await setEnabled(settings["share"] as bool);
    }
    if (settings["autoBackup"] is bool) {
      await _backupService.setAutoExportEnabled(settings["autoBackup"] as bool);
    }
    if (settings.containsKey("follow")) {
      final follow = settings["follow"];
      final remoteSync = _requireRemoteSync();
      if (follow == null) {
        await remoteSync.setUrl("");
      } else if (follow is Map && follow["name"] is String && follow["url"] is String) {
        final url = Uri.tryParse(follow["url"] as String);
        if (url == null || !url.hasScheme) {
          throw const _ApiException(HttpStatus.badRequest, "follow.url is not a valid address");
        }
        await remoteSync.follow(follow["name"] as String, url,
            id: follow["id"] is String ? follow["id"] as String : null);
      } else {
        throw const _ApiException(HttpStatus.badRequest, "follow must be null or {name, url, id}");
      }
    }
    if (settings["autoSync"] is bool) {
      await _requireRemoteSync().setEnabled(settings["autoSync"] as bool);
    }
  }

  /// A new pairing can only start when control is on, no pairing is waiting for its code and pairing
  /// is not blocked after wrong codes - so each code allows at most [maxPairingAttempts] guesses.
  void _checkPairingAllowed() {
    if (!controlEnabled) {
      throw const _ApiException(HttpStatus.forbidden, "Control from other apps is turned off on this device");
    }
    final blockedUntil = _pairingBlockedUntil;
    if (blockedUntil != null && blockedUntil.isAfter(DateTime.now())) {
      throw const _ApiException(HttpStatus.tooManyRequests, "Too many wrong codes, try again later");
    }
    if (pairingRequest != null) {
      throw const _ApiException(HttpStatus.conflict, "A pairing is already waiting for its code");
    }
  }

  (int, String?) _startPairing(Map<String, dynamic> body) {
    _checkPairingAllowed();
    final name = body["client"] is String
        ? String.fromCharCodes((body["client"] as String).runes.where((c) => c >= 0x20 && c != 0x7F)).trim()
        : "";
    final client = name.isEmpty
        ? "Unknown app"
        : name.length > _maxClientNameLength
            ? name.substring(0, _maxClientNameLength)
            : name;
    _pairingRequest = PairingRequest(
      client: client,
      code: List.generate(6, (_) => _random.nextInt(10)).join(),
      expires: DateTime.now().add(pairingTimeout),
    );
    notifyListeners();
    return (HttpStatus.accepted, jsonEncode({"expiresIn": pairingTimeout.inSeconds}));
  }

  Future<(int, String?)> _confirmPairing(Map<String, dynamic> body) async {
    final request = pairingRequest;
    if (!controlEnabled || request == null) {
      throw const _ApiException(HttpStatus.gone, "No pairing in progress");
    }
    if (!_constantTimeEquals("${body["code"]}", request.code)) {
      _failedPairingAttempts++;
      if (_failedPairingAttempts >= maxPairingAttempts) {
        // Each further block lasts twice as long, up to an hour.
        final blockTime = pairingBlockTime * (1 << _pairingBlocks.clamp(0, 4));
        _pairingBlocks++;
        _failedPairingAttempts = 0;
        _pairingRequest = null;
        _pairingBlockedUntil =
            DateTime.now().add(blockTime > _maxPairingBlockTime ? _maxPairingBlockTime : blockTime);
        notifyListeners();
      }
      throw const _ApiException(HttpStatus.unauthorized, "Wrong code");
    }
    final token = base64Url.encode(List.generate(32, (_) => _random.nextInt(256))).replaceAll("=", "");
    await _saveClients([...clients, PairedClient(name: request.client, token: token, created: DateTime.now())]);
    _pairingRequest = null;
    _failedPairingAttempts = 0;
    _pairingBlocks = 0;
    notifyListeners();
    return (HttpStatus.ok, jsonEncode({"token": token, "id": deviceId, "name": _name}));
  }

  void _authorize(HttpRequest request) {
    if (!controlEnabled) {
      throw const _ApiException(HttpStatus.forbidden, "Control from other apps is turned off on this device");
    }
    final header = request.headers.value(HttpHeaders.authorizationHeader) ?? "";
    final token = header.startsWith("Bearer ") ? header.substring(7).trim() : "";
    if (token.isEmpty || !clients.any((client) => _constantTimeEquals(client.token, token))) {
      throw const _ApiException(HttpStatus.unauthorized, "Not paired");
    }
  }

  RemoteSyncService _requireRemoteSync() {
    final remoteSync = _remoteSyncService;
    if (remoteSync == null) {
      throw const _ApiException(HttpStatus.notImplemented, "Sync is not available");
    }
    return remoteSync;
  }

  static Future<Map<String, dynamic>> _readJson(HttpRequest request,
      {bool optional = false, int maxBytes = _maxBodyBytes}) async {
    if (request.contentLength > maxBytes) {
      throw const _ApiException(HttpStatus.requestEntityTooLarge, "Request too large");
    }
    final bytes = BytesBuilder(copy: false);
    try {
      await for (final chunk in request.timeout(_bodyTimeout)) {
        bytes.add(chunk);
        if (bytes.length > maxBytes) {
          throw const _ApiException(HttpStatus.requestEntityTooLarge, "Request too large");
        }
      }
    } on TimeoutException {
      throw const _ApiException(HttpStatus.requestTimeout, "Request body too slow");
    }
    if (bytes.isEmpty && optional) {
      return {};
    }
    try {
      final decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (_) {}
    throw const _ApiException(HttpStatus.badRequest, "Expected a JSON object");
  }

  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) {
      return false;
    }
    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      difference |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return difference == 0;
  }
}

/// Finds devices that share their layout by probing the local /24 networks on [port].
class LayoutDiscovery {
  static const int _maxInfoBytes = 4096;

  final int port;
  final Duration timeout;

  const LayoutDiscovery({this.port = layoutSharePort, this.timeout = const Duration(milliseconds: 800)});

  Future<List<SharedLayoutSource>> scan({List<String>? hosts}) async {
    final candidates = hosts ?? await localNetworkHosts();
    final found = <SharedLayoutSource>[];
    const batchSize = 32;
    for (var start = 0; start < candidates.length; start += batchSize) {
      final batch = candidates.skip(start).take(batchSize);
      for (final source in (await Future.wait(batch.map(probe))).whereType<SharedLayoutSource>()) {
        // A device on two networks (e.g. Ethernet and Wi-Fi) answers on both addresses.
        if (source.id == null || found.every((other) => other.id != source.id)) {
          found.add(source);
        }
      }
    }
    found.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return found;
  }

  /// Looks for the device with this [id], e.g. after its address changed.
  Future<SharedLayoutSource?> find(String id, {List<String>? hosts}) async {
    for (final source in await scan(hosts: hosts)) {
      if (source.id == id) {
        return source;
      }
    }
    return null;
  }

  Future<SharedLayoutSource?> probe(String host) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(Uri(scheme: "http", host: host, port: port, path: layoutShareInfoPath));
      final response = await request.close().timeout(timeout * 2);
      if (response.statusCode != HttpStatus.ok) {
        return null;
      }
      if (response.contentLength > _maxInfoBytes) {
        return null;
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(timeout * 2)) {
        bytes.add(chunk);
        if (bytes.length > _maxInfoBytes) {
          return null;
        }
      }
      final info = jsonDecode(utf8.decode(bytes.takeBytes()));
      if (info is! Map || info["app"] != "arc-launcher" || info["sharing"] != true) {
        return null;
      }
      return SharedLayoutSource(
        name: info["name"] is String ? info["name"] as String : host,
        id: info["id"] is String ? info["id"] as String : null,
        host: host,
        backupUrl: Uri(scheme: "http", host: host, port: port, path: layoutShareBackupPath),
      );
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// All other addresses in the /24 networks of this device's private IPv4 addresses.
  static Future<List<String>> localNetworkHosts() async {
    final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
    final hosts = <String>{};
    final own = <String>{};
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        final parts = address.address.split(".").map(int.parse).toList();
        final private = parts[0] == 10 ||
            (parts[0] == 172 && parts[1] >= 16 && parts[1] <= 31) ||
            (parts[0] == 192 && parts[1] == 168);
        if (!private) {
          continue;
        }
        own.add(address.address);
        for (var i = 1; i < 255; i++) {
          hosts.add("${parts[0]}.${parts[1]}.${parts[2]}.$i");
        }
      }
    }
    return hosts.difference(own).toList();
  }
}
