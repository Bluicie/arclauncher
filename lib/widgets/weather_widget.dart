import 'package:flauncher/providers/weather_service.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// Current temperature and condition for the status bar; empty while weather is off or not loaded yet.
class WeatherWidget extends StatelessWidget {
  final TextStyle textStyle;

  const WeatherWidget({super.key, required this.textStyle});

  @override
  Widget build(BuildContext context) {
    final weather = context.watch<WeatherService?>()?.current;
    if (weather == null) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(right: 16),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(iconFor(weather), size: 22, color: textStyle.color, shadows: textStyle.shadows),
          const SizedBox(width: 6),
          Text("${weather.temperature.round()}°", style: textStyle),
        ],
      ),
    );
  }

  /// Icon for a WMO weather code.
  static IconData iconFor(CurrentWeather weather) {
    final code = weather.code;
    if (code == 0) {
      return weather.isDay ? Icons.wb_sunny_outlined : Icons.nightlight_outlined;
    }
    if (code <= 2) {
      return weather.isDay ? Icons.wb_cloudy_outlined : Icons.nights_stay_outlined;
    }
    if (code == 3) {
      return Icons.cloud_outlined;
    }
    if (code == 45 || code == 48) {
      return Icons.foggy;
    }
    if (code >= 51 && code <= 57) {
      return Icons.grain;
    }
    if ((code >= 71 && code <= 77) || code == 85 || code == 86) {
      return Icons.ac_unit;
    }
    if (code >= 95) {
      return Icons.flash_on;
    }
    return Icons.water_drop_outlined;
  }
}
