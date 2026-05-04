import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:keepsy/data/api/api_client.dart';
import 'package:keepsy/data/api/api_error.dart';
import 'package:keepsy/data/api/error_mapper.dart';
import 'package:keepsy/data/api/prekey_json_client.dart';
import 'package:keepsy/data/api/realtime_service.dart';
import 'package:keepsy/e2ee/identity.dart';
import 'package:keepsy/e2ee/identity_label_map.dart';
import 'package:keepsy/e2ee/prekey_api.dart';
import 'package:keepsy/secure_store/secure_key_store.dart';
import 'package:keepsy/ui/providers/app_state.dart';
import 'package:keepsy/ui/screens/landing_screen.dart';
import 'package:keepsy/ui/screens/login_screen.dart';
import 'package:keepsy/ui/theme/app_theme.dart';

// Top-level so the global error boundary in this file can resolve a
// messenger and route. Lives in ui/ — the data layer must not see it.
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();
final GlobalKey<ScaffoldMessengerState> rootMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

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
  final apiClient = ApiClient();
  final realtimeService = RealtimeService(apiClient);

  // Compose the E2EE stack here so the rest of the app can 'context.read'
  // it via Provider. The platform SecureKeyStore factory throws on host : the
  // production app only runs this on iOS/Android, so the throw is the right
  // behavior. Tests inject their own SecureKeyStore + IdentityLabelMap
  final secureKeyStore = createSecureKeyStore();
  final labelMap = IdentityLabelMap();
  await labelMap.load();
  final prekeyApi = HttpPrekeyApi(ApiClientPrekeyJsonClient(apiClient));
  final identityService = IdentityService(
    store: secureKeyStore,
    labels: labelMap,
    api: prekeyApi,
  );

  //WS e2ee.opk_low → replenishOpks. Service level mutex collapses
  // bursts to one in flight call so bouncing connections dont fan out
  realtimeService.stream.listen((ev) {
    if (ev.type == 'e2ee.opk_low') {
      identityService.replenishOpks();
    }
  });

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: appState),
        Provider.value(value: realtimeService),
        Provider<IdentityLabelMap>.value(value: labelMap),
        Provider<IdentityService>.value(value: identityService),
      ],
      child: const KeepsyApp(),
    ),
  );
}

void _showApiError(ApiError err) {
  final ux = mapApiError(err);
  rootMessengerKey.currentState?.showSnackBar(
    SnackBar(
      content: Text(ux.userMessage),
      duration: ux.isTransient
          ? const Duration(seconds: 3)
          : const Duration(seconds: 6),
      behavior: SnackBarBehavior.floating,
    ),
  );
  if (ux.action == ErrorRecovery.abortAndReauth) {
    rootNavigatorKey.currentState?.pushNamedAndRemoveUntil(
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
      navigatorKey: rootNavigatorKey,
      scaffoldMessengerKey: rootMessengerKey,
      theme: K.theme(isDark, accent),
      home: const LandingPage(),
      routes: {
        '/login': (_) => const LoginScreen(),
      },
    );
  }
}
