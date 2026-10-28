import 'dart:convert';
import 'dart:io';

import 'package:flauncher/database.dart';
import 'package:flauncher/providers/backup_service.dart';
import 'package:flauncher/providers/layout_share_service.dart';
import 'package:flauncher/providers/quick_actions_service.dart';
import 'package:flauncher/widgets/quick_actions_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

const _webhook = "http://192.168.1.10:8123/api/webhook/abc";

void main() {
  late SharedPreferences sharedPreferences;
  late List<http.Request> sent;
  late int webhookStatus;
  late QuickActionsService service;

  setUp(() async {
    SharedPreferencesStorePlatform.instance = InMemorySharedPreferencesStore.empty();
    sharedPreferences = await SharedPreferences.getInstance();
    await sharedPreferences.clear();
    sent = [];
    webhookStatus = 200;
    service = QuickActionsService(
      sharedPreferences,
      deviceId: () => "device-1",
      deviceName: () async => "Slaapkamer TV",
      client: MockClient((request) async {
        sent.add(request);
        return http.Response("", webhookStatus);
      }),
    );
  });

  test("stores valid actions and calls the web address with device and payload when pressed", () async {
    final count = await service.setActionsFromJson([
      {"id": "movie_night", "label": "Movie night", "icon": "mdi:movie", "url": _webhook, "payload": {"scene": "x"}},
      {"id": "off", "label": "Lights off", "url": _webhook},
    ]);
    expect(count, 2);
    expect(service.actions.map((a) => a.icon), ["movie", "gesture-tap"]);

    expect(await service.trigger(service.actions.first), isTrue);
    expect(sent.single.url.toString(), _webhook);
    expect(sent.single.headers["Content-Type"], startsWith("application/json"));
    expect(jsonDecode(sent.single.body),
        {"scene": "x", "action": "movie_night", "device": "device-1", "name": "Slaapkamer TV"});

    webhookStatus = 404;
    expect(await service.trigger(service.actions.first), isFalse);

    await service.clear();
    expect(service.actions, isEmpty);
  });

  test("rejects invalid action lists", () async {
    Future<void> invalid(Object? json) =>
        expectLater(service.setActionsFromJson(json), throwsA(isA<FormatException>()));

    await invalid("nope");
    await invalid([for (var i = 0; i < 7; i++) {"id": "a$i", "label": "A", "url": _webhook}]);
    await invalid([{"id": "Bad Id", "label": "A", "url": _webhook}]);
    await invalid([{"id": "a", "label": "x" * 25, "url": _webhook}]);
    await invalid([{"id": "a", "label": "A", "url": "file:///etc/passwd"}]);
    await invalid([{"id": "a", "label": "A", "url": _webhook, "payload": {"x": "y" * 5000}}]);
    await invalid([
      {"id": "a", "label": "A", "url": _webhook},
      {"id": "a", "label": "B", "url": _webhook},
    ]);
    expect(service.actions, isEmpty);
  });

  test("icons fall back to a generic one", () {
    expect(QuickActionsBar.iconFor("bed"), Icons.bed_outlined);
    expect(QuickActionsBar.iconFor("unknown"), Icons.touch_app_outlined);
  });

  test("a paired app sets quick actions through the control API", () async {
    final directory = await Directory.systemTemp.createTemp("quick_actions_api_test");
    final database = FLauncherDatabase.inMemory();
    final shareService = LayoutShareService(
      sharedPreferences,
      BackupService(database, sharedPreferences, backupDirectoryProvider: () async => directory),
      () async => "Slaapkamer TV",
      quickActionsService: service,
      port: 0,
    );
    final client = HttpClient();
    try {
      await shareService.setControlEnabled(true);
      Future<(int, dynamic)> call(String method, String path, {Object? body, String? token}) async {
        final request = await client.openUrl(method, Uri.parse("http://127.0.0.1:${shareService.port}$path"));
        if (token != null) {
          request.headers.set(HttpHeaders.authorizationHeader, "Bearer $token");
        }
        if (body != null) {
          request.headers.contentType = ContentType.json;
          request.write(jsonEncode(body));
        }
        final response = await request.close();
        final text = await utf8.decodeStream(response);
        return (response.statusCode, text.isEmpty ? null : jsonDecode(text));
      }

      await call("POST", "/arc-launcher/v1/pair", body: {"client": "Home Assistant"});
      final token = (await call("POST", "/arc-launcher/v1/pair/confirm",
          body: {"code": shareService.pairingRequest!.code})).$2["token"] as String;

      final actions = {
        "actions": [
          {"id": "bed", "label": "Goodnight", "icon": "bed", "url": _webhook}
        ]
      };
      expect((await call("PUT", "/arc-launcher/v1/quick-actions", body: actions)).$1, 401);
      final result = await call("PUT", "/arc-launcher/v1/quick-actions", body: actions, token: token);
      expect(result.$1, 200);
      expect(result.$2["quickActions"], 1);
      expect(service.actions.single.label, "Goodnight");

      final status = await call("GET", "/arc-launcher/v1/status", token: token);
      expect(status.$2["quickActions"], [
        {"id": "bed", "label": "Goodnight", "icon": "bed"}
      ]);
      expect((await call("PUT", "/arc-launcher/v1/quick-actions", body: {"actions": 1}, token: token)).$1, 400);
    } finally {
      client.close(force: true);
      shareService.dispose();
      await database.close();
      await directory.delete(recursive: true);
    }
  });
}
