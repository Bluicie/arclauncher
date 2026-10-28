import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

const _enabledKey = "weather_enabled";
const _locationNameKey = "weather_location_name";
const _latitudeKey = "weather_latitude";
const _longitudeKey = "weather_longitude";
const _fahrenheitKey = "weather_fahrenheit";

class WeatherPlace {
  final String name;
  final String? region;
  final double latitude;
  final double longitude;

  const WeatherPlace({required this.name, this.region, required this.latitude, required this.longitude});

  String get label => region == null || region!.isEmpty ? name : "$name, $region";
}

class CurrentWeather {
  final double temperature;

  /// WMO weather interpretation code, see https://open-meteo.com/en/docs.
  final int code;
  final bool isDay;

  const CurrentWeather({required this.temperature, required this.code, required this.isDay});
}

/// Current weather for the status bar, from Open-Meteo (free, no API key).
class WeatherService extends ChangeNotifier {
  static const Duration refreshInterval = Duration(minutes: 30);
  static const Duration timeout = Duration(seconds: 15);

  final SharedPreferences _sharedPreferences;
  final http.Client _client;
  Timer? _timer;
  CurrentWeather? _current;

  WeatherService(this._sharedPreferences, {http.Client? client, bool schedule = true})
      : _client = client ?? http.Client() {
    if (schedule) {
      _reschedule();
    }
  }

  bool get enabled => _sharedPreferences.getBool(_enabledKey) ?? false;

  bool get fahrenheit => _sharedPreferences.getBool(_fahrenheitKey) ?? false;

  String? get locationName => _sharedPreferences.getString(_locationNameKey);

  bool get hasLocation =>
      _sharedPreferences.containsKey(_latitudeKey) && _sharedPreferences.containsKey(_longitudeKey);

  /// The last fetched weather, `null` until the first successful refresh.
  CurrentWeather? get current => enabled ? _current : null;

  Future<void> setEnabled(bool value) async {
    await _sharedPreferences.setBool(_enabledKey, value);
    _reschedule();
    notifyListeners();
  }

  Future<void> setFahrenheit(bool value) async {
    await _sharedPreferences.setBool(_fahrenheitKey, value);
    notifyListeners();
    await refresh();
  }

  Future<void> setLocation(WeatherPlace place) async {
    await _sharedPreferences.setString(_locationNameKey, place.label);
    await _sharedPreferences.setDouble(_latitudeKey, place.latitude);
    await _sharedPreferences.setDouble(_longitudeKey, place.longitude);
    _current = null;
    _reschedule();
    notifyListeners();
  }

  void _reschedule() {
    _timer?.cancel();
    _timer = null;
    if (!enabled || !hasLocation) {
      return;
    }
    refresh();
    _timer = Timer.periodic(refreshInterval, (_) => refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _client.close();
    super.dispose();
  }

  /// Fetches the current weather; keeps the previous value when that fails.
  Future<void> refresh() async {
    if (!enabled || !hasLocation) {
      return;
    }
    final uri = Uri.https("api.open-meteo.com", "/v1/forecast", {
      "latitude": "${_sharedPreferences.getDouble(_latitudeKey)}",
      "longitude": "${_sharedPreferences.getDouble(_longitudeKey)}",
      "current": "temperature_2m,weather_code,is_day",
      if (fahrenheit) "temperature_unit": "fahrenheit",
    });
    try {
      final response = await _client.get(uri).timeout(timeout);
      if (response.statusCode != 200) {
        return;
      }
      final current = (jsonDecode(response.body) as Map<String, dynamic>)["current"] as Map<String, dynamic>;
      _current = CurrentWeather(
        temperature: (current["temperature_2m"] as num).toDouble(),
        code: (current["weather_code"] as num).toInt(),
        isDay: current["is_day"] != 0,
      );
      notifyListeners();
    } catch (_) {
      // Offline or unexpected answer: keep showing the last known weather.
    }
  }

  /// Looks up places by name with the Open-Meteo geocoding API.
  Future<List<WeatherPlace>> search(String name, {String language = "en"}) async {
    if (name.trim().length < 2) {
      return const [];
    }
    final uri = Uri.https("geocoding-api.open-meteo.com", "/v1/search",
        {"name": name.trim(), "count": "8", "language": language, "format": "json"});
    final response = await _client.get(uri).timeout(timeout);
    if (response.statusCode != 200) {
      throw http.ClientException("HTTP ${response.statusCode}", uri);
    }
    final results = (jsonDecode(response.body) as Map<String, dynamic>)["results"] as List? ?? const [];
    return [
      for (final result in results.whereType<Map<String, dynamic>>())
        WeatherPlace(
          name: result["name"] as String,
          region: [result["admin1"], result["country"]].whereType<String>().join(", "),
          latitude: (result["latitude"] as num).toDouble(),
          longitude: (result["longitude"] as num).toDouble(),
        ),
    ];
  }
}
