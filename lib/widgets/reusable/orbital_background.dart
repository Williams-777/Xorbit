import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:xorbit/models/app_state.dart';

class OrbitalBackground extends StatefulWidget {
  const OrbitalBackground({super.key});

  @override
  State<OrbitalBackground> createState() => _OrbitalBackgroundState();
}

class _OrbitalBackgroundState extends State<OrbitalBackground>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 12),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = themeNotifier.isDark;
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) => CustomPaint(
        painter: OrbitalPainter(
          progress: _ctrl.value,
          isDark: isDark,
        ),
      ),
    );
  }
}

class OrbitalPainter extends CustomPainter {
  final double progress;
  final bool isDark;

  OrbitalPainter({required this.progress, required this.isDark});

  // Orbit config: [angle offset, orbit scale X, orbit scale Y, speed multiplier]
  static const _orbits = [
    [0.0, 1.0, 0.38, 1.0], // image   — outer ring, normal speed
    [0.5, 1.0, 0.38, 1.0], // video   — outer ring, opposite side
    [0.25, 0.68, 0.28, 1.4], // music   — inner ring, faster
    [0.75, 0.68, 0.28, 1.4], // doc     — inner ring, opposite
  ];

  // Icon emoji characters for each orbit
  static const _emojis = ['🖼', '🎬', '🎵', '📄'];

  // Orbit ring colors (ARGB)
  static const _ringColors = [
    Color(0xFF2979FF), // blue
    Color(0xFF9C27B0), // purple
    Color(0xFFE91E63), // pink
    Color(0xFFFF9800), // orange
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;

    // Keep animation in the upper portion — don't cover device cards
    final centerY = size.height * 0.18;
    final radius = size.width * 0.28;

    // ── Draw X ─────────────────────────────────────
    _drawX(canvas, cx, centerY, radius * 0.55);

    // ── Draw orbit rings ────────────────────────────
    for (int i = 0; i < _orbits.length; i++) {
      final cfg = _orbits[i];
      final rx = radius * cfg[1]; // horizontal radius of ellipse
      final ry = radius * cfg[2] * 0.5; // vertical radius (flatten it)
      final tilt = i.isEven ? -0.25 : 0.25; // tilt angle in radians

      _drawOrbitRing(canvas, cx, centerY, rx, ry, tilt, _ringColors[i]);
    }

    // ── Draw orbiting icons ─────────────────────────
    for (int i = 0; i < _orbits.length; i++) {
      final cfg = _orbits[i];
      final offset = cfg[0];
      final scaleX = cfg[1];
      final scaleY = cfg[2];
      final speed = cfg[3];

      final angle = (progress * speed + offset) * 2 * math.pi;
      final tilt = i.isEven ? -0.25 : 0.25;

      // Elliptical orbit with tilt
      final rawX = math.cos(angle) * radius * scaleX;
      final rawY = math.sin(angle) * radius * scaleY * 0.5;

      // Apply tilt rotation
      final x = cx + rawX * math.cos(tilt) - rawY * math.sin(tilt);
      final y = centerY + rawX * math.sin(tilt) + rawY * math.cos(tilt);

      // Depth cue: icons "behind" the X are smaller and more transparent
      final depth = (math.sin(angle) + 1) / 2; // 0 = far, 1 = near
      final iconSize = 16.0 + depth * 10;
      final alpha = 0.4 + depth * 0.6;

      _drawIconCircle(
        canvas,
        x,
        y,
        iconSize,
        _emojis[i],
        _ringColors[i],
        alpha,
      );
    }
  }

  void _drawX(Canvas canvas, double cx, double cy, double size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = size * 0.18
      ..strokeCap = StrokeCap.round
      ..color = (isDark ? const Color(0xFF2979FF) : const Color(0xFF1565C0))
          .withOpacity(0.12);

    // First stroke of X
    canvas.drawLine(
      Offset(cx - size, cy - size),
      Offset(cx + size, cy + size),
      paint,
    );
    // Second stroke of X
    canvas.drawLine(
      Offset(cx + size, cy - size),
      Offset(cx - size, cy + size),
      paint,
    );
  }

  void _drawOrbitRing(
    Canvas canvas,
    double cx,
    double cy,
    double rx,
    double ry,
    double tilt,
    Color color,
  ) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..color = color.withOpacity(isDark ? 0.15 : 0.1);

    // Draw ellipse as a path with tilt
    final path = Path();
    const steps = 80;
    for (int j = 0; j <= steps; j++) {
      final a = (j / steps) * 2 * math.pi;
      final rawX = math.cos(a) * rx;
      final rawY = math.sin(a) * ry;
      final x = cx + rawX * math.cos(tilt) - rawY * math.sin(tilt);
      final y = cy + rawX * math.sin(tilt) + rawY * math.cos(tilt);
      if (j == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.close();
    canvas.drawPath(path, paint);
  }

  void _drawIconCircle(
    Canvas canvas,
    double x,
    double y,
    double size,
    String emoji,
    Color color,
    double alpha,
  ) {
    // Circle background
    final bgPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = color.withOpacity(alpha * (isDark ? 0.25 : 0.15));

    canvas.drawCircle(Offset(x, y), size * 0.85, bgPaint);

    // Circle border
    final borderPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..color = color.withOpacity(alpha * 0.6);

    canvas.drawCircle(Offset(x, y), size * 0.85, borderPaint);

    // Emoji text
    final tp = TextPainter(
      text: TextSpan(
        text: emoji,
        style: TextStyle(fontSize: size * 0.8),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    tp.paint(
      canvas,
      Offset(
        x - tp.width / 2,
        y - tp.height / 2,
      ),
    );
  }

  @override
  bool shouldRepaint(OrbitalPainter old) =>
      old.progress != progress || old.isDark != isDark;
}
