/*
 * FLauncher
 * Copyright (C) 2021  Étienne Fesser
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

import 'package:flutter/material.dart';

/// Paints the 1dp tvOS hairline specular gradient contour along an app card's perimeter.
///
/// Ported from the native Arc TV app card (`ArcAppCard.kt`):
/// - Focused: a 1dp hairline vertical gradient falling away from the top edge:
///   `White @ 0.50` -> `Accent @ 0.25` -> `White @ 0.12`.
/// - Moving / Reordering: a 2dp vertical gradient:
///   `White @ 1.0` -> `Accent @ 1.0` -> `White @ 0.80`.
class AppCardContourPainter extends CustomPainter {
  final double radius;
  final double strokeWidth;
  final Color accentColor;
  final double alpha;
  final bool isMoving;

  const AppCardContourPainter({
    this.radius = 12.0,
    this.strokeWidth = 1.0,
    required this.accentColor,
    this.alpha = 1.0,
    this.isMoving = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || strokeWidth <= 0) return;

    final halfStroke = strokeWidth / 2.0;
    final rect = Rect.fromLTWH(
      halfStroke,
      halfStroke,
      size.width - strokeWidth,
      size.height - strokeWidth,
    );
    final rrect = RRect.fromRectAndRadius(
      rect,
      Radius.circular((radius - halfStroke).clamp(0.0, double.infinity)),
    );

    final gradient = isMoving
        ? LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.white,
              accentColor,
              Colors.white.withValues(alpha: 0.8),
            ],
          )
        : LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.white.withValues(alpha: 0.50 * alpha),
              accentColor.withValues(alpha: 0.25 * alpha),
              Colors.white.withValues(alpha: 0.12 * alpha),
            ],
          );

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..shader = gradient.createShader(Offset.zero & size);

    canvas.drawRRect(rrect, paint);
  }

  @override
  bool shouldRepaint(covariant AppCardContourPainter oldDelegate) =>
      oldDelegate.radius != radius ||
      oldDelegate.strokeWidth != strokeWidth ||
      oldDelegate.accentColor != accentColor ||
      oldDelegate.alpha != alpha ||
      oldDelegate.isMoving != isMoving;
}
