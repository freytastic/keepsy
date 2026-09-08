import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

class PhotoHold extends StatelessWidget {
  static const duration = Duration(milliseconds: 240);

  final GestureLongPressStartCallback onStart;
  final Widget child;

  const PhotoHold({
    super.key,
    required this.onStart,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: <Type, GestureRecognizerFactory>{
        LongPressGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
          () => LongPressGestureRecognizer(duration: duration),
          (recognizer) => recognizer.onLongPressStart = onStart,
        ),
      },
      child: child,
    );
  }
}
