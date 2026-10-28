import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

// "backup_" prefix: quick actions are set up per device and never exported by BackupService.
const _quickActionsKey = "backup_quick_actions";

/// A button in the status bar that calls a web address (e.g. a Home Assistant webhook) when pressed.
class QuickAction {
  static final RegExp _idPattern = RegExp(r"^[a-z0-9_-]{1,40}$");
  static const int maxLabelLength = 24;
  static const int maxPayloadBytes = 4096;

  final String id;
  final String label;
  final String icon;
  final Uri url;
  final Map<String, dynamic> payload;

  const QuickAction({required this.id, required this.label, required this.icon, required this.url, this.payload = const {}});

  Map<String, dynamic> toJson() => {"id": id, "label": label, "icon": icon, "url": url.toString(), "payload": payload};

  /// Validates one action as sent by a client; throws a [FormatException] explaining what is wrong.
  static QuickAction fromJson(Object? json) {
    if (json is! Map) {
      throw const FormatException("Each action must be an object");
    }
    final id = json["id"];
    if (id is! String || !_idPattern.hasMatch(id)) {
      throw const FormatException("id must be 1-40 characters of a-z, 0-9, _ and -");
    }
    final label = json["label"];
    if (label is! String || label.trim().isEmpty || label.trim().length > maxLabelLength) {
      throw FormatException("label of $id must be 1-$maxLabelLength characters");
    }
    final url = json["url"] is String ? Uri.tryParse(json["url"] as String) : null;
    if (url == null || !(url.isScheme("http") || url.isScheme("https")) || url.host.isEmpty) {
      throw FormatException("url of $id must be an http(s) address");
    }
    final payload = json["payload"] ?? const <String, dynamic>{};
    if (payload is! Map<String, dynamic> || utf8.encode(jsonEncode(payload)).length > maxPayloadBytes) {
      throw FormatException("payload of $id must be an object of at most $maxPayloadBytes bytes");
    }
    return QuickAction(
      id: id,
      label: label.trim(),
      icon: json["icon"] is String ? (json["icon"] as String).replaceFirst("mdi:", "") : "gesture-tap",
      url: url,
      payload: payload,
    );
  }
}

/// The quick-action buttons shown in the status bar. They are set by a paired app through the local
/// control API; pressing one POSTs `{"action", "device", "name", ...payload}` to its web address.
class QuickActionsService extends ChangeNotifier {
  static const int maxActions = 6;
  static const Duration timeout = Duration(seconds: 5);

  final SharedPreferences _sharedPreferences;
  final http.Client _client;
  final String Function() _deviceId;
  final Future<String> Function() _deviceName;

  QuickActionsService(this._sharedPreferences,
      {http.Client? client, required String Function() deviceId, required Future<String> Function() deviceName})
      : _client = client ?? http.Client(),
        _deviceId = deviceId,
        _deviceName = deviceName;

  List<QuickAction> get actions {
    try {
      final stored = jsonDecode(_sharedPreferences.getString(_quickActionsKey) ?? "[]") as List;
      return stored.map(QuickAction.fromJson).toList();
    } catch (_) {
      return const [];
    }
  }

  /// Validates and stores [json] (a list of actions); throws a [FormatException] when it is not valid.
  Future<int> setActionsFromJson(Object? json) async {
    if (json is! List || json.length > maxActions) {
      throw const FormatException("actions must be a list of at most $maxActions buttons");
    }
    final actions = json.map(QuickAction.fromJson).toList();
    if (actions.map((action) => action.id).toSet().length != actions.length) {
      throw const FormatException("action ids must be unique");
    }
    await _sharedPreferences.setString(_quickActionsKey, jsonEncode(actions.map((a) => a.toJson()).toList()));
    notifyListeners();
    return actions.length;
  }

  Future<void> clear() async {
    await _sharedPreferences.remove(_quickActionsKey);
    notifyListeners();
  }

  /// Calls the action's address; returns whether it answered with a 2xx status.
  Future<bool> trigger(QuickAction action) async {
    try {
      final body = {...action.payload, "action": action.id, "device": _deviceId(), "name": await _deviceName()};
      final response = await _client
          .post(action.url, headers: {"Content-Type": "application/json"}, body: jsonEncode(body))
          .timeout(timeout);
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }
}
