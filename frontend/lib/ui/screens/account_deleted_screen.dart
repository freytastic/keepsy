import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';

// Terminal screen after the device wipe. The service graph behind the app was
// built on keys that no longer exist, so nothing here may touch it
class AccountDeletedScreen extends StatelessWidget {
  const AccountDeletedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: Warm.ground,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Warm.pagePad),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Your account is deleted', style: Warm.h1),
                const SizedBox(height: Warm.headingToLead),
                Text(
                  'Everything Keepsy kept on this phone is gone. Our servers '
                  'are removing the rest. Close Keepsy to finish.',
                  style: Warm.sub,
                ),
                const SizedBox(height: 32),
                // iOS ignores programmatic exits, so there the user closes it
                if (defaultTargetPlatform != TargetPlatform.iOS)
                  TextButton(
                    onPressed: () => SystemNavigator.pop(),
                    child: const Text('Close Keepsy'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
