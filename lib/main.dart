import 'package:flutter/material.dart';
import 'package:xorbit/models/app_state.dart';
import 'package:xorbit/pages/device_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await appState.init();
  await themeNotifier.load();
  await PremiumGate.load();

  runApp(const XorbitApp());
}

class XorbitApp extends StatelessWidget {
  const XorbitApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: themeNotifier,
      builder: (_, __) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Xorbit',
        themeMode: themeNotifier.mode,

        darkTheme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: const Color(0xFF080E1C),
          colorScheme: const ColorScheme.dark(
            primary: Color(0xFF2979FF),
            secondary: Color(0xFF448AFF),
            surface: Color(0xFF111827),
            onSurface: Colors.white,
          ),
          appBarTheme: const AppBarTheme(
            backgroundColor: Color(0xFF080E1C),
            elevation: 0,
            titleTextStyle: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
            iconTheme: IconThemeData(color: Colors.white),
          ),
          cardTheme: CardThemeData(
            color: const Color(0xFF111827),
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
          drawerTheme: const DrawerThemeData(
            backgroundColor: Color(0xFF0D1321),
          ),
          elevatedButtonTheme: ElevatedButtonThemeData(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF2979FF),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: 24,
                vertical: 14,
              ),
            ),
          ),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: const Color(0xFF1E2A3A),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide.none,
            ),
          ),
        ),

        theme: ThemeData(
          brightness: Brightness.light,
          scaffoldBackgroundColor: const Color(0xFFF4F6FB),
          colorScheme: const ColorScheme.light(
            primary: Color(0xFF1565C0),
            secondary: Color(0xFF1E88E5),
            surface: Colors.white,
            onSurface: Color(0xFF1A1A2E),
          ),
          appBarTheme: const AppBarTheme(
            backgroundColor: Color(0xFFF4F6FB),
            elevation: 0,
            titleTextStyle: TextStyle(
              color: Color(0xFF1A1A2E),
              fontSize: 20,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
            iconTheme: IconThemeData(color: Color(0xFF1A1A2E)),
          ),
          cardTheme: CardThemeData(
            color: Colors.white,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
          drawerTheme: const DrawerThemeData(
            backgroundColor: Colors.white,
          ),
          elevatedButtonTheme: ElevatedButtonThemeData(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1565C0),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: 24,
                vertical: 14,
              ),
            ),
          ),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: const Color(0xFFEEF2FA),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide.none,
            ),
          ),
        ),

        home: const DevicePage(),
      ),
    );
  }
}