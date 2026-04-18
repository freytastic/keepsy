import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'providers/app_state.dart';
import 'screens/login_screen.dart';
// import 'screens/main_shell.dart';
import 'screens/landing_screen.dart';
// import 'services/storage_service.dart';
import 'services/api_client.dart';
import 'core/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final appState = AppState();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: appState),
      ],
      child: const KeepsyApp(),
    ),
  );
}

class KeepsyApp extends StatelessWidget {
  const KeepsyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = context.select((AppState s) => s.isDark);
    final accent = context.select((AppState s) => s.accent);


    return MaterialApp(
      title: 'Keepsy',
      debugShowCheckedModeBanner: false,
      navigatorKey: ApiClient.navigatorKey,
      theme: K.theme(isDark, accent),
      home: const LandingPage(),
      routes: {
        '/login': (_) => const LoginScreen(),
      },
    );
  }
}
