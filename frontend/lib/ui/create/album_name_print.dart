import 'package:flutter/material.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';
import 'package:keepsy/ui/widgets/print_card.dart';

import 'create_copy.dart';

// Editable album print with entry and exit motion
class AlbumNamePrint extends StatefulWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onSubmitted;
  final bool enabled;

  const AlbumNamePrint({
    super.key,
    required this.controller,
    required this.onChanged,
    required this.onSubmitted,
    this.enabled = true,
  });

  @override
  State<AlbumNamePrint> createState() => AlbumNamePrintState();
}

class AlbumNamePrintState extends State<AlbumNamePrint>
    with TickerProviderStateMixin {
  static const _restTiltDegrees = -1.6;
  static const _entryTiltDegrees = 6.0;
  static const _riseFrom = 200.0;
  static const _entryScale = 0.5;
  static const _exitTo = -420.0;
  static const _exitTiltDegrees = -3.0;
  static const _exitScale = 0.58;
  static const _exitDuration = Duration(milliseconds: 320);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 620),
  )..forward();

  late final Animation<double> _t = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );

  late final Animation<double> _exitCurve = CurvedAnimation(
    parent: _exit,
    curve: Curves.easeInCubic,
  );

  late final AnimationController _exit = AnimationController(
    vsync: this,
    duration: _exitDuration,
  );

  // Key for the translated flight transform
  static const flightKey = ValueKey('print-flight');

  // Moves the print out before the route closes
  Future<void> flyOut() async {
    if (!mounted) return;
    await _exit.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    _exit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_t, _exitCurve]),
      builder: (context, child) {
        final t = _t.value;
        final e = _exitCurve.value;
        final degrees = _entryTiltDegrees +
            (_restTiltDegrees - _entryTiltDegrees) * t +
            (_exitTiltDegrees - _restTiltDegrees) * e;
        final rest = _entryScale + (1 - _entryScale) * t;
        return Transform.rotate(
          angle: degrees * 3.1415926535 / 180,
          child: Transform.translate(
            key: flightKey,
            offset: Offset(0, _riseFrom * (1 - t) + _exitTo * e),
            child: Transform.scale(
              scale: rest + (_exitScale - rest) * e,
              child:
                  Opacity(opacity: (t * (1 - e)).clamp(0.0, 1.0), child: child),
            ),
          ),
        );
      },
      child: PrintCard(
        blank: true,
        frame: true,
        chin: Center(child: _NameField(widget: widget)),
      ),
    );
  }
}

class _NameField extends StatelessWidget {
  final AlbumNamePrint widget;

  const _NameField({required this.widget});

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: widget.controller,
      enabled: widget.enabled,
      // Avoid opening the keyboard during the entry animation
      autofocus: false,
      textAlign: TextAlign.center,
      maxLength: 38,
      maxLines: 1,
      textInputAction: TextInputAction.done,
      style: const TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: Warm.ink,
      ),
      decoration: const InputDecoration(
        isDense: true,
        counterText: '',
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        hintText: CreateCopy.namePlaceholder,
        hintStyle: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w500,
          color: Warm.inkFaint,
        ),
      ),
      onChanged: widget.onChanged,
      onSubmitted: (_) => widget.onSubmitted(),
    );
  }
}
