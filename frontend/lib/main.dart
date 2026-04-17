import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'screens/login_screen.dart';
import 'providers/app_state.dart';

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

    return MaterialApp(
      title: 'Keepsy',
      debugShowCheckedModeBanner: false,
      // theme: isDark ? K.darkTheme : K.lightTheme,
      home: const LoginScreen(),
    );
  }
}