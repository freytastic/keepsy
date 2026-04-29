import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'providers/app_state.dart';
import 'screens/login_screen.dart';
import 'screens/landing_screen.dart';
import 'services/api_client.dart';
import 'services/api_error.dart';
import 'services/error_mapper.dart';
import 'core/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Global error boundary : any uncaught error inside a Flutter widget tree
  // bubbles up here.. we render a banner via ScaffoldMessenger so the user
  // never sees a red Flutter error frame in production
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    final err = details.exception;
    if (err is ApiError) {
      _showApiError(err);
    }
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    if (error is ApiError) {
      _showApiError(error);
      return true;
    }
    return false;
  };

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

void _showApiError(ApiError err) {
  final ux = mapApiError(err);
  final messengerCtx = ApiClient.navigatorKey.currentContext;
  if (messengerCtx == null) return;
  final messenger = ScaffoldMessenger.maybeOf(messengerCtx);
  if (messenger == null) return;
  messenger.showSnackBar(
    SnackBar(
      content: Text(ux.userMessage),
      duration: ux.isTransient
          ? const Duration(seconds: 3)
          : const Duration(seconds: 6),
      behavior: SnackBarBehavior.floating,
    ),
  );

  if (ux.action == ErrorRecovery.abortAndReauth) {
    ApiClient.navigatorKey.currentState?.pushNamedAndRemoveUntil(
      '/login',
      (_) => false,
    );
  }
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
      // ScaffoldMessenger key tied to navigatorKey so _showApiError can
      // resolve a messenger from anywhere in the app
      scaffoldMessengerKey: GlobalKey<ScaffoldMessengerState>(),
      theme: K.theme(isDark, accent),
      home: const LandingPage(),
      routes: {
        '/login': (_) => const LoginScreen(),
      },
    );
  }
}
