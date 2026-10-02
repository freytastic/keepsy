import 'dart:async';

import 'package:flutter/foundation.dart';

// Square wave caret visibility. A repeating AnimationController asks for a
// frame on every vsync; this flips twice per period, so the screen redraws
// twice per blink instead of up to 120 times a second
class CaretBlink extends ValueNotifier<bool> {
  CaretBlink(Duration period) : super(true) {
    _timer = Timer.periodic(period ~/ 2, (_) => value = !value);
  }

  late final Timer _timer;

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }
}
