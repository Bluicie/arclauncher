import 'package:flauncher/providers/quick_actions_service.dart';
import 'package:flauncher/widgets/app_bar_focus_ring.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// The quick-action buttons next to the settings button in the status bar.
class QuickActionsBar extends StatelessWidget {
  const QuickActionsBar({super.key});

  @override
  Widget build(BuildContext context) {
    final service = context.watch<QuickActionsService?>();
    final actions = service?.actions ?? const <QuickAction>[];
    if (service == null || actions.isEmpty) {
      return const SizedBox.shrink();
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [for (final action in actions) _QuickActionButton(service, action, key: ValueKey(action.id))],
    );
  }

  static const Map<String, IconData> icons = {
    "movie": Icons.movie_outlined,
    "television": Icons.tv,
    "lightbulb": Icons.lightbulb_outline,
    "lightbulb-off": Icons.dark_mode_outlined,
    "lamp": Icons.wb_incandescent_outlined,
    "ceiling-light": Icons.wb_incandescent_outlined,
    "bed": Icons.bed_outlined,
    "weather-night": Icons.nightlight_outlined,
    "power": Icons.power_settings_new,
    "home": Icons.home_outlined,
    "door": Icons.door_front_door_outlined,
    "lock": Icons.lock_outline,
    "lock-open": Icons.lock_open,
    "thermometer": Icons.thermostat,
    "fan": Icons.air,
    "music": Icons.music_note,
    "play": Icons.play_arrow,
    "pause": Icons.pause,
    "stop": Icons.stop,
    "volume-high": Icons.volume_up,
    "volume-off": Icons.volume_off,
    "sofa": Icons.weekend_outlined,
    "star": Icons.star_outline,
    "palette": Icons.palette_outlined,
    "gamepad-variant": Icons.sports_esports_outlined,
    "coffee": Icons.coffee_outlined,
    "bell": Icons.notifications_outlined,
    "account": Icons.person_outline,
    "blinds": Icons.view_day_outlined,
    "garage": Icons.directions_car_outlined,
    "robot-vacuum": Icons.cleaning_services_outlined,
    "gesture-tap": Icons.touch_app_outlined,
  };

  static IconData iconFor(String name) => icons[name] ?? Icons.touch_app_outlined;
}

class _QuickActionButton extends StatefulWidget {
  final QuickActionsService service;
  final QuickAction action;

  const _QuickActionButton(this.service, this.action, {super.key});

  @override
  State<_QuickActionButton> createState() => _QuickActionButtonState();
}

class _QuickActionButtonState extends State<_QuickActionButton> {
  /// null: idle, true/false: result of the last press (shown for 2 seconds).
  bool? _result;
  bool _busy = false;

  Future<void> _press() async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    final ok = await widget.service.trigger(widget.action);
    if (!mounted) {
      return;
    }
    setState(() {
      _busy = false;
      _result = ok;
    });
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) {
      setState(() => _result = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final IconData icon = switch (_result) {
      true => Icons.check_circle_outline,
      false => Icons.error_outline,
      null => QuickActionsBar.iconFor(widget.action.icon),
    };
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Tooltip(
        message: widget.action.label,
        child: AppBarFocusRing(
          onPressed: _press,
          semanticLabel: widget.action.label,
          child: Opacity(
            opacity: _busy ? 0.5 : 1,
            child: Icon(
              icon,
              size: 20,
              color: _result == false ? Colors.redAccent : Colors.white,
              shadows: const [Shadow(color: Colors.black54, blurRadius: 8, offset: Offset(0, 2))],
            ),
          ),
        ),
      ),
    );
  }
}
