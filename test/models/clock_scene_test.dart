import 'dart:ui';

import 'package:flauncher/models/clock_scene.dart';
import 'package:flauncher/widgets/scene_clock_background.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Amsterdam
  const lat = 52.37;
  const lon = 4.90;

  group("sceneForTime", () {
    test("follows the sun on a summer day", () {
      expect(sceneForTime(DateTime.utc(2026, 6, 21, 0, 30), latitude: lat, longitude: lon), "night");
      expect(sceneForTime(DateTime.utc(2026, 6, 21, 3, 45), latitude: lat, longitude: lon), "dawn");
      expect(sceneForTime(DateTime.utc(2026, 6, 21, 12), latitude: lat, longitude: lon), "water");
      expect(sceneForTime(DateTime.utc(2026, 6, 21, 19, 30), latitude: lat, longitude: lon), "golden");
      expect(sceneForTime(DateTime.utc(2026, 6, 21, 21, 30), latitude: lat, longitude: lon), "night");
    });

    test("winter evenings are night early", () {
      expect(sceneForTime(DateTime.utc(2026, 12, 21, 17), latitude: lat, longitude: lon), "night");
    });

    test("grey weather turns the day scene into fog", () {
      expect(sceneForTime(DateTime.utc(2026, 6, 21, 12), latitude: lat, longitude: lon, weatherCode: 61), "fog");
      expect(sceneForTime(DateTime.utc(2026, 6, 21, 12), latitude: lat, longitude: lon, weatherCode: 1), "water");
      // Weather does not change the night.
      expect(sceneForTime(DateTime.utc(2026, 6, 21, 0, 30), latitude: lat, longitude: lon, weatherCode: 61), "night");
    });

    test("falls back to fixed hours without a place", () {
      expect(sceneForTime(DateTime(2026, 3, 1, 6)), "dawn");
      expect(sceneForTime(DateTime(2026, 3, 1, 12)), "water");
      expect(sceneForTime(DateTime(2026, 3, 1, 18)), "golden");
      expect(sceneForTime(DateTime(2026, 3, 1, 23)), "night");
    });
  });

  test("the pixel island set follows the day, with its afternoon for grey weather", () {
    final island = clockSceneSetById("island");
    expect(sceneForTime(DateTime.utc(2026, 6, 21, 3, 45), latitude: lat, longitude: lon, set: island), "island-dawn");
    expect(sceneForTime(DateTime.utc(2026, 6, 21, 12), latitude: lat, longitude: lon, set: island), "island-day");
    expect(sceneForTime(DateTime.utc(2026, 6, 21, 12), latitude: lat, longitude: lon, weatherCode: 61, set: island),
        "island-day");
    expect(sceneForTime(DateTime.utc(2026, 6, 21, 19, 30), latitude: lat, longitude: lon, set: island), "island-golden");
    expect(sceneForTime(DateTime.utc(2026, 6, 21, 0, 30), latitude: lat, longitude: lon, set: island), "island-night");
    expect(island.sceneIds, ["island-dawn", "island-day", "island-golden", "island-night"]);
    for (final id in island.sceneIds) {
      expect(clockSceneById(id).id, id);
    }
    expect(clockSceneSetById("nope").id, "landscapes");
  });

  test("the adventure set keeps its afternoon world through the evening", () {
    final adventure = clockSceneSetById("adventure");
    expect(sceneForTime(DateTime.utc(2026, 6, 21, 3, 45), latitude: lat, longitude: lon, set: adventure),
        "adventure-backyard");
    expect(sceneForTime(DateTime.utc(2026, 6, 21, 19, 30), latitude: lat, longitude: lon, set: adventure),
        "adventure-platform");
    expect(sceneForTime(DateTime.utc(2026, 6, 21, 0, 30), latitude: lat, longitude: lon, set: adventure),
        "adventure-blocks");
    for (final id in adventure.sceneIds) {
      expect(clockSceneById(id).id, id);
    }
  });

  test("solar noon altitude is about 90 - latitude + declination", () {
    final summer = solarPosition(lat, lon, DateTime.utc(2026, 6, 21, 11, 40));
    expect(summer.altitude, closeTo(90 - lat + 23.45, 1.5));
    final winter = solarPosition(lat, lon, DateTime.utc(2026, 12, 21, 11, 40));
    expect(winter.altitude, closeTo(90 - lat - 23.45, 1.5));
  });

  test("every scene id resolves, unknown ids fall back to the first scene", () {
    for (final scene in clockScenes) {
      expect(clockSceneById(scene.id), same(scene));
    }
    expect(clockSceneById("nope"), same(clockScenes.first));
  });

  group("layoutClock", () {
    const size = Size(1920, 1080);
    final night = clockSceneById("night");

    test("keeps the scene's own place when there is room", () {
      final layout = layoutClock(night, size, 670)!;
      expect(layout.top, closeTo(night.clockTop * 1080, 0.01));
      expect(layout.fontSize, closeTo(night.clockSize * 1080, 0.01));
    });

    test("moves up and shrinks to stay above the content", () {
      final layout = layoutClock(night, size, 300)!;
      expect(layout.top, lessThan(night.clockTop * 1080));
      expect(layout.top + 0.92 * layout.fontSize, lessThanOrEqualTo(300 - 0.02 * 1080 + 0.01));
    });

    test("hides the clock when there is no room", () {
      expect(layoutClock(night, size, 100), isNull);
    });
  });
}
