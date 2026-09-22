import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:keepsy/ui/theme/warm_tokens.dart';
import 'package:keepsy/ui/widgets/default_status_bar.dart';

void main() {
  testWidgets('closing a dark screen brings the dark icons back',
      (tester) async {
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: nav,
      builder: (_, child) => DefaultStatusBar(child: child!),
      home: const Scaffold(body: SizedBox.expand()),
    ));
    await tester.pump();
    expect(SystemChrome.latestStyle?.statusBarIconBrightness, Brightness.dark);

    nav.currentState!.push(PageRouteBuilder<void>(
      opaque: false,
      pageBuilder: (_, __, ___) => const AnnotatedRegion<SystemUiOverlayStyle>(
        value: Warm.overlayOnPeek,
        child: SizedBox.expand(),
      ),
    ));
    await tester.pumpAndSettle();
    expect(SystemChrome.latestStyle?.statusBarIconBrightness, Brightness.light);

    nav.currentState!.pop();
    await tester.pumpAndSettle();
    expect(SystemChrome.latestStyle?.statusBarIconBrightness, Brightness.dark);
  });
}
