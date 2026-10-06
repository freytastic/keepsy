import 'dart:async';

import 'package:flutter/foundation.dart';

// Toggle visibility twice per blink without requesting every display frame
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
