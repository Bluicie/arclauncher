import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flauncher/database.dart';
import 'package:flauncher/models/category.dart';
import 'package:flutter/foundation.dart' show ChangeNotifier, Listenable;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _autoExportEnabledKey = "backup_auto_export_enabled";

class BackupImportResult {
  final int categories;
  final int spacers;
  final int settings;
  final int placedApps;
  final List<String> missingApps;

  const BackupImportResult({
    required this.categories,
    required this.spacers,
    required this.settings,
    required this.placedApps,
    required this.missingApps,
  });
}

/// Exports and imports the launcher layout (sections, apps per section, hidden apps)
/// and settings as a plain JSON file, so a setup can be backed up or copied to another device.
class BackupService extends ChangeNotifier {
  static const String format = "arc-launcher-backup";
  static const int formatVersion = 1;
  static const String autoExportFileName = "arc-launcher-backup.json";
  static const Duration autoExportDelay = Duration(seconds: 10);

  /// Settings that are never exported: credentials, transient state and
  /// device-specific values (e.g. screen brightness).
  static const Set<String> excludedSettings = {
    "unsplash_access_key",
    "unsplash_author",
    "reddit_client_id",
    "reddit_client_secret",
  };
  static const List<String> excludedSettingPrefixes = [
    "backup_",
    "brightness_",
    "reddit_current_",
  ];

  final FLauncherDatabase _database;
  final SharedPreferences _sharedPreferences;
  final Future<Directory> Function() _backupDirectoryProvider;
  final Future<void> Function()? _onRestored;

  Timer? _autoExportTimer;
  String? _lastAutoExportContent;
  bool _restoring = false;

  BackupService(
    this._database,
    this._sharedPreferences, {
    Future<Directory> Function()? backupDirectoryProvider,
    Future<void> Function()? onRestored,
  })  : _backupDirectoryProvider = backupDirectoryProvider ?? defaultBackupDirectory,
        _onRestored = onRestored;

  /// App-specific external storage (no permission needed, reachable with adb),
  /// falling back to the documents directory.
  static Future<Directory> defaultBackupDirectory() async {
    Directory? base;
    try {
      base = await getExternalStorageDirectory();
    } catch (_) {}
    base ??= await getApplicationDocumentsDirectory();
    return Directory(path.join(base.path, "backups"));
  }

  Future<Directory> backupDirectory() async {
    final directory = await _backupDirectoryProvider();
    await directory.create(recursive: true);
    return directory;
  }

  bool get autoExportEnabled => _sharedPreferences.getBool(_autoExportEnabledKey) ?? false;

  Future<void> setAutoExportEnabled(bool value) async {
    await _sharedPreferences.setBool(_autoExportEnabledKey, value);
    notifyListeners();
    if (value) {
      await autoExport();
    }
  }

  /// Schedules a (debounced) auto-export whenever [listenable] changes.
  void watchForChanges(Listenable listenable) => listenable.addListener(_scheduleAutoExport);

  void _scheduleAutoExport() {
    if (!autoExportEnabled || _restoring) {
      return;
    }
    _autoExportTimer?.cancel();
    _autoExportTimer = Timer(autoExportDelay, () => autoExport());
  }

  @override
  void dispose() {
    _autoExportTimer?.cancel();
    super.dispose();
  }

  static bool isExportedSetting(String key) =>
      !excludedSettings.contains(key) && !excludedSettingPrefixes.any((prefix) => key.startsWith(prefix));

  Future<Map<String, dynamic>> createBackup() async {
    String? appVersion;
    try {
      appVersion = (await PackageInfo.fromPlatform()).version;
    } catch (_) {}

    final categories = await _database.getCategories();
    final spacers = await _database.getLauncherSpacers();
    final appsCategories = await _database.getAppsCategories();
    final apps = await _database.getApplications();

    final appsByCategory = <int, List<AppCategory>>{};
    for (final appCategory in appsCategories) {
      appsByCategory.putIfAbsent(appCategory.categoryId, () => []).add(appCategory);
    }

    final sections = <Map<String, dynamic>>[
      for (final category in categories)
        {
          "kind": "category",
          "order": category.order,
          "name": category.name,
          "sort": category.sort.name,
          "type": category.type.name,
          "rowHeight": category.rowHeight,
          "columnsCount": category.columnsCount,
          "apps": ((appsByCategory[category.id] ?? [])..sort((a, b) => a.order.compareTo(b.order)))
              .map((appCategory) => appCategory.appPackageName)
              .toList(),
        },
      for (final spacer in spacers) {"kind": "spacer", "order": spacer.order, "height": spacer.height},
    ]..sort((a, b) => (a["order"] as int).compareTo(b["order"] as int));

    final settings = <String, dynamic>{};
    final keys = _sharedPreferences.getKeys().where(isExportedSetting).toList()..sort();
    for (final key in keys) {
      settings[key] = _sharedPreferences.get(key);
    }

    return {
      "format": format,
      "version": formatVersion,
      "exportedAt": DateTime.now().toUtc().toIso8601String(),
      if (appVersion != null) "appVersion": appVersion,
      "sections": sections,
      "hiddenApps": (apps.where((app) => app.hidden).map((app) => app.packageName).toList()..sort()),
      "settings": settings,
    };
  }

  static String encode(Map<String, dynamic> backup) => const JsonEncoder.withIndent("  ").convert(backup);

  /// Writes a timestamped backup file and returns it.
  Future<File> exportToFile() async {
    final backup = await createBackup();
    final stamp = DateTime.now().toIso8601String().replaceAll(RegExp(r"[:.]"), "-").substring(0, 19);
    final file = File(path.join((await backupDirectory()).path, "arc-launcher-backup-$stamp.json"));
    await file.writeAsString(encode(backup));
    return file;
  }

  /// Writes [autoExportFileName] when the layout or settings changed since the last export.
  /// Returns the file when it was (re)written.
  Future<File?> autoExport() async {
    final backup = await createBackup();
    final content = _contentWithoutTimestamp(backup);
    final file = File(path.join((await backupDirectory()).path, autoExportFileName));

    if (_lastAutoExportContent == null && await file.exists()) {
      try {
        _lastAutoExportContent = _contentWithoutTimestamp(jsonDecode(await file.readAsString()));
      } catch (_) {}
    }
    if (content == _lastAutoExportContent) {
      return null;
    }

    await file.writeAsString(encode(backup));
    _lastAutoExportContent = content;
    return file;
  }

  static String _contentWithoutTimestamp(Map<String, dynamic> backup) =>
      jsonEncode(Map.of(backup)..remove("exportedAt"));

  /// Backup files in the backup directory, newest first.
  Future<List<File>> listBackups() async {
    final directory = await backupDirectory();
    final files = await directory
        .list()
        .where((entity) => entity is File && entity.path.toLowerCase().endsWith(".json"))
        .cast<File>()
        .toList();
    final modified = {for (final file in files) file.path: await file.lastModified()};
    files.sort((a, b) => modified[b.path]!.compareTo(modified[a.path]!));
    return files;
  }

  Future<BackupImportResult> importFromFile(File file) async => importFromJson(await file.readAsString());

  Future<BackupImportResult> importFromJson(String json) {
    final decoded = jsonDecode(json);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException("Not a launcher backup.");
    }
    return applyBackup(decoded);
  }

  /// Replaces the current layout and settings with [backup].
  /// Apps that are not installed on this device are skipped and reported in the result.
  /// Hidden apps and settings are left alone when the backup has no "hiddenApps" or "settings" entry
  /// (a layout-only backup).
  Future<BackupImportResult> applyBackup(Map<String, dynamic> backup) async {
    if (backup["format"] != format) {
      throw const FormatException("Not a launcher backup.");
    }
    final version = backup["version"];
    if (version is! int || version > formatVersion) {
      throw FormatException("Unsupported backup version: $version");
    }

    final sections = (backup["sections"] as List? ?? const []).whereType<Map>().toList();
    final hiddenApps = (backup["hiddenApps"] as List? ?? const []).whereType<String>().toSet();
    final settings = backup["settings"] is Map ? Map<String, dynamic>.from(backup["settings"]) : <String, dynamic>{};

    _restoring = true;
    try {
      var categoryCount = 0;
      var spacerCount = 0;
      var placedApps = 0;
      final missingApps = <String>{};

      await _database.transaction(() async {
        final installed = (await _database.getApplications()).map((app) => app.packageName).toSet();

        await _database.deleteLayout();

        final appsCategories = <AppsCategoriesCompanion>[];
        for (var index = 0; index < sections.length; index++) {
          final section = sections[index];
          final order = section["order"] is int ? section["order"] as int : index;

          if (section["kind"] == "spacer") {
            await _database.insertSpacer(LauncherSpacersCompanion.insert(
              height: section["height"] is int ? section["height"] as int : 0,
              order: order,
            ));
            spacerCount++;
            continue;
          }

          final name = section["name"];
          if (section["kind"] != "category" || name is! String) {
            continue;
          }
          final categoryId = await _database.insertCategory(CategoriesCompanion.insert(
            name: name,
            order: order,
            sort: Value(CategorySort.values.asNameMap()[section["sort"]] ?? Category.Sort),
            type: Value(CategoryType.values.asNameMap()[section["type"]] ?? Category.Type),
            rowHeight: Value(section["rowHeight"] is int ? section["rowHeight"] as int : Category.RowHeight),
            columnsCount:
                Value(section["columnsCount"] is int ? section["columnsCount"] as int : Category.ColumnsCount),
          ));
          categoryCount++;

          var appOrder = 0;
          for (final packageName in (section["apps"] as List? ?? const []).whereType<String>()) {
            if (!installed.contains(packageName)) {
              missingApps.add(packageName);
              continue;
            }
            appsCategories.add(AppsCategoriesCompanion.insert(
              categoryId: categoryId,
              appPackageName: packageName,
              order: appOrder++,
            ));
          }
        }
        await _database.insertAppsCategories(appsCategories);
        placedApps = appsCategories.length;

        if (backup.containsKey("hiddenApps")) {
          await _database.setHiddenApps(hiddenApps);
        }
      });

      final settingCount = backup.containsKey("settings") ? await _applySettings(settings) : 0;
      await _onRestored?.call();

      return BackupImportResult(
        categories: categoryCount,
        spacers: spacerCount,
        settings: settingCount,
        placedApps: placedApps,
        missingApps: missingApps.toList()..sort(),
      );
    } finally {
      _restoring = false;
    }
  }

  /// Mirrors the exported settings: keys missing from the backup fall back to their defaults.
  Future<int> _applySettings(Map<String, dynamic> settings) async {
    for (final key in _sharedPreferences.getKeys().where(isExportedSetting).toList()) {
      if (!settings.containsKey(key)) {
        await _sharedPreferences.remove(key);
      }
    }

    var applied = 0;
    for (final entry in settings.entries) {
      final key = entry.key;
      final value = entry.value;
      if (!isExportedSetting(key)) {
        continue;
      }
      if (value is bool) {
        await _sharedPreferences.setBool(key, value);
      } else if (value is int) {
        await _sharedPreferences.setInt(key, value);
      } else if (value is double) {
        await _sharedPreferences.setDouble(key, value);
      } else if (value is String) {
        await _sharedPreferences.setString(key, value);
      } else if (value is List && value.every((item) => item is String)) {
        await _sharedPreferences.setStringList(key, value.cast<String>());
      } else {
        continue;
      }
      applied++;
    }
    return applied;
  }
}
