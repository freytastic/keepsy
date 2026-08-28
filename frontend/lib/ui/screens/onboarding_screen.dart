import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'package:keepsy/data/api/auth_api.dart';
import 'package:keepsy/data/api/realtime_service.dart';
import 'package:keepsy/data/api/user_api.dart';
import 'package:keepsy/e2ee/identity.dart';
import 'package:keepsy/ui/providers/app_state.dart';
import 'package:keepsy/ui/screens/main_shell.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';
import 'package:keepsy/ui/widgets/camera_stage.dart';

const int _kOtpLength = 6;
final RegExp _kEmailRe = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

const double _kTrustMarkExtent = 14;
const double _kCompactTrustGap = 12;
const double _kCompactEmailCopyBox = 64;
const double _kCompactOtpCopyBox = 88;
const double _kCompactFootExtent = 148;
const double _kCompactContentGap = 8;

enum _Phase { intro, email, otp, done }

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _emailCtrl = _EmailEditingController();
  final _otpCtrl = TextEditingController();
  final _emailFocus = FocusNode();
  final _otpFocus = FocusNode();

  _Phase _phase = _Phase.intro;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _emailCtrl.addListener(_onFieldChanged);
    _otpCtrl.addListener(_onFieldChanged);
  }

  @override
  void dispose() {
    _emailCtrl.removeListener(_onFieldChanged);
    _otpCtrl.removeListener(_onFieldChanged);
    _emailCtrl.dispose();
    _otpCtrl.dispose();
    _emailFocus.dispose();
    _otpFocus.dispose();
    super.dispose();
  }

  void _onFieldChanged() => setState(() {});

  String get _email => _emailCtrl.text.trim();
  String get _code => _otpCtrl.text;

  bool get _ready => switch (_phase) {
        _Phase.intro => true,
        _Phase.email => _kEmailRe.hasMatch(_email),
        _Phase.otp => _code.length == _kOtpLength,
        _Phase.done => false,
      };

  String get _ctaLabel => switch (_phase) {
        _Phase.intro => 'Continue',
        _Phase.email => 'Send code',
        _ => 'Verify',
      };

  Future<void> _advance() async {
    if (!_ready || _busy) return;
    switch (_phase) {
      case _Phase.intro:
        // Avoid opening the keyboard during the phase transition
        setState(() => _phase = _Phase.email);
      case _Phase.email:
        await _sendCode();
      case _Phase.otp:
        await _verify();
      case _Phase.done:
        break;
    }
  }

  Future<void> _sendCode() async {
    setState(() => _busy = true);
    try {
      final sent = await AuthService().requestOtp(_email);
      if (!mounted) return;
      if (!sent) {
        setState(() => _busy = false);
        _showError('We could not send a code to that address.');
        return;
      }
      setState(() {
        _phase = _Phase.otp;
        _busy = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      _showError('Connection error. Check your network and try again.');
    }
  }

  Future<void> _verify() async {
    final identity = context.read<IdentityService>();
    setState(() => _busy = true);
    // Let the pressed state paint before the request starts
    await WidgetsBinding.instance.endOfFrame;

    try {
      final ok = await AuthService().verifyOtp(_email, _code);
      if (!mounted) return;
      if (!ok) {
        _otpCtrl.clear();
        setState(() => _busy = false);
        _otpFocus.requestFocus();
        HapticFeedback.vibrate();
        _showError('That code did not match. Try again.');
        return;
      }

      final userData = await UserService().getMe();
      if (!mounted) return;
      final appState = context.read<AppState>();
      if (userData != null) appState.setUserData(userData);
      // The profile still needs the typed email when /me omits it
      appState.setEmail(_email);
      unawaited(context.read<RealtimeService>().connect());

      // Capture before navigation invalidates this context
      final messenger = ScaffoldMessenger.of(context);
      FocusManager.instance.primaryFocus?.unfocus();
      setState(() {
        _phase = _Phase.done;
        _busy = false;
      });
      await Future<void>.delayed(const Duration(milliseconds: 1150));
      if (!mounted) return;
      _goHome();
      // Keep keystore work off the sign-in transition
      unawaited(_bootstrapInBackground(identity, messenger));
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      _showError('Sign-in failed. Please try again.');
    }
  }

  Future<void> _bootstrapInBackground(
      IdentityService identity, ScaffoldMessengerState messenger) async {
    try {
      await identity.bootstrap();
    } on BootstrapAccountConflictException {
      messenger.showSnackBar(const SnackBar(
        content: Text(
          "This account's encryption keys are registered on another device. "
          'Use account recovery to continue here.',
        ),
        duration: Duration(seconds: 6),
      ));
      return;
    } catch (_) {
      messenger.showSnackBar(const SnackBar(
        content: Text('Encryption setup failed. Please reopen the app.'),
        duration: Duration(seconds: 5),
      ));
      return;
    }
    try {
      await identity.replenishOpks(
        target: kTargetOpkPool,
        trigger: kTargetOpkPool,
      );
    } catch (_) {}
  }

  void _goHome() {
    Navigator.of(context).pushAndRemoveUntil(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 420),
        pageBuilder: (_, __, ___) => const MainShell(),
        transitionsBuilder: (_, a, __, child) => FadeTransition(
          opacity: CurvedAnimation(parent: a, curve: Curves.easeOutQuad),
          child: child,
        ),
      ),
      (_) => false,
    );
  }

  void _showError(String message) {
    final messenger = ScaffoldMessenger.of(context)..removeCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      content: Text(message, style: const TextStyle(color: Warm.ctaInk)),
      backgroundColor: Warm.ctaBottom,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      duration: const Duration(seconds: 3),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    // Keep the camera anchored while the keyboard opens
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final keyboardOpen = keyboard > 0;
    final onIntro = _phase == _Phase.intro;
    // Use the same stable top inset as CameraStage.positioned
    final topInset = MediaQuery.viewPaddingOf(context).top;

    final compactCopyBox =
        _phase == _Phase.otp ? _kCompactOtpCopyBox : _kCompactEmailCopyBox;
    final compactCopyExtent =
        _kTrustMarkExtent + _kCompactTrustGap + compactCopyBox;
    final compactFootBottom = keyboard + 20;
    final compactFootTop =
        size.height - compactFootBottom - _kCompactFootExtent;
    final compactHeroMaxBottom =
        compactFootTop - compactCopyExtent - 2 * _kCompactContentGap;
    final compactStageScale = CameraStage.shrunkScaleToFit(
      context,
      maxVisualBottom: compactHeroMaxBottom,
    );
    final compactHeroBottom = CameraStage.shrunkVisualBottom(
      context,
      scale: compactStageScale,
    );
    final rawCompactSlack = compactFootTop -
        compactHeroBottom -
        compactCopyExtent -
        2 * _kCompactContentGap;
    final compactSlack = rawCompactSlack > 0 ? rawCompactSlack : 0.0;
    final compactCopyTop =
        compactHeroBottom + _kCompactContentGap + compactSlack / 2;

    // Keep system icons visible on the cream background
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark, // Android
        statusBarBrightness: Brightness.light, // iOS
      ),
      child: Scaffold(
        backgroundColor: Warm.ground,
        resizeToAvoidBottomInset: false,
        body: GestureDetector(
          onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
          behavior: HitTestBehavior.opaque,
          child: Stack(
            children: [
              const Positioned.fill(child: _Ground()),

              // Keep the scrim behind the camera so its colours stay unchanged
              const Positioned.fill(child: IgnorePointer(child: _Scrim())),

              CameraStage.positioned(
                context,
                shrink: keyboardOpen,
                shrunkScale: compactStageScale,
              ),

              // Move the copy with the compact camera to avoid field overlap
              AnimatedPositioned(
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOutCubic,
                top: topInset +
                    (keyboardOpen
                        ? compactCopyTop - topInset
                        : size.height * Warm.topAir),
                left: Warm.pagePad,
                right: Warm.pagePad,
                child: AnimatedOpacity(
                  opacity: _phase == _Phase.done ? 0 : 1,
                  duration: const Duration(milliseconds: 700),
                  curve: Warm.easeSoft,
                  child: _Copy(
                    phase: _phase,
                    email: _email,
                    compact: keyboardOpen,
                  ),
                ),
              ),

              AnimatedPositioned(
                duration: Warm.quick,
                curve: Warm.easeOut,
                left: Warm.pagePad,
                right: Warm.pagePad,
                bottom: (keyboard > 0
                    ? keyboard + 20
                    : size.height * Warm.ctaBottomInset),
                child: _phase == _Phase.done
                    ? const _Confirmation()
                    : _Foot(
                        onIntro: onIntro,
                        phase: _phase,
                        ready: _ready && !_busy,
                        busy: _busy,
                        label: _ctaLabel,
                        emailCtrl: _emailCtrl,
                        emailFocus: _emailFocus,
                        otpCtrl: _otpCtrl,
                        otpFocus: _otpFocus,
                        onSubmit: _advance,
                        compact: keyboardOpen,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Preserve IME composition without drawing Flutter's composing underline
class _EmailEditingController extends TextEditingController {
  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    return TextSpan(style: style, text: text);
  }
}

class _Ground extends StatelessWidget {
  const _Ground();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        color: Warm.ground,
        gradient: RadialGradient(
          center: Alignment(0, -1.4),
          radius: 1.1,
          colors: [Warm.groundLift, Warm.groundLift0],
        ),
      ),
    );
  }
}

class _Scrim extends StatelessWidget {
  const _Scrim();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, 0.36),
          radius: 0.78,
          colors: [
            Color(0xB8F6F3EE),
            Color(0x52F6F3EE),
            Color(0x00F6F3EE),
          ],
          stops: [0, 0.55, 1],
        ),
      ),
    );
  }
}

class _Copy extends StatelessWidget {
  const _Copy({
    required this.phase,
    required this.email,
    required this.compact,
  });

  final _Phase phase;
  final String email;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final onIntro = phase == _Phase.intro;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          height: _kTrustMarkExtent,
          child: _TrustMark(),
        ),
        SizedBox(height: compact ? _kCompactTrustGap : 20),
        SizedBox(
          height: compact
              ? (phase == _Phase.otp
                  ? _kCompactOtpCopyBox
                  : _kCompactEmailCopyBox)
              : 168,
          child: AnimatedSwitcher(
            duration: Warm.crossfade,
            switchInCurve: Warm.easeSoft,
            switchOutCurve: const FlippedCurve(Warm.easeSoft),
            // Keep copy top-aligned across phases.
            layoutBuilder: (current, previous) => Stack(
              alignment: Alignment.topCenter,
              children: [...previous, if (current != null) current],
            ),
            child: onIntro
                ? const _IntroCopy(key: ValueKey('intro'))
                : _PhaseCopy(
                    key: ValueKey(phase),
                    phase: phase,
                    email: email,
                    compact: compact,
                  ),
          ),
        ),
      ],
    );
  }
}

class _TrustMark extends StatelessWidget {
  const _TrustMark();

  @override
  Widget build(BuildContext context) {
    return const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.lock_outline_rounded, size: 12, color: Warm.inkSoft),
        SizedBox(width: 6),
        Text('END-TO-END ENCRYPTED', style: Warm.trustMark),
      ],
    );
  }
}

class _IntroCopy extends StatelessWidget {
  const _IntroCopy({super.key});

  @override
  Widget build(BuildContext context) {
    return const Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Keepsy', style: Warm.wordmark),
        SizedBox(height: Warm.headingToLead),
        SizedBox(
          width: Warm.leadMaxWidth,
          child: Text(
            'Shared photo albums for the people who were actually there.',
            textAlign: TextAlign.center,
            style: Warm.lead,
          ),
        ),
      ],
    );
  }
}

class _PhaseCopy extends StatelessWidget {
  const _PhaseCopy({
    super.key,
    required this.phase,
    required this.email,
    required this.compact,
  });

  final _Phase phase;
  final String email;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: Warm.leadMaxWidth,
      // Align phase copy with the intro lead.
      margin: EdgeInsets.only(top: compact ? 4 : Warm.headingToLead),
      child: phase == _Phase.email
          ? const Text(
              'We’ll send a one-time sign-in code to your email.',
              textAlign: TextAlign.center,
              style: Warm.lead,
            )
          : Text.rich(
              TextSpan(
                style: Warm.lead,
                children: [
                  const TextSpan(text: 'Enter the 6-digit code we sent to '),
                  TextSpan(
                    text: email,
                    style: const TextStyle(color: Warm.ink),
                  ),
                  const TextSpan(text: '.'),
                ],
              ),
              textAlign: TextAlign.center,
            ),
    );
  }
}

class _Foot extends StatelessWidget {
  const _Foot({
    required this.onIntro,
    required this.phase,
    required this.ready,
    required this.busy,
    required this.label,
    required this.emailCtrl,
    required this.emailFocus,
    required this.otpCtrl,
    required this.otpFocus,
    required this.onSubmit,
    required this.compact,
  });

  final bool onIntro;
  final _Phase phase;
  final bool ready;
  final bool busy;
  final String label;
  final TextEditingController emailCtrl;
  final FocusNode emailFocus;
  final TextEditingController otpCtrl;
  final FocusNode otpFocus;
  final Future<void> Function() onSubmit;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _Dots(step: onIntro ? 0 : 1),
        SizedBox(height: compact ? 14 : 22),
        AnimatedSize(
          duration: Warm.springSnappy,
          curve: Warm.easeSoft,
          child: onIntro
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: EdgeInsets.only(bottom: compact ? 14 : 22),
                  child: AnimatedSwitcher(
                    duration: Warm.quick,
                    child: phase == _Phase.email
                        ? _EmailPill(
                            key: const ValueKey('email'),
                            controller: emailCtrl,
                            focusNode: emailFocus,
                            onSubmit: onSubmit,
                          )
                        : _OtpRow(
                            key: const ValueKey('otp'),
                            controller: otpCtrl,
                            focusNode: otpFocus,
                            onSubmit: onSubmit,
                          ),
                  ),
                ),
        ),
        _Cta(label: label, ready: ready, busy: busy, onTap: onSubmit),
      ],
    );
  }
}

class _Dots extends StatelessWidget {
  const _Dots({required this.step});

  final int step;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(2, (i) {
        final active = i == step;
        return AnimatedContainer(
          duration: Warm.springSoft,
          curve: Warm.easeSoft,
          margin: EdgeInsets.only(right: i == 0 ? Warm.dotsGap : 0),
          width: active ? 20 : 6,
          height: 6,
          decoration: BoxDecoration(
            color: Warm.ink.withValues(alpha: active ? 1 : 0.28),
            borderRadius: BorderRadius.circular(3),
          ),
        );
      }),
    );
  }
}

class _EmailPill extends StatelessWidget {
  const _EmailPill({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final Future<void> Function() onSubmit;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 320),
        width: double.infinity,
        height: Warm.fieldHeight,
        decoration: BoxDecoration(
          gradient: Warm.stoneFill,
          borderRadius: BorderRadius.circular(Warm.fieldRadius),
          boxShadow: Warm.stoneShadow,
        ),
        child: TextField(
          controller: controller,
          focusNode: focusNode,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.go,
          autocorrect: false,
          textAlign: TextAlign.center,
          textAlignVertical: TextAlignVertical.center,
          style: Warm.input,
          cursorColor: Warm.inkFaint,
          cursorWidth: 2,
          onSubmitted: (_) => onSubmit(),
          decoration: const InputDecoration(
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            disabledBorder: InputBorder.none,
            errorBorder: InputBorder.none,
            focusedErrorBorder: InputBorder.none,
            hintText: 'your email',
            hintStyle: TextStyle(
              color: Warm.inkGhost,
              fontWeight: FontWeight.w400,
              fontSize: 17,
            ),
            contentPadding: EdgeInsets.symmetric(horizontal: 24),
          ),
          spellCheckConfiguration: const SpellCheckConfiguration.disabled(),
        ),
      ),
    );
  }
}

// One field preserves paste and SMS autofill across all six cells
class _OtpRow extends StatelessWidget {
  const _OtpRow({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final Future<void> Function() onSubmit;

  @override
  Widget build(BuildContext context) {
    final code = controller.text;
    return GestureDetector(
      onTap: focusNode.requestFocus,
      behavior: HitTestBehavior.opaque,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(_kOtpLength, (i) {
              return Padding(
                padding: EdgeInsets.only(right: i == _kOtpLength - 1 ? 0 : 8),
                child: _OtpCell(
                  digit: i < code.length ? code[i] : '',
                  active: i == code.length && focusNode.hasFocus,
                ),
              );
            }),
          ),
          SizedBox(
            height: Warm.otpCellHeight,
            width: _kOtpLength * Warm.otpCellWidth + (_kOtpLength - 1) * 8,
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.go,
              maxLength: _kOtpLength,
              autofillHints: const [AutofillHints.oneTimeCode],
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onSubmitted: (_) => onSubmit(),
              showCursor: false,
              style: const TextStyle(color: Colors.transparent, height: 0.01),
              decoration: const InputDecoration(
                border: InputBorder.none,
                counterText: '',
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _OtpCell extends StatelessWidget {
  const _OtpCell({required this.digit, required this.active});

  final String digit;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: Warm.quick,
      curve: Warm.easeOut,
      width: Warm.otpCellWidth,
      height: Warm.otpCellHeight,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: Warm.stoneFill,
        borderRadius: BorderRadius.circular(Warm.otpCellRadius),
        border: active ? Border.all(color: Warm.ink, width: 1.5) : null,
        boxShadow: Warm.stoneShadow,
      ),
      child: digit.isNotEmpty
          ? Text(digit, style: Warm.otpDigit)
          : active
              ? const _Caret()
              : null,
    );
  }
}

class _Caret extends StatefulWidget {
  const _Caret();

  @override
  State<_Caret> createState() => _CaretState();
}

class _CaretState extends State<_Caret> with SingleTickerProviderStateMixin {
  late final AnimationController _blink = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _blink,
      builder: (context, child) =>
          Opacity(opacity: _blink.value < 0.5 ? 1 : 0, child: child),
      child: Container(
        width: 2,
        height: 24,
        decoration: BoxDecoration(
          color: Warm.ink,
          borderRadius: BorderRadius.circular(1),
        ),
      ),
    );
  }
}

class _Cta extends StatefulWidget {
  const _Cta({
    required this.label,
    required this.ready,
    required this.busy,
    required this.onTap,
  });

  final String label;
  final bool ready;
  final bool busy;
  final Future<void> Function() onTap;

  @override
  State<_Cta> createState() => _CtaState();
}

class _CtaState extends State<_Cta> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.ready;
    return GestureDetector(
      onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
      onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
      onTap: enabled
          ? () {
              setState(() => _pressed = false);
              HapticFeedback.lightImpact();
              widget.onTap();
            }
          : null,
      child: AnimatedOpacity(
        opacity: enabled ? 1 : 0.42,
        duration: Warm.quick,
        child: AnimatedScale(
          scale: _pressed ? 0.965 : 1,
          duration: Warm.quick,
          curve: Warm.easeOut,
          child: SizedBox(
            width: 300,
            height: Warm.ctaHeight,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                Container(
                  decoration: BoxDecoration(
                    gradient: Warm.ctaFill,
                    borderRadius: BorderRadius.circular(Warm.ctaRadius),
                    boxShadow: enabled ? Warm.ctaShadow : Warm.ctaShadowIdle,
                  ),
                  alignment: Alignment.center,
                  child: widget.busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Warm.ctaInk,
                          ),
                        )
                      : AnimatedSwitcher(
                          duration: Warm.quick,
                          child: Text(
                            widget.label,
                            key: ValueKey(widget.label),
                            style: Warm.ctaLabel,
                          ),
                        ),
                ),
                Positioned.fill(child: _CtaGlow(lit: _pressed)),
                const Positioned(
                  top: 1,
                  left: 1,
                  right: 1,
                  height: Warm.ctaHeight * 0.4,
                  child: IgnorePointer(child: _CtaSheen()),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CtaSheen extends StatelessWidget {
  const _CtaSheen();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(Warm.ctaRadius - 1),
          bottom: Radius.elliptical(Warm.ctaRadius, 12),
        ),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withValues(alpha: 0.07),
            Colors.white.withValues(alpha: 0),
          ],
        ),
      ),
    );
  }
}

class _CtaGlow extends StatelessWidget {
  const _CtaGlow({required this.lit});

  final bool lit;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(Warm.ctaRadius),
      child: IgnorePointer(
        child: AnimatedOpacity(
          opacity: lit ? 1 : 0.37,
          duration: Warm.quick,
          child: ImageFiltered(
            imageFilter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  // Expand the short-side radius across the wide pill
                  radius: 2.4,
                  colors: [
                    Warm.orbPeach.withValues(alpha: 0.55),
                    Warm.orbBlush.withValues(alpha: 0.28),
                    Warm.orbPeach.withValues(alpha: 0),
                  ],
                  stops: const [0, 0.45, 0.72],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Confirmation extends StatelessWidget {
  const _Confirmation();

  @override
  Widget build(BuildContext context) {
    return const Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('You’re in.', style: Warm.confirmTitle),
        SizedBox(height: 8),
        Text('Setting up your albums…', style: Warm.confirmSub),
      ],
    );
  }
}
