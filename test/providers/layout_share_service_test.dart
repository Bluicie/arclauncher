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
  late FLauncherDatabase leaderDatabase;
  late FLauncherDatabase followerDatabase;
  late SharedPreferences sharedPreferences;
  late Directory directory;
  late BackupService leaderBackup;
  late LayoutShareService shareService;

  setUp(() async {
    SharedPreferencesStorePlatform.instance = InMemorySharedPreferencesStore.empty();
    sharedPreferences = await SharedPreferences.getInstance();
    await sharedPreferences.clear();
    directory = await Directory.systemTemp.createTemp("layout_share_service_test");

    leaderDatabase = FLauncherDatabase.inMemory();
    await leaderDatabase.persistApps([AppsCompanion.insert(packageName: "app.a", name: "A", version: "1")]);
    final categoryId = await leaderDatabase.insertCategory(CategoriesCompanion.insert(name: "Favorites", order: 0));
    await leaderDatabase.insertAppsCategories(
        [AppsCategoriesCompanion.insert(categoryId: categoryId, appPackageName: "app.a", order: 0)]);
    leaderBackup = BackupService(leaderDatabase, sharedPreferences, backupDirectoryProvider: () async => directory);

    followerDatabase = FLauncherDatabase.inMemory();
    await followerDatabase.persistApps([AppsCompanion.insert(packageName: "app.a", name: "A", version: "1")]);

    shareService = LayoutShareService(sharedPreferences, leaderBackup, () async => "Woonkamer TV", port: 0);
  });

  tearDown(() async {
    shareService.dispose();
    await leaderDatabase.close();
    await followerDatabase.close();
    await directory.delete(recursive: true);
  });

  test("serves info and the current backup while enabled", () async {
    expect(shareService.running, isFalse);
    await shareService.setEnabled(true);
    expect(shareService.running, isTrue);
    expect(shareService.name, "Woonkamer TV");

    final source = await LayoutDiscovery(port: shareService.port!).probe("127.0.0.1");
    expect(source, isNotNull);
    expect(source!.name, "Woonkamer TV");
    expect(source.backupUrl.path, layoutShareBackupPath);

    final client = HttpClient();
    final response = await (await client.getUrl(source.backupUrl)).close();
    final backup = jsonDecode(await utf8.decodeStream(response));
    client.close();
    expect(backup["format"], BackupService.format);
    expect((backup["sections"] as List).single["apps"], ["app.a"]);

    await shareService.setEnabled(false);
    expect(shareService.running, isFalse);
    expect(await LayoutDiscovery(port: source.backupUrl.port).probe("127.0.0.1"), isNull);
  });

  test("discovery finds sharing devices once each, by id, and ignores other hosts", () async {
    await shareService.setEnabled(true);
    final discovery = LayoutDiscovery(port: shareService.port!, timeout: const Duration(milliseconds: 300));

    final sources = await discovery.scan(hosts: ["127.0.0.1", "127.0.0.2"]);
    expect(sources.map((s) => s.name), ["Woonkamer TV"]);
    // 127.0.0.1 and 127.0.0.2 both reach the same server: listed once.
    expect(sources.single.id, shareService.deviceId);
    expect((await discovery.find(shareService.deviceId, hosts: ["127.0.0.1"]))?.host, "127.0.0.1");
    expect(await discovery.find("another-id", hosts: ["127.0.0.1"]), isNull);
  });

  test("a follower syncs from the leader and finds it again after its address changed", () async {
    await shareService.setEnabled(true);
    final source = (await LayoutDiscovery(port: shareService.port!).probe("127.0.0.1"))!;
    final followerBackup = BackupService(followerDatabase, sharedPreferences,
        backupDirectoryProvider: () async => directory);
    final remoteSync = RemoteSyncService(
      sharedPreferences,
      followerBackup,
      schedule: false,
      locate: (id) async => id == source.id ? source.backupUrl : null,
    );

    await remoteSync.follow(source.name, source.backupUrl.replace(port: 1), id: source.id);

    expect(remoteSync.lastError, isNull);
    expect(remoteSync.followedName, "Woonkamer TV");
    expect(remoteSync.followedId, shareService.deviceId);
    expect(remoteSync.url, source.backupUrl.toString());
    expect((await followerDatabase.getCategories()).single.name, "Favorites");
    remoteSync.dispose();
  });
}
