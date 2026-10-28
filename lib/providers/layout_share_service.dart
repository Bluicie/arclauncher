import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flauncher/providers/backup_service.dart';
import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:shared_preferences/shared_preferences.dart';

// "backup_" prefix: device-specific, never exported by BackupService.
const _shareEnabledKey = "backup_share_enabled";
const _deviceIdKey = "backup_device_id";

const int layoutSharePort = 47474;
const String layoutShareInfoPath = "/arc-launcher/v1/info";
const String layoutShareBackupPath = "/arc-launcher/v1/backup";

/// A device on the local network that shares its layout.
class SharedLayoutSource {
  final String name;

  /// Stable id of the device, `null` for devices that do not report one.
  final String? id;
  final String host;
  final Uri backupUrl;

  const SharedLayoutSource({required this.name, this.id, required this.host, required this.backupUrl});
}

/// Shares this device's current layout and settings on the local network, so other devices
/// can follow it with [RemoteSyncService]. Only serves read-only data (the same as an exported backup).
class LayoutShareService extends ChangeNotifier {
  final SharedPreferences _sharedPreferences;
  final BackupService _backupService;
  final Future<String> Function() _deviceName;
  final int _port;

  HttpServer? _server;
  String? _name;
  String? _error;

  LayoutShareService(
    this._sharedPreferences,
    this._backupService,
    this._deviceName, {
    int port = layoutSharePort,
    bool start = true,
  }) : _port = port {
    if (start && enabled) {
      startServer();
    }
  }

  bool get enabled => _sharedPreferences.getBool(_shareEnabledKey) ?? false;

  bool get running => _server != null;

  /// The port actually listened on (differs from the requested one when that was 0).
  int? get port => _server?.port;

  /// Name other devices see, available once the server runs.
  String? get name => _name;

  String? get error => _error;

  /// Stable random id of this device, so followers recognise it when its name or address changes.
  String get deviceId {
    var id = _sharedPreferences.getString(_deviceIdKey);
    if (id == null) {
      final random = Random.secure();
      id = List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, "0")).join();
      _sharedPreferences.setString(_deviceIdKey, id);
    }
    return id;
  }

  Future<void> setEnabled(bool value) async {
    await _sharedPreferences.setBool(_shareEnabledKey, value);
    if (value) {
      await startServer();
    } else {
      await stopServer();
    }
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
    await server?.close(force: true);
    notifyListeners();
  }

  @override
  void dispose() {
    _server?.close(force: true);
    super.dispose();
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      if (request.method != "GET") {
        response.statusCode = HttpStatus.methodNotAllowed;
      } else if (request.uri.path == layoutShareInfoPath) {
        _writeJson(response, jsonEncode({"app": "arc-launcher", "name": _name, "id": deviceId, "sharing": true}));
      } else if (request.uri.path == layoutShareBackupPath) {
        _writeJson(response, BackupService.encode(await _backupService.createBackup()));
      } else {
        response.statusCode = HttpStatus.notFound;
      }
    } catch (e) {
      response.statusCode = HttpStatus.internalServerError;
    }
    await response.close();
  }

  static void _writeJson(HttpResponse response, String json) {
    response.headers.contentType = ContentType.json;
    response.write(json);
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
