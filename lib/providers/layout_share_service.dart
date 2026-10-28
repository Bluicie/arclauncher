import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flauncher/providers/backup_service.dart';
import 'package:flauncher/providers/remote_sync_service.dart';
import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

// "backup_" prefix: device-specific, never exported by BackupService.
const _shareEnabledKey = "backup_share_enabled";
const _controlEnabledKey = "backup_control_enabled";
const _clientsKey = "backup_api_clients";
const _deviceIdKey = "backup_device_id";

const int layoutSharePort = 47474;
const int localApiVersion = 1;
const String localApiServiceType = "_arclauncher._tcp";
const String _apiPrefix = "/arc-launcher/v1";
const String layoutShareInfoPath = "$_apiPrefix/info";
const String layoutShareBackupPath = "$_apiPrefix/backup";

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
/// Only `GET /arc-launcher/v1/info` is public; it tells which of the two is enabled.
class LayoutShareService extends ChangeNotifier {
  static const Duration pairingTimeout = Duration(minutes: 2);
  static const int maxPairingAttempts = 5;
  static const Duration pairingBlockTime = Duration(minutes: 5);
  static const int _maxBodyBytes = 4 * 1024 * 1024;

  final SharedPreferences _sharedPreferences;
  final BackupService _backupService;
  final RemoteSyncService? _remoteSyncService;
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
  DateTime? _pairingBlockedUntil;

  LayoutShareService(
    this._sharedPreferences,
    this._backupService,
    this._deviceName, {
    RemoteSyncService? remoteSyncService,
    Future<void> Function(String name, int port, Map<String, String> attributes)? advertise,
    Future<void> Function()? stopAdvertising,
    int port = layoutSharePort,
    bool start = true,
  })  : _remoteSyncService = remoteSyncService,
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
  String get deviceId {
    var id = _sharedPreferences.getString(_deviceIdKey);
    if (id == null) {
      id = List.generate(16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, "0")).join();
      _sharedPreferences.setString(_deviceIdKey, id);
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
      _pairingRequest = null;
    }
    await _updateServer();
  }

  Future<void> removeClient(String token) async {
    await _saveClients(clients.where((client) => client.token != token).toList());
    notifyListeners();
  }

  void cancelPairing() {
    _pairingRequest = null;
    notifyListeners();
  }

  Future<void> _saveClients(List<PairedClient> clients) => _sharedPreferences.setStringList(
      _clientsKey, clients.map((client) => jsonEncode(client.toJson())).toList());

  Future<void> _updateServer() async {
    if (enabled || controlEnabled) {
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
    try {
      final result = await _route(request);
      response.statusCode = result.$1;
      if (result.$2 != null) {
        response.headers.contentType = ContentType.json;
        response.write(result.$2);
      }
    } on _ApiException catch (e) {
      response.statusCode = e.status;
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode({"error": e.message}));
    } catch (e) {
      response.statusCode = HttpStatus.internalServerError;
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode({"error": e.toString()}));
    }
    await response.close();
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
      return _startPairing(await _readJson(request));
    } else if (route == "POST $_apiPrefix/pair/confirm") {
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
        final result = await _backupService.applyBackup(await _readJson(request));
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
        await remoteSync.follow(follow["name"] as String, Uri.parse(follow["url"] as String));
      } else {
        throw const _ApiException(HttpStatus.badRequest, "follow must be null or {name, url}");
      }
    }
    if (settings["autoSync"] is bool) {
      await _requireRemoteSync().setEnabled(settings["autoSync"] as bool);
    }
  }

  (int, String?) _startPairing(Map<String, dynamic> body) {
    if (!controlEnabled) {
      throw const _ApiException(HttpStatus.forbidden, "Control from other apps is turned off on this device");
    }
    final blockedUntil = _pairingBlockedUntil;
    if (blockedUntil != null && blockedUntil.isAfter(DateTime.now())) {
      throw const _ApiException(HttpStatus.tooManyRequests, "Too many wrong codes, try again later");
    }
    final client = body["client"] is String && (body["client"] as String).trim().isNotEmpty
        ? (body["client"] as String).trim()
        : "Unknown app";
    _pairingRequest = PairingRequest(
      client: client,
      code: List.generate(6, (_) => _random.nextInt(10)).join(),
      expires: DateTime.now().add(pairingTimeout),
    );
    _failedPairingAttempts = 0;
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
        _pairingRequest = null;
        _pairingBlockedUntil = DateTime.now().add(pairingBlockTime);
        notifyListeners();
      }
      throw const _ApiException(HttpStatus.unauthorized, "Wrong code");
    }
    final token = base64Url.encode(List.generate(32, (_) => _random.nextInt(256))).replaceAll("=", "");
    await _saveClients([...clients, PairedClient(name: request.client, token: token, created: DateTime.now())]);
    _pairingRequest = null;
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

  static Future<Map<String, dynamic>> _readJson(HttpRequest request, {bool optional = false}) async {
    final bytes = <int>[];
    await for (final chunk in request) {
      bytes.addAll(chunk);
      if (bytes.length > _maxBodyBytes) {
        throw const _ApiException(HttpStatus.requestEntityTooLarge, "Request too large");
      }
    }
    if (bytes.isEmpty && optional) {
      return {};
    }
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
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
