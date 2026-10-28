import 'dart:convert';

import 'package:flauncher/providers/weather_service.dart';
import 'package:flauncher/widgets/weather_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

void main() {
  late SharedPreferences sharedPreferences;
  late List<Uri> requests;
  late int forecastStatus;

  WeatherService createService() => WeatherService(
        sharedPreferences,
        schedule: false,
        client: MockClient((request) async {
          requests.add(request.url);
          if (request.url.host == "geocoding-api.open-meteo.com") {
            return http.Response(
                jsonEncode({
                  "results": [
                    {"name": "Gent", "admin1": "Flanders", "country": "Belgium", "latitude": 51.05, "longitude": 3.72},
                  ]
                }),
                200);
          }
          return http.Response(
              jsonEncode({
                "current": {"temperature_2m": 12.6, "weather_code": 3, "is_day": 1}
              }),
              forecastStatus);
        }),
      );

  setUp(() async {
    SharedPreferencesStorePlatform.instance = InMemorySharedPreferencesStore.empty();
    sharedPreferences = await SharedPreferences.getInstance();
    await sharedPreferences.clear();
    requests = [];
    forecastStatus = 200;
  });

  test("searches places and loads the current weather for the chosen one", () async {
    final service = createService();

    final places = await service.search("Gent");
    expect(places.single.label, "Gent, Flanders, Belgium");

    await service.setLocation(places.single);
    await service.setEnabled(true);
    await service.refresh();

    expect(service.locationName, "Gent, Flanders, Belgium");
    expect(service.current?.temperature, 12.6);
    expect(service.current?.code, 3);
    expect(requests.last.queryParameters["latitude"], "51.05");
    expect(requests.last.queryParameters.containsKey("temperature_unit"), isFalse);

    await service.setFahrenheit(true);
    expect(requests.last.queryParameters["temperature_unit"], "fahrenheit");
    service.dispose();
  });

  test("shows nothing while off and keeps the last weather when a refresh fails", () async {
    final service = createService();
    await service.setLocation(const WeatherPlace(name: "Gent", latitude: 51.05, longitude: 3.72));
    await service.refresh();
    expect(service.current, isNull); // off
    expect(requests, isEmpty);

    await service.setEnabled(true);
    await service.refresh();
    forecastStatus = 500;
    await service.refresh();
    expect(service.current?.temperature, 12.6);
    service.dispose();
  });

  test("maps weather codes to icons", () {
    expect(WeatherWidget.iconFor(const CurrentWeather(temperature: 1, code: 0, isDay: true)), Icons.wb_sunny_outlined);
    expect(WeatherWidget.iconFor(const CurrentWeather(temperature: 1, code: 0, isDay: false)),
        Icons.nightlight_outlined);
    expect(WeatherWidget.iconFor(const CurrentWeather(temperature: 1, code: 63, isDay: true)),
        Icons.water_drop_outlined);
    expect(WeatherWidget.iconFor(const CurrentWeather(temperature: 1, code: 73, isDay: true)), Icons.ac_unit);
    expect(WeatherWidget.iconFor(const CurrentWeather(temperature: 1, code: 95, isDay: true)), Icons.flash_on);
  });
}
