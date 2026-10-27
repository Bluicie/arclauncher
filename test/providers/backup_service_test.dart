import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:flauncher/database.dart';
import 'package:flauncher/models/category.dart';
import 'package:flauncher/providers/backup_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

Future<void> _installApps(FLauncherDatabase database, List<String> packageNames) => database.persistApps([
      for (final packageName in packageNames)
        AppsCompanion.insert(packageName: packageName, name: packageName, version: "1.0.0"),
    ]);

Future<void> _addCategory(FLauncherDatabase database, String name, int order, List<String> apps,
    {CategoryType type = CategoryType.row}) async {
  final id = await database.insertCategory(
      CategoriesCompanion.insert(name: name, order: order, type: Value(type), rowHeight: const Value(150)));
  await database.insertAppsCategories([
    for (var i = 0; i < apps.length; i++)
      AppsCategoriesCompanion.insert(categoryId: id, appPackageName: apps[i], order: i),
  ]);
}

void main() {
  late FLauncherDatabase database;
  late SharedPreferences sharedPreferences;
  late Directory directory;
  late int restoredCalls;
  late BackupService backupService;

  setUp(() async {
    SharedPreferencesStorePlatform.instance = InMemorySharedPreferencesStore.empty();
    sharedPreferences = await SharedPreferences.getInstance();
    await sharedPreferences.clear();
    database = FLauncherDatabase.inMemory();
    directory = await Directory.systemTemp.createTemp("backup_service_test");
    restoredCalls = 0;
    backupService = BackupService(
      database,
      sharedPreferences,
      backupDirectoryProvider: () async => directory,
      onRestored: () async => restoredCalls++,
    );
  });

  tearDown(() async {
    backupService.dispose();
    await database.close();
    await directory.delete(recursive: true);
  });

  test("createBackup exports sections in order, hidden apps and settings without secrets", () async {
    await _installApps(database, ["app.a", "app.b", "app.c"]);
    await _addCategory(database, "Favorites", 0, ["app.b", "app.a"]);
    await database.insertSpacer(LauncherSpacersCompanion.insert(height: 40, order: 1));
    await _addCategory(database, "All Apps", 2, ["app.c"], type: CategoryType.grid);
    await database.setHiddenApps({"app.c"});
    await sharedPreferences.setBool("show_category_titles", true);
    await sharedPreferences.setString("accent_color", "00BFA5");
    await sharedPreferences.setDouble("focus_border_thickness", 2.0);
    await sharedPreferences.setStringList("reddit_subreddits", ["EarthPorn"]);
    await sharedPreferences.setString("unsplash_access_key", "secret");
    await sharedPreferences.setInt("brightness_day", 80);

    final backup = await backupService.createBackup();

    expect(backup["format"], BackupService.format);
    expect(backup["version"], BackupService.formatVersion);
    final sections = backup["sections"] as List;
    expect(sections.map((s) => s["kind"]), ["category", "spacer", "category"]);
    expect(sections[0]["name"], "Favorites");
    expect(sections[0]["apps"], ["app.b", "app.a"]);
    expect(sections[0]["type"], "row");
    expect(sections[0]["rowHeight"], 150);
    expect(sections[1]["height"], 40);
    expect(sections[2]["type"], "grid");
    expect(backup["hiddenApps"], ["app.c"]);
    expect(backup["settings"], {
      "accent_color": "00BFA5",
      "focus_border_thickness": 2.0,
      "reddit_subreddits": ["EarthPorn"],
      "show_category_titles": true,
    });
  });

  test("applyBackup replaces layout and settings, skipping apps that are not installed", () async {
    await _installApps(database, ["app.a", "app.b"]);
    await _addCategory(database, "Old", 0, ["app.a"]);
    await sharedPreferences.setBool("show_category_titles", true);
    await sharedPreferences.setString("unsplash_access_key", "keep-me");

    final json = jsonEncode({
      "format": BackupService.format,
      "version": 1,
      "sections": [
        {"kind": "category", "order": 0, "name": "Favorites", "sort": "manual", "type": "row", "rowHeight": 120,
          "columnsCount": 6, "apps": ["app.b", "app.missing", "app.a"]},
        {"kind": "spacer", "order": 1, "height": 30},
      ],
      "hiddenApps": ["app.a"],
      "settings": {"accent_color": "2979FF", "focus_border_thickness": 3.0, "unsplash_access_key": "ignored"},
    });

    final result = await backupService.importFromJson(json);

    expect(result.categories, 1);
    expect(result.spacers, 1);
    expect(result.placedApps, 2);
    expect(result.missingApps, ["app.missing"]);
    expect(restoredCalls, 1);

    final categories = await database.getCategories();
    expect(categories.map((c) => c.name), ["Favorites"]);
    expect(categories.single.type, CategoryType.row);
    expect(categories.single.rowHeight, 120);
    final appsCategories = (await database.getAppsCategories())..sort((a, b) => a.order.compareTo(b.order));
    expect(appsCategories.map((ac) => ac.appPackageName), ["app.b", "app.a"]);
    expect((await database.getLauncherSpacers()).single.height, 30);
    final apps = {for (final app in await database.getApplications()) app.packageName: app.hidden};
    expect(apps, {"app.a": true, "app.b": false});

    expect(sharedPreferences.getString("accent_color"), "2979FF");
    expect(sharedPreferences.getDouble("focus_border_thickness"), 3.0);
    expect(sharedPreferences.containsKey("show_category_titles"), isFalse);
    expect(sharedPreferences.getString("unsplash_access_key"), "keep-me");
  });

  test("export and import round-trip", () async {
    await _installApps(database, ["app.a", "app.b"]);
    await _addCategory(database, "Favorites", 0, ["app.a", "app.b"]);
    await sharedPreferences.setBool("show_category_titles", true);

    final file = await backupService.exportToFile();
    await database.deleteLayout();
    await sharedPreferences.clear();

    await backupService.importFromFile(file);

    final appsCategories = (await database.getAppsCategories())..sort((a, b) => a.order.compareTo(b.order));
    expect(appsCategories.map((ac) => ac.appPackageName), ["app.a", "app.b"]);
    expect(sharedPreferences.getBool("show_category_titles"), isTrue);
    expect(await backupService.listBackups(), hasLength(1));
  });

  test("autoExport only rewrites the file when something changed", () async {
    await _installApps(database, ["app.a"]);
    await _addCategory(database, "Favorites", 0, ["app.a"]);

    expect(await backupService.autoExport(), isNotNull);
    expect(await backupService.autoExport(), isNull);

    await sharedPreferences.setBool("show_category_titles", true);
    final file = await backupService.autoExport();
    expect(file, isNotNull);
    expect(file!.path.endsWith(BackupService.autoExportFileName), isTrue);
  });

  test("rejects files that are not a backup or from a newer version", () async {
    expect(() => backupService.importFromJson('{"format": "something-else", "version": 1}'),
        throwsA(isA<FormatException>()));
    expect(() => backupService.importFromJson('{"format": "${BackupService.format}", "version": 99}'),
        throwsA(isA<FormatException>()));
    expect(() => backupService.importFromJson('[]'), throwsA(isA<FormatException>()));
  });
}
