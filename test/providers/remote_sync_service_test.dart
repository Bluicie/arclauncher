import 'dart:convert';
import 'dart:io';

import 'package:flauncher/database.dart';
import 'package:flauncher/providers/backup_service.dart';
import 'package:flauncher/providers/remote_sync_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

const _url = "http://192.168.1.10:8123/local/arc-launcher/backup.json";

String _backupJson(String accentColor) => jsonEncode({
      "format": BackupService.format,
      "version": 1,
      "sections": [
        {"kind": "category", "order": 0, "name": "Favorites", "apps": ["app.a"]},
      ],
      "hiddenApps": [],
      "settings": {"accent_color": accentColor},
    });

void main() {
  late FLauncherDatabase database;
  late SharedPreferences sharedPreferences;
  late Directory directory;
  late BackupService backupService;
  late String served;
  late int statusCode;
  late int requests;
  late List<RemoteSyncService> services;

  RemoteSyncService createService() {
    final service = RemoteSyncService(
      sharedPreferences,
      backupService,
      schedule: false,
      client: MockClient((request) async {
        requests++;
        expect(request.url.toString(), _url);
        return http.Response(served, statusCode);
      }),
    );
    services.add(service);
    return service;
  }

  setUp(() async {
    SharedPreferencesStorePlatform.instance = InMemorySharedPreferencesStore.empty();
    sharedPreferences = await SharedPreferences.getInstance();
    await sharedPreferences.clear();
    database = FLauncherDatabase.inMemory();
    await database.persistApps([AppsCompanion.insert(packageName: "app.a", name: "A", version: "1")]);
    directory = await Directory.systemTemp.createTemp("remote_sync_service_test");
    backupService = BackupService(database, sharedPreferences, backupDirectoryProvider: () async => directory);
    served = _backupJson("2979FF");
    statusCode = 200;
    requests = 0;
    services = [];
  });

  tearDown(() async {
    for (final service in services) {
      service.dispose();
    }
    await database.close();
    await directory.delete(recursive: true);
  });

  test("restores the remote backup and keeps its own settings", () async {
    final service = createService();
    await service.setUrl(_url);

    expect(await service.syncNow(), isTrue);

    expect(sharedPreferences.getString("accent_color"), "2979FF");
    expect((await database.getCategories()).single.name, "Favorites");
    expect(service.url, _url);
    expect(service.lastCheck, isNotNull);
    expect(service.lastError, isNull);
    expect(service.lastResult?.placedApps, 1);
  });

  test("only restores again when the remote file changed, unless forced", () async {
    final service = createService();
    await service.setUrl(_url);

    expect(await service.syncNow(), isTrue);
    expect(await service.syncNow(), isFalse);
    expect(await service.syncNow(force: true), isTrue);

    served = _backupJson("FF6D00");
    expect(await service.syncNow(), isTrue);
    expect(sharedPreferences.getString("accent_color"), "FF6D00");
    expect(requests, 4);
  });

  test("keeps the error and the current layout when the download fails", () async {
    final service = createService();
    await service.setUrl(_url);
    statusCode = 404;

    expect(await service.syncNow(), isFalse);

    expect(service.lastError, contains("404"));
    expect(await database.getCategories(), isEmpty);
  });

  test("is only enabled with an address and rejects invalid addresses", () async {
    final service = createService();
    await sharedPreferences.setBool("backup_remote_enabled", true);
    expect(service.enabled, isFalse);

    await service.setUrl(_url);
    expect(service.enabled, isTrue);

    expect(() => service.setUrl("not an address"), throwsA(isA<FormatException>()));
  });

  test("contentHash is stable", () {
    expect(RemoteSyncService.contentHash(""), "811c9dc5");
    expect(RemoteSyncService.contentHash("a"), "e40c292c");
    expect(RemoteSyncService.contentHash("abc"), isNot(RemoteSyncService.contentHash("abd")));
  });
}
