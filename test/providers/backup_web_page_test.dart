import 'dart:convert';
import 'dart:io';

import 'package:flauncher/database.dart';
import 'package:flauncher/providers/backup_service.dart';
import 'package:flauncher/providers/layout_share_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

void main() {
  late FLauncherDatabase database;
  late SharedPreferences sharedPreferences;
  late Directory directory;
  late LayoutShareService service;

  Future<(int, HttpHeaders, String)> call(String method, String path,
      {String? body, Map<String, String> headers = const {}}) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(method, Uri.parse("http://127.0.0.1:${service.port}$path"));
      headers.forEach(request.headers.set);
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(body);
      }
      final response = await request.close();
      return (response.statusCode, response.headers, await utf8.decodeStream(response));
    } finally {
      client.close(force: true);
    }
  }

  String uploadedBackup(String name) => jsonEncode({
        "format": BackupService.format,
        "version": 1,
        "sections": [
          {"kind": "category", "order": 0, "name": name, "apps": ["app.a"]},
        ],
      });

  void answerOnTv(bool approve) {
    void listener() {
      if (service.webRestoreRequest != null) {
        service.removeListener(listener);
        service.answerWebRestore(approve);
      }
    }

    service.addListener(listener);
  }

  setUp(() async {
    SharedPreferencesStorePlatform.instance = InMemorySharedPreferencesStore.empty();
    sharedPreferences = await SharedPreferences.getInstance();
    await sharedPreferences.clear();
    directory = await Directory.systemTemp.createTemp("backup_web_page_test");
    database = FLauncherDatabase.inMemory();
    await database.persistApps([AppsCompanion.insert(packageName: "app.a", name: "A", version: "1")]);
    final categoryId = await database.insertCategory(CategoriesCompanion.insert(name: "Favorites", order: 0));
    await database.insertAppsCategories(
        [AppsCategoriesCompanion.insert(categoryId: categoryId, appPackageName: "app.a", order: 0)]);
    final backupService = BackupService(database, sharedPreferences, backupDirectoryProvider: () async => directory);
    service = LayoutShareService(sharedPreferences, backupService, () async => "Woonkamer <TV>", port: 0);
    await service.setWebEnabled(true);
  });

  tearDown(() async {
    service.dispose();
    await database.close();
    await directory.delete(recursive: true);
  });

  test("serves the page and the settings file only while enabled", () async {
    final page = await call("GET", "/");
    expect(page.$1, 200);
    expect(page.$2.contentType?.mimeType, "text/html");
    expect(page.$3, contains("Woonkamer &lt;TV&gt;"));

    final download = await call("GET", "/arc-launcher/web/backup.json");
    expect(download.$1, 200);
    expect(download.$2.value("content-disposition"), contains("arc-launcher-woonkamer-tv-2"));
    expect(jsonDecode(download.$3)["sections"][0]["name"], "Favorites");

    expect((await service.webAddresses()).every((address) => address.startsWith("http://")), isTrue);

    await service.setWebEnabled(false);
    expect(service.running, isFalse);
  });

  test("an upload is restored after it is confirmed on the TV", () async {
    answerOnTv(true);
    final result = await call("POST", "/arc-launcher/web/restore",
        body: uploadedBackup("Kids"), headers: {"origin": "http://127.0.0.1:${service.port}"});

    expect(result.$1, 200);
    expect(jsonDecode(result.$3)["placedApps"], 1);
    expect((await database.getCategories()).single.name, "Kids");
    expect(service.webRestoreRequest, isNull);
  });

  test("an upload cancelled on the TV changes nothing", () async {
    answerOnTv(false);
    final result = await call("POST", "/arc-launcher/web/restore", body: uploadedBackup("Kids"));

    expect(result.$1, 403);
    expect((await database.getCategories()).single.name, "Favorites");
  });

  test("refuses files that are not settings files and uploads from other web pages", () async {
    expect((await call("POST", "/arc-launcher/web/restore", body: '{"hello": 1}')).$1, 400);
    expect(service.webRestoreRequest, isNull);

    final crossSite = await call("POST", "/arc-launcher/web/restore",
        body: uploadedBackup("Evil"), headers: {"origin": "http://evil.example"});
    expect(crossSite.$1, 403);
    expect(service.webRestoreRequest, isNull);
  });
}
