import 'package:flutter/material.dart';

import 'config.dart';
import 'screens/home_screen.dart';
import 'services/map_pack_service.dart';
import 'services/routing_service.dart';
import 'services/search_service.dart';
import 'services/settings.dart';
import 'services/style_builder.dart';
import 'services/update_service.dart';
import 'services/voice_service.dart';

/// One place that holds every service, shared by all screens.
class Services {
  Services._(this.settings)
      : packs = MapPackService(settings),
        routing = RoutingService(settings),
        search = SearchService(),
        voice = VoiceService(settings),
        updates = UpdateService() {
    styles = StyleBuilder(packs);
  }

  static late Services i;

  final Settings settings;
  final MapPackService packs;
  final RoutingService routing;
  final SearchService search;
  final VoiceService voice;
  final UpdateService updates;
  late final StyleBuilder styles;

  static Future<void> init() async {
    final s = Settings();
    await s.load();
    i = Services._(s);
    await i.voice.init();
  }
}

class Brand {
  static const teal = Color(0xFF0E7C7B);
  static const tealDark = Color(0xFF0A5554);
  static const amber = Color(0xFFFFB400);
  static const coral = Color(0xFFE85D4A);
  static const routeBlue = '#1E88E5';
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Services.init();
  runApp(const SafeRouteApp());
}

class SafeRouteApp extends StatelessWidget {
  const SafeRouteApp({super.key});

  ThemeData _theme(Brightness b) {
    final scheme = ColorScheme.fromSeed(
      seedColor: Brand.teal,
      brightness: b,
      primary: b == Brightness.light ? Brand.teal : const Color(0xFF4FC3C1),
      secondary: Brand.amber,
    );
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 56),
          textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = Services.i.settings;
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => MaterialApp(
        title: AppConfig.appName,
        debugShowCheckedModeBanner: false,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        themeMode: settings.isNight ? ThemeMode.dark : ThemeMode.light,
        home: const HomeScreen(),
      ),
    );
  }
}
