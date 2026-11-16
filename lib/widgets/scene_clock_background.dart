import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flauncher/models/clock_scene.dart';
import 'package:flauncher/providers/settings_service.dart';
import 'package:flauncher/providers/watch_next_service.dart';
import 'package:flauncher/providers/weather_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

/// A layered scene with a large frosted glass clock, used instead of the wallpaper.
///
/// The scene follows the day (or a fixed scene from the settings) and changes with a crossfade.
/// While a recommendation has the focus, the glass takes the colours of its poster.
class SceneClockBackground extends StatefulWidget {
  /// Where the home content starts, in logical pixels from the top of the screen. The clock is
  /// kept above it.
  final double contentTop;

  const SceneClockBackground({super.key, required this.contentTop});

  @override
  State<SceneClockBackground> createState() => _SceneClockBackgroundState();
}

class _LoadedScene {
  final ClockScene scene;
  final ui.Image image;
  final ui.Image? foreground;
  final ui.Image glass;

  const _LoadedScene(this.scene, this.image, this.foreground, this.glass);
}

class _SceneClockBackgroundState extends State<SceneClockBackground> with SingleTickerProviderStateMixin {
  Timer? _timer;
  DateTime _now = DateTime.now();
  _LoadedScene? _shown;
  String? _loading;
  final Set<String> _failed = {};

  // The glass fades from [_tintFrom] to [_tintTo]; `null` is the scene's own glass.
  late final AnimationController _tint =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 600), value: 1);
  ui.Image? _tintFrom;
  ui.Image? _tintTo;
  Uint8List? _posterBytes;

  @override
  void initState() {
    super.initState();
    _scheduleTick();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _tint.dispose();
    super.dispose();
  }

  /// Makes the glass for the focused recommendation's poster, or goes back to the scene's glass.
  Future<void> _followPoster(Uint8List? bytes) async {
    // Never change state during the build that noticed the new poster.
    await Future<void>.value();
    ui.Image? glass;
    if (bytes != null) {
      try {
        final codec = await ui.instantiateImageCodec(bytes, targetWidth: 480);
        final poster = (await codec.getNextFrame()).image;
        codec.dispose();
        glass = await _makeGlass(poster);
        poster.dispose();
      } catch (_) {
        glass = null;
      }
    }
    if (!mounted || !identical(bytes, _posterBytes)) return;
    setState(() {
      _tintFrom = _tint.value >= 0.5 ? _tintTo : _tintFrom;
      _tintTo = glass;
    });
    _tint.forward(from: 0);
  }

  void _scheduleTick() {
    final now = DateTime.now();
    final nextMinute = DateTime(now.year, now.month, now.day, now.hour, now.minute + 1);
    _timer = Timer(nextMinute.difference(now), () {
      if (!mounted) return;
      setState(() => _now = DateTime.now());
      _scheduleTick();
    });
  }

  String _targetScene(BuildContext context) {
    final setting = context.select<SettingsService, String>((s) => s.sceneClockScene);
    if (setting != autoClockScene) {
      return clockSceneById(setting).id;
    }
    final set = context.select<SettingsService, String>((s) => s.sceneClockSet);
    final weather = context.watch<WeatherService?>();
    return sceneForTime(
      _now,
      latitude: weather?.latitude,
      longitude: weather?.longitude,
      weatherCode: weather?.current?.code,
      set: clockSceneSetById(set),
    );
  }

  Future<void> _load(String id, int targetWidth) async {
    _loading = id;
    final scene = clockSceneById(id);
    try {
      final image = await _decodeAsset(scene.image, targetWidth);
      final foreground = scene.foreground == null ? null : await _decodeAsset(scene.foreground!, targetWidth);
      final glass = await _makeGlass(image);
      if (!mounted || _loading != id) return;
      setState(() {
        _shown = _LoadedScene(scene, image, foreground, glass);
        _loading = null;
      });
    } catch (_) {
      _failed.add(id);
      if (_loading == id) _loading = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final id = _targetScene(context);
    if (_shown?.scene.id != id && _loading != id && !_failed.contains(id)) {
      final physicalWidth = (size.width * dpr).round();
      _load(id, physicalWidth <= 0 ? 1920 : math.min(physicalWidth, 1920));
    }

    final posterBytes = context.select<WatchNextService?, Uint8List?>((service) {
      final item = service?.focusedItem;
      return item == null ? null : service!.getCachedPoster(service.getPosterUriForItem(item));
    });
    if (!identical(posterBytes, _posterBytes)) {
      _posterBytes = posterBytes;
      _followPoster(posterBytes);
    }

    final shown = _shown;
    final pattern = MediaQuery.alwaysUse24HourFormatOf(context) ? "HH:mm" : "h:mm";
    return SizedBox(
      width: size.width,
      height: size.height,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 1500),
        child: shown == null
            ? const ColoredBox(key: ValueKey("scene_loading"), color: Colors.black, child: SizedBox.expand())
            : AnimatedBuilder(
                key: ValueKey("scene_${shown.scene.id}"),
                animation: _tint,
                builder: (context, _) => CustomPaint(
                  size: size,
                  painter: ClockScenePainter(
                    scene: shown.scene,
                    image: shown.image,
                    foreground: shown.foreground,
                    glass: _tintFrom ?? shown.glass,
                    tintGlass: _tintTo ?? shown.glass,
                    tint: _tint.value,
                    time: DateFormat(pattern).format(_now),
                    contentTop: widget.contentTop,
                    // After 9 pm everything dims a little.
                    dim: _now.hour >= 21 || _now.hour < 6,
                  ),
                ),
              ),
      ),
    );
  }
}

Future<ui.Image> _decodeAsset(String asset, int targetWidth) async {
  final data = await rootBundle.load(asset);
  final codec = await ui.instantiateImageCodec(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      targetWidth: targetWidth);
  try {
    return (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
}

/// A small, blurred and brightened copy of the photo: what the frosted digits show.
Future<ui.Image> _makeGlass(ui.Image image) async {
  const width = 480;
  const height = 270;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawImageRect(
    image,
    Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()
      ..filterQuality = FilterQuality.medium
      ..imageFilter = ui.ImageFilter.blur(sigmaX: 6, sigmaY: 6, tileMode: TileMode.clamp)
      ..colorFilter = const ColorFilter.matrix([
        1.1, 0, 0, 0, 14, //
        0, 1.1, 0, 0, 14, //
        0, 0, 1.1, 0, 14, //
        0, 0, 0, 1, 0, //
      ]),
  );
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(width, height);
  } finally {
    picture.dispose();
  }
}

ColorFilter _brightness(double value) => ColorFilter.matrix([
      value, 0, 0, 0, 0, //
      0, value, 0, 0, 0, //
      0, 0, value, 0, 0, //
      0, 0, 0, 1, 0, //
    ]);

/// Draws [image] over [destination] like `BoxFit.cover`, centred.
void _drawCover(Canvas canvas, ui.Image image, Rect destination, Paint paint) {
  final imageSize = Size(image.width.toDouble(), image.height.toDouble());
  final fitted = applyBoxFit(BoxFit.cover, imageSize, destination.size);
  final source = Alignment.center.inscribe(fitted.source, Offset.zero & imageSize);
  canvas.drawImageRect(image, source, destination, paint);
}

/// The clock's place and size on screen.
class ClockLayout {
  final double top;
  final double fontSize;

  const ClockLayout(this.top, this.fontSize);
}

/// Where the clock goes for [scene] on a screen of [size], kept above [contentTop]: the scene's
/// own place when it fits, else smaller, else higher up. `null` when there is no room at all.
ClockLayout? layoutClock(ClockScene scene, Size size, double contentTop) {
  // The digits' ink ends about 0.92 of the font size below the top of the line box.
  const inkDepth = 0.92;
  final height = size.height;
  final maxBottom = contentTop - 0.02 * height;
  var top = scene.clockTop * height;
  var fontSize = scene.clockSize * height;
  if (top + inkDepth * fontSize > maxBottom) {
    fontSize = (maxBottom - top) / inkDepth;
    if (fontSize < 0.2 * height) {
      top = 0.07 * height;
      fontSize = math.min(scene.clockSize * height, (maxBottom - top) / inkDepth);
    }
  }
  if (fontSize < 0.08 * height) return null;
  return ClockLayout(top, fontSize);
}

class ClockScenePainter extends CustomPainter {
  final ClockScene scene;
  final ui.Image image;
  final ui.Image? foreground;
  final ui.Image glass;

  /// The glass fading in over [glass], by [tint] (0 to 1).
  final ui.Image? tintGlass;
  final double tint;
  final String time;
  final double contentTop;
  final bool dim;

  ClockScenePainter({
    required this.scene,
    required this.image,
    required this.foreground,
    required this.glass,
    this.tintGlass,
    this.tint = 0,
    required this.time,
    required this.contentTop,
    required this.dim,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final screen = Offset.zero & size;
    final light = scene.brightness * (dim ? 0.72 : 1.0);
    final photoPaint = Paint()..filterQuality = FilterQuality.medium;
    if (light != 1.0) photoPaint.colorFilter = _brightness(light);

    _drawCover(canvas, image, screen, photoPaint);

    final layout = layoutClock(scene, size, contentTop);
    if (layout != null) {
      final waterline = scene.waterline;
      if (waterline == null) {
        _paintClock(canvas, size, layout, scene.rim);
      } else {
        // Sharp above the water, a blurred reflection below it.
        final line = size.height * waterline;
        canvas.save();
        canvas.clipRect(Rect.fromLTRB(0, 0, size.width, line));
        _paintClock(canvas, size, layout, scene.rim);
        canvas.restore();
        canvas.save();
        canvas.clipRect(Rect.fromLTRB(0, line, size.width, size.height));
        final blur = 0.002 * size.height;
        canvas.saveLayer(
          screen,
          Paint()
            ..color = const Color.fromRGBO(0, 0, 0, 0.78)
            ..imageFilter = ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        );
        _paintClock(canvas, size, layout, const Color(0x80AAF0FF));
        canvas.restore();
        canvas.restore();
      }
    }

    final cutout = foreground;
    if (cutout != null) _drawCover(canvas, cutout, screen, photoPaint);

    // Darker at the bottom, so the rows stay readable.
    canvas.drawRect(
      screen,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x00000000), Color(0x00000000), Color(0x80000000)],
          stops: [0, 0.6, 1],
        ).createShader(screen),
    );
  }

  TextPainter _text(double fontSize, {Color? color, Paint? foreground}) {
    final painter = TextPainter(
      textDirection: ui.TextDirection.ltr,
      text: TextSpan(
        text: time,
        style: TextStyle(
          fontFamily: "Antonio",
          fontSize: fontSize,
          fontWeight: FontWeight.w300,
          fontVariations: const [ui.FontVariation("wght", 300)],
          height: 0.82,
          leadingDistribution: TextLeadingDistribution.even,
          letterSpacing: -0.02 * fontSize,
          color: foreground == null ? color : null,
          foreground: foreground,
        ),
      ),
    );
    painter.layout();
    return painter;
  }

  void _paintClock(Canvas canvas, Size size, ClockLayout layout, Color rim) {
    final fontSize = layout.fontSize;
    final height = size.height;
    final shape = _text(fontSize, color: Colors.white);
    final left = scene.clockLeft == null ? (size.width - shape.width) / 2 : scene.clockLeft! * size.width;
    final offset = Offset(left, layout.top);
    final bounds = Rect.fromLTWH(left - fontSize * 0.1, layout.top - fontSize * 0.3, shape.width + fontSize * 0.2,
        fontSize * 1.6);

    // A soft shadow under the glass.
    _text(
      fontSize,
      foreground: Paint()
        ..color = const Color(0x29000000)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 0.013 * height),
    ).paint(canvas, offset + Offset(0, 0.0055 * height));

    // The frosted glass: the blurred photo, seen only through the digits.
    canvas.saveLayer(bounds, Paint()..color = Color.fromRGBO(0, 0, 0, scene.glassOpacity));
    shape.paint(canvas, offset);
    final glassLight = scene.glassBrightness * (dim ? 0.72 : 1.0);
    final glassPaint = Paint()
      ..blendMode = BlendMode.srcIn
      ..filterQuality = FilterQuality.low;
    if (glassLight != 1.0) glassPaint.colorFilter = _brightness(glassLight);
    _drawCover(canvas, glass, Offset.zero & size, glassPaint);
    final incoming = tintGlass;
    if (incoming != null && tint > 0 && !identical(incoming, glass)) {
      final tintPaint = Paint()
        ..blendMode = BlendMode.srcATop
        ..filterQuality = FilterQuality.low
        ..color = Color.fromRGBO(0, 0, 0, tint.clamp(0.0, 1.0));
      if (glassLight != 1.0) tintPaint.colorFilter = _brightness(glassLight);
      _drawCover(canvas, incoming, Offset.zero & size, tintPaint);
    }
    if (scene.sheen) {
      canvas.drawRect(
        bounds,
        Paint()
          ..blendMode = BlendMode.srcATop
          ..shader = const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0x8CFFFFFF), Color(0x00FFFFFF), Color(0x00FFFFFF), Color(0x38FFFFFF)],
            stops: [0, 0.38, 0.7, 1],
          ).createShader(bounds),
      );
    }
    canvas.restore();

    // The rim: a faint tint and a thin light edge.
    _text(fontSize, color: const Color(0x14FFFFFF)).paint(canvas, offset);
    _text(
      fontSize,
      foreground: Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.0, 0.0014 * height)
        ..color = rim,
    ).paint(canvas, offset);
  }

  @override
  bool shouldRepaint(ClockScenePainter oldDelegate) =>
      oldDelegate.scene != scene ||
      oldDelegate.image != image ||
      oldDelegate.foreground != foreground ||
      oldDelegate.glass != glass ||
      oldDelegate.tintGlass != tintGlass ||
      oldDelegate.tint != tint ||
      oldDelegate.time != time ||
      oldDelegate.contentTop != contentTop ||
      oldDelegate.dim != dim;
}
