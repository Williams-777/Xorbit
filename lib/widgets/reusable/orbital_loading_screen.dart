import 'package:flutter/material.dart';
import 'package:xorbit/models/app_state.dart';
import 'package:xorbit/widgets/reusable/orbital_background.dart';

class OrbitalLoadingScreen extends StatefulWidget {
  const OrbitalLoadingScreen({super.key});

  @override
  State<OrbitalLoadingScreen> createState() => _OrbitalLoadingScreenState();
}

class _OrbitalLoadingScreenState extends State<OrbitalLoadingScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = themeNotifier.isDark;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 160,
            height: 160,
            child: AnimatedBuilder(
              animation: _ctrl,
              builder: (_, __) => CustomPaint(
                painter: OrbitalPainter(
                  progress: _ctrl.value,
                  isDark: isDark,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Starting Xorbit...',
            style: TextStyle(
              fontSize: 14,
              color: scheme.onSurface.withOpacity(0.5),
            ),
          ),
        ],
      ),
    );
  }
}
