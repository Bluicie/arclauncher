import 'dart:math' as math;
import 'dart:ui';

/// A layered background with a large glass clock: the photo, the clock, then
/// (optionally) a cut-out of the scenery that is drawn over the clock.
///
/// Positions and sizes are fractions of the screen, designed at 16:9.
class ClockScene {
  final String id;

  /// The photo, an asset path.
  final String image;

  /// The scenery with a transparent sky, drawn over the clock (asset path).
  final String? foreground;

  /// The top of the clock's line box, as a fraction of the screen height.
  final double clockTop;

  /// The clock's font size, as a fraction of the screen height.
  final double clockSize;

  /// Left edge as a fraction of the screen width, or `null` to centre the clock.
  final double? clockLeft;

  /// Where the water starts (fraction of the height): below it the clock is a
  /// blurred reflection.
  final double? waterline;

  /// Brightness of the photo and the cut-out (1 = unchanged).
  final double brightness;

  /// Brightness and opacity of the frosted glass inside the digits.
  final double glassBrightness;
  final double glassOpacity;

  /// Colour of the thin outline around the digits.
  final Color rim;

  /// Whether the digits get a diagonal light sheen.
  final bool sheen;

  const ClockScene({
    required this.id,
    required this.image,
    this.foreground,
    this.clockTop = 0.139,
    this.clockSize = 0.37,
    this.clockLeft,
    this.waterline,
    this.brightness = 1.0,
    this.glassBrightness = 1.0,
    this.glassOpacity = 1.0,
    this.rim = const Color(0x8CFFFFFF),
    this.sheen = true,
  });
}

/// "Follow the day": the scene is picked from the sun's position.
const String autoClockScene = "auto";

/// The built-in scenes. The pictures were made with an AI image model for
/// couch-tv (https://github.com/Seagey/couch-tv, MIT), free to use; see
/// assets/scenes/CREDITS.md.
const List<ClockScene> clockScenes = [
  ClockScene(
    id: "night",
    image: "assets/scenes/scene-night.jpg",
    foreground: "assets/scenes/scene-night-fg.webp",
    brightness: 0.86,
    glassBrightness: 1.15,
    glassOpacity: 0.9,
    rim: Color(0x80FFD7E1),
  ),
  ClockScene(
    id: "dawn",
    image: "assets/scenes/scene-dawn.jpg",
    foreground: "assets/scenes/scene-dawn-fg.webp",
    clockTop: 0.213,
  ),
  ClockScene(
    id: "water",
    image: "assets/scenes/scene-water.jpg",
    clockTop: 0.248,
    clockSize: 0.389,
    waterline: 0.55,
  ),
  ClockScene(
    id: "fog",
    image: "assets/scenes/scene-fog.jpg",
    foreground: "assets/scenes/scene-fog-fg.webp",
    clockTop: 0.159,
    clockSize: 0.435,
    clockLeft: 0.05,
    glassBrightness: 0.46,
    glassOpacity: 0.8,
    rim: Color(0x99FFFFFF),
    sheen: false,
  ),
  ClockScene(
    id: "golden",
    image: "assets/scenes/scene-golden.jpg",
    foreground: "assets/scenes/scene-golden-fg.webp",
    clockTop: 0.141,
    clockSize: 0.361,
  ),
  // Pixel island: a 16-bit island at four times of day, made for this launcher (see CREDITS.md).
  ClockScene(
    id: "island-dawn",
    image: "assets/scenes/scene-island-dawn.jpg",
    foreground: "assets/scenes/scene-island-dawn-fg.webp",
  ),
  ClockScene(
    id: "island-day",
    image: "assets/scenes/scene-island-day.jpg",
    foreground: "assets/scenes/scene-island-day-fg.webp",
  ),
  ClockScene(
    id: "island-golden",
    image: "assets/scenes/scene-island-golden.jpg",
    foreground: "assets/scenes/scene-island-golden-fg.webp",
  ),
  ClockScene(
    id: "island-night",
    image: "assets/scenes/scene-island-night.jpg",
    foreground: "assets/scenes/scene-island-night-fg.webp",
    // The night sky is dark navy: brighter glass keeps the digits readable.
    glassBrightness: 1.7,
    rim: Color(0x99D7E6FF),
  ),
];

/// A family of scenes that "Follow the day" picks from, one per time of day.
class ClockSceneSet {
  final String id;

  /// Scene ids for "dawn", "day", "fog", "golden" and "night"; a missing time of day uses "day".
  final Map<String, String> phases;

  const ClockSceneSet(this.id, this.phases);

  String sceneFor(String phase) => phases[phase] ?? phases["day"]!;

  /// The scenes of this set, in the order of the day.
  List<String> get sceneIds => [
        for (final phase in const ["dawn", "day", "fog", "golden", "night"])
          if (phases[phase] != null) phases[phase]!,
      ];
}

const List<ClockSceneSet> clockSceneSets = [
  ClockSceneSet("landscapes", {"dawn": "dawn", "day": "water", "fog": "fog", "golden": "golden", "night": "night"}),
  ClockSceneSet("island", {"dawn": "island-dawn", "day": "island-day", "golden": "island-golden", "night": "island-night"}),
];

ClockSceneSet clockSceneSetById(String id) =>
    clockSceneSets.firstWhere((set) => set.id == id, orElse: () => clockSceneSets.first);

ClockScene clockSceneById(String id) =>
    clockScenes.firstWhere((scene) => scene.id == id, orElse: () => clockScenes.first);

/// The sun's altitude above the horizon in degrees, and its hour angle in
/// degrees (negative before solar noon), for a place and moment.
({double altitude, double hourAngle}) solarPosition(double latitude, double longitude, DateTime time) {
  final utc = time.toUtc();
  final dayOfYear = utc.difference(DateTime.utc(utc.year, 1, 1)).inDays + 1;
  final b = 2 * math.pi / 365.25 * (dayOfYear - 81);
  // Equation of time in minutes, and declination.
  final equationOfTime = 9.87 * math.sin(2 * b) - 7.53 * math.cos(b) - 1.5 * math.sin(b);
  final declination = 23.45 * math.sin(b) * math.pi / 180;
  final utcHours = utc.hour + utc.minute / 60 + utc.second / 3600;
  final solarTime = (utcHours + longitude / 15 + equationOfTime / 60 + 24) % 24;
  final hourAngle = (solarTime - 12) * 15 * math.pi / 180;
  final lat = latitude * math.pi / 180;
  final sinAltitude =
      math.sin(lat) * math.sin(declination) + math.cos(lat) * math.cos(declination) * math.cos(hourAngle);
  final altitude = math.asin(sinAltitude.clamp(-1.0, 1.0)) * 180 / math.pi;
  return (altitude: altitude, hourAngle: hourAngle * 180 / math.pi);
}

/// WMO weather codes for overcast skies, drizzle, rain and showers: the day
/// scene becomes the misty one.
const Set<int> _greyWeatherCodes = {3, 45, 48, 51, 53, 55, 61, 63, 65, 80, 81, 82};

/// Picks the scene of [set] (landscapes by default) for [time]: dawn and golden hour while the sun
/// is low, day (fog when the weather is grey) when it is up, night once the sun is 6° under the
/// horizon. Without a place it falls back to fixed hours.
String sceneForTime(DateTime time, {double? latitude, double? longitude, int? weatherCode, ClockSceneSet? set}) =>
    (set ?? clockSceneSets.first)
        .sceneFor(dayPhase(time, latitude: latitude, longitude: longitude, weatherCode: weatherCode));

/// The time of day for [time]: "dawn", "day", "fog", "golden" or "night".
String dayPhase(DateTime time, {double? latitude, double? longitude, int? weatherCode}) {
  final daytime = weatherCode != null && _greyWeatherCodes.contains(weatherCode) ? "fog" : "day";
  if (latitude == null || longitude == null) {
    final hour = time.hour;
    if (hour >= 5 && hour < 8) return "dawn";
    if (hour >= 8 && hour < 17) return daytime;
    if (hour >= 17 && hour < 20) return "golden";
    return "night";
  }
  final sun = solarPosition(latitude, longitude, time);
  if (sun.altitude < -6) return "night";
  if (sun.altitude < 10) return sun.hourAngle < 0 ? "dawn" : "golden";
  return daytime;
}
