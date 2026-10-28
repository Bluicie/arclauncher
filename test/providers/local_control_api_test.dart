import 'dart:convert';
import 'dart:io';

import 'package:flauncher/database.dart';
import 'package:flauncher/providers/backup_service.dart';
import 'package:flauncher/providers/layout_share_service.dart';
import 'package:flauncher/providers/remote_sync_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

void main() {
  late FLauncherDatabase database;
  late SharedPreferences sharedPreferences;
  late Directory directory;
  late BackupService backupService;
  late RemoteSyncService remoteSyncService;
  late LayoutShareService service;
  late List<Map<String, String>> announcements;
  late int withdrawn;

  Future<(int, dynamic)> call(String method, String path, {Object? body, String? token}) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(method, Uri.parse("http://127.0.0.1:${service.port}$path"));
      if (token != null) {
        request.headers.set(HttpHeaders.authorizationHeader, "Bearer $token");
      }
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(body is String ? body : jsonEncode(body));
      }
      final response = await request.close();
      final text = await utf8.decodeStream(response);
      return (response.statusCode, text.isEmpty ? null : jsonDecode(text));
    } finally {
      client.close(force: true);
    }
  }

  Future<String> pair() async {
    expect((await call("POST", "/arc-launcher/v1/pair", body: {"client": "Home Assistant"})).$1, 202);
    final result = await call("POST", "/arc-launcher/v1/pair/confirm", body: {"code": service.pairingRequest!.code});
    expect(result.$1, 200);
    return result.$2["token"] as String;
  }

  setUp(() async {
    SharedPreferencesStorePlatform.instance = InMemorySharedPreferencesStore.empty();
    sharedPreferences = await SharedPreferences.getInstance();
    await sharedPreferences.clear();
    directory = await Directory.systemTemp.createTemp("local_control_api_test");
    database = FLauncherDatabase.inMemory();
    await database.persistApps([AppsCompanion.insert(packageName: "app.a", name: "A", version: "1")]);
    final categoryId = await database.insertCategory(CategoriesCompanion.insert(name: "Favorites", order: 0));
    await database.insertAppsCategories(
        [AppsCategoriesCompanion.insert(categoryId: categoryId, appPackageName: "app.a", order: 0)]);
    backupService = BackupService(database, sharedPreferences, backupDirectoryProvider: () async => directory);
    remoteSyncService = RemoteSyncService(sharedPreferences, backupService, schedule: false);
    announcements = [];
    withdrawn = 0;
    service = LayoutShareService(
      sharedPreferences,
      backupService,
      () async => "Woonkamer TV",
      remoteSyncService: remoteSyncService,
      advertise: (name, port, attributes) async => announcements.add({"name": name, ...attributes}),
      stopAdvertising: () async => withdrawn++,
      port: 0,
    );
  });

  tearDown(() async {
    service.dispose();
    remoteSyncService.dispose();
    await database.close();
    await directory.delete(recursive: true);
  });

  test("pairing and control are refused while control is turned off", () async {
    await service.setEnabled(true);

    expect((await call("GET", "/arc-launcher/v1/info")).$2["control"], isFalse);
    expect((await call("POST", "/arc-launcher/v1/pair", body: {"client": "x"})).$1, 403);
    expect((await call("GET", "/arc-launcher/v1/status")).$1, 403);
  });

  test("announces the service with its id and enabled features, and withdraws it when stopped", () async {
    await service.setControlEnabled(true);

    expect(announcements.last["name"], "Woonkamer TV");
    expect(announcements.last["id"], service.deviceId);
    expect(announcements.last["control"], "1");
    expect(announcements.last["share"], "0");

    await service.setEnabled(true);
    expect(announcements.last["share"], "1");

    await service.setControlEnabled(false);
    expect(service.running, isTrue); // still sharing
    await service.setEnabled(false);
    expect(service.running, isFalse);
    expect(withdrawn, 1);
  });

  test("pairing with the code shown on screen gives a token for the control endpoints", () async {
    await service.setControlEnabled(true);

    final started = await call("POST", "/arc-launcher/v1/pair", body: {"client": "Home Assistant"});
    expect(started.$1, 202);
    expect(service.pairingRequest?.client, "Home Assistant");
    expect(service.pairingRequest?.code, hasLength(6));

    expect((await call("POST", "/arc-launcher/v1/pair/confirm", body: {"code": "nope"})).$1, 401);
    final confirmed = await call("POST", "/arc-launcher/v1/pair/confirm", body: {"code": service.pairingRequest!.code});
    expect(confirmed.$1, 200);
    expect(confirmed.$2["id"], service.deviceId);
    expect(service.pairingRequest, isNull);
    expect(service.clients.single.name, "Home Assistant");

    final token = confirmed.$2["token"] as String;
    expect((await call("GET", "/arc-launcher/v1/status")).$1, 401);
    expect((await call("GET", "/arc-launcher/v1/status", token: "wrong")).$1, 401);
    final status = await call("GET", "/arc-launcher/v1/status", token: token);
    expect(status.$1, 200);
    expect(status.$2["name"], "Woonkamer TV");
    expect(status.$2["layout"]["sections"], 1);
    expect(status.$2["layout"]["apps"], 1);
    expect(status.$2["sync"]["enabled"], isFalse);

    await service.removeClient(token);
    expect((await call("GET", "/arc-launcher/v1/status", token: token)).$1, 401);
  });

  test("too many wrong codes block pairing for a while", () async {
    await service.setControlEnabled(true);
    await call("POST", "/arc-launcher/v1/pair", body: {"client": "x"});

    for (var i = 0; i < LayoutShareService.maxPairingAttempts; i++) {
      expect((await call("POST", "/arc-launcher/v1/pair/confirm", body: {"code": "000000x"})).$1, 401);
    }
    expect(service.pairingRequest, isNull);
    expect((await call("POST", "/arc-launcher/v1/pair", body: {"client": "x"})).$1, 429);
  });

  test("a new pairing cannot replace one that is waiting, so codes cannot be cycled", () async {
    await service.setControlEnabled(true);
    expect((await call("POST", "/arc-launcher/v1/pair", body: {"client": "x"})).$1, 202);
    for (var i = 0; i < LayoutShareService.maxPairingAttempts - 1; i++) {
      expect((await call("POST", "/arc-launcher/v1/pair/confirm", body: {"code": "000000x"})).$1, 401);
    }
    expect((await call("POST", "/arc-launcher/v1/pair", body: {"client": "x"})).$1, 409);
    expect((await call("POST", "/arc-launcher/v1/pair/confirm", body: {"code": "000000x"})).$1, 401);
    expect((await call("POST", "/arc-launcher/v1/pair", body: {"client": "x"})).$1, 429);
  });

  test("long or odd client names are shortened, and turning control off unpairs everything", () async {
    await service.setControlEnabled(true);
    await call("POST", "/arc-launcher/v1/pair", body: {"client": "Home\nAssistant ${"x" * 500}"});
    expect(service.pairingRequest!.client, hasLength(40));
    expect(service.pairingRequest!.client.contains("\n"), isFalse);
    await call("POST", "/arc-launcher/v1/pair/confirm", body: {"code": service.pairingRequest!.code});
    expect(service.clients, hasLength(1));

    await service.setControlEnabled(false);
    await service.setControlEnabled(true);
    expect(service.clients, isEmpty);
  });

  test("refuses requests from web pages and unknown host names", () async {
    await service.setControlEnabled(true);
    final client = HttpClient();
    try {
      Future<int> status(void Function(HttpHeaders headers) setHeaders) async {
        final request = await client.getUrl(Uri.parse("http://127.0.0.1:${service.port}/arc-launcher/v1/info"));
        setHeaders(request.headers);
        final response = await request.close();
        await response.drain<void>();
        return response.statusCode;
      }

      expect(await status((_) {}), 200);
      expect(await status((headers) => headers.set("origin", "http://evil.example")), 403);
      expect(await status((headers) => headers.host = "evil.example"), 403);
      expect(await status((headers) => headers.host = "woonkamer-tv.local"), 200);
    } finally {
      client.close(force: true);
    }
  });

  test("settings, backup and restore endpoints", () async {
    await service.setControlEnabled(true);
    final token = await pair();
    await sharedPreferences.setString("accent_color", "00BFA5");

    expect((await call("GET", "/arc-launcher/v1/backup")).$1, 401); // not shared, not paired
    expect((await call("GET", "/arc-launcher/v1/backup", token: token)).$2["format"], BackupService.format);

    final updated = await call("PUT", "/arc-launcher/v1/settings", token: token, body: {"share": true, "autoBackup": true});
    expect(updated.$1, 200);
    expect(service.enabled, isTrue);
    expect(backupService.autoExportEnabled, isTrue);
    expect(updated.$2["sharing"], isTrue);
    expect((await call("GET", "/arc-launcher/v1/backup")).$1, 200); // shared now

    expect((await call("PUT", "/arc-launcher/v1/settings", token: token, body: {"follow": 3})).$1, 400);
    expect((await call("PUT", "/arc-launcher/v1/settings", token: token, body: {"follow": null})).$1, 200);
    expect(remoteSyncService.url, isEmpty);

    final exported = await call("POST", "/arc-launcher/v1/backup", token: token);
    expect(exported.$1, 200);
    expect(File("${directory.path}/${exported.$2["file"]}").existsSync(), isTrue);

    final restored = await call("POST", "/arc-launcher/v1/restore", token: token, body: {
      "format": BackupService.format,
      "version": 1,
      "sections": [
        {"kind": "category", "order": 0, "name": "Kids", "apps": ["app.a", "app.other"]},
      ],
    });
    expect(restored.$1, 200);
    expect(restored.$2["placedApps"], 1);
    expect(restored.$2["missingApps"], ["app.other"]);
    expect((await database.getCategories()).single.name, "Kids");
    expect(sharedPreferences.getString("accent_color"), "00BFA5"); // layout-only restore keeps settings

    expect((await call("POST", "/arc-launcher/v1/restore", token: token, body: {"format": "other"})).$1, 400);
    expect((await call("POST", "/arc-launcher/v1/restore", token: token, body: "not json")).$1, 400);
    expect((await call("GET", "/arc-launcher/v1/nothing", token: token)).$1, 404);
  });

  test("sync endpoint reports the result", () async {
    await service.setControlEnabled(true);
    final token = await pair();

    final result = await call("POST", "/arc-launcher/v1/sync", token: token);
    expect(result.$1, 200);
    expect(result.$2["restored"], isFalse); // no address configured
  });
}
