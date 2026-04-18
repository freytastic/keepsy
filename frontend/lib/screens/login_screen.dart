import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../core/app_theme.dart';
import '../widgets/shared_widgets.dart';
import 'main_shell.dart';
import '../services/auth_service.dart';
import '../services/user_service.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  final _emailCtrl = TextEditingController();
  final _otpCtrls = List.generate(6, (_) => TextEditingController());
  final _otpFoci = List.generate(6, (_) => FocusNode());
  final _emailFocus = FocusNode();
  bool _otpMode = false;
  bool _loading = false;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _emailFocus.dispose();
    for (final c in _otpCtrls) {
      c.dispose();
    }
    for (final f in _otpFoci) {
      f.dispose();
    }
    super.dispose();
  }

  // navigate to MainShell – wipe entire nav stack
  void _goHome() {
    Navigator.of(context).pushAndRemoveUntil(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (_, __, ___) => const MainShell(),
        transitionsBuilder: (_, a, __, child) => FadeTransition(
          opacity: CurvedAnimation(parent: a, curve: Curves.easeOutQuad),
          child: child,
        ),
      ),
      (_) => false, // remove every route below
    );
  }

  void _handleContinue() async {
    if (_loading) return;

    final authService = AuthService();

    // email mode
    if (!_otpMode) {
      final email = _emailCtrl.text.trim();

      if (email.isEmpty) {
        HapticFeedback.lightImpact();
        _showError("Please enter your email");
        return;
      }

      final emailRegex = RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$');
      if (!emailRegex.hasMatch(email)) {
        HapticFeedback.lightImpact();
        _showError("Please enter a valid email address");
        return;
      }

      setState(() => _loading = true);

      try {
        final success = await authService.requestOtp(email);

        if (success) {
          setState(() {
            _otpMode = true;
            _loading = false;
          });

          await Future.delayed(const Duration(milliseconds: 100));
          _otpFoci[0].requestFocus();
        } else {
          setState(() => _loading = false);
          _showError("Failed to send OTP. Enter a valid Email");
        }
      } catch (e) {
        setState(() => _loading = false);
        _showError("Connection error");
      }
    }

    // otp mode
    else {
      String otpCode = _otpCtrls.map((c) => c.text).join();

      if (otpCode.length < 6) {
        HapticFeedback.vibrate();
        return;
      }

      setState(() => _loading = true);

      try {
        // verifyOtp now returns bool and saves token+expiry internally
        final ok = await authService.verifyOtp(_emailCtrl.text.trim(), otpCode);

        if (ok) {
          final userService = UserService();
          final userData = await userService.getMe();
          if (userData != null && mounted) {
            context.read<AppState>().setUserData(userData);
          }
          setState(() => _loading = false);
          _goHome();
        } else {
          for (final c in _otpCtrls) { c.clear(); }
          setState(() => _loading = false);
          _otpFoci[0].requestFocus();
          _showError("Invalid OTP code. Try again.");
        }
      } catch (e) {
        for (final c in _otpCtrls) { c.clear(); }
        setState(() => _loading = false);
        _otpFoci[0].requestFocus();
        _showError("Something went wrong. Please try again.");
      }
    }
  }

  // error snackbar
  void _showError(String message) {
    ScaffoldMessenger.of(context).removeCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.error_outline_rounded,
                color: Colors.white, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
        backgroundColor: const Color(0xDD3A1111),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  // build
  @override
  Widget build(BuildContext context) {
    final accent = context.watch<AppState>().accent;
    final dark = context.watch<AppState>().isDark;
    final size = MediaQuery.of(context).size;

    return Stack(
      children: [
        // solid backdrop – respects theme toggle
        Positioned.fill(
          child: Container(color: K.bg(dark)),
        ),

        // background – fully isolated from keyboard insets
        Positioned.fill(
          child: RepaintBoundary(
            child: GlowOrbs(
              colors: [
                const Color(0xFF667eea),
                accent,
                const Color(0xFFf093fb),
              ],
              opacity: 0.30,
            ),
          ),
        ),

        // foreground – resizes with keyboard
        Scaffold(
          backgroundColor: Colors.transparent,
          resizeToAvoidBottomInset: true,
          body: SafeArea(
            child: SingleChildScrollView(
              physics: const ClampingScrollPhysics(),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: size.height - 120),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(height: size.height * 0.1),

                      // logo
                      Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [accent, accent.withOpacity(0.6)],
                          ),
                          borderRadius: BorderRadius.circular(22),
                          boxShadow: [
                            BoxShadow(
                                color: accent.withOpacity(0.5),
                                blurRadius: 30,
                                offset: const Offset(0, 8)),
                          ],
                        ),
                        child: const Center(
                          child: Text('k',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 36,
                                  fontWeight: FontWeight.w800,
                                  fontStyle: FontStyle.italic)),
                        ),
                      ),

                      const SizedBox(height: 28),

                      // wordmark
                      ShaderMask(
                        shaderCallback: (b) => LinearGradient(
                          colors: [Colors.white, accent],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ).createShader(b),
                        child: const Text(
                          'keepsy',
                          style: TextStyle(
                              fontSize: 48,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                              letterSpacing: -2),
                        ),
                      ),

                      const SizedBox(height: 10),
                      const Text(
                        'Tagline for the app.',
                        style: TextStyle(
                            color: Color(0x99FFFFFF),
                            fontSize: 15,
                            fontWeight: FontWeight.w400),
                      ),

                      SizedBox(height: size.height * 0.06),

                      // email ↔ otp animated switch (snappy 200ms)
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 200),
                        switchInCurve: Curves.easeOutQuad,
                        switchOutCurve: Curves.easeInQuad,
                        transitionBuilder: (child, anim) => FadeTransition(
                          opacity: anim,
                          child: SlideTransition(
                            position: Tween<Offset>(
                                    begin: const Offset(0, 0.08),
                                    end: Offset.zero)
                                .animate(anim),
                            child: child,
                          ),
                        ),
                        child: _otpMode
                            ? _OtpRow(
                                key: const ValueKey('otp'),
                                ctrls: _otpCtrls,
                                foci: _otpFoci,
                                accent: accent,
                                onComplete: _handleContinue,
                              )
                            : _EmailField(
                                key: const ValueKey('email'),
                                ctrl: _emailCtrl,
                                focus: _emailFocus,
                                accent: accent,
                                onSubmit: _handleContinue,
                              ),
                      ),

                      const SizedBox(height: 16),

                      PrimaryButton(
                        label: _otpMode ? 'Verify & Sign In' : 'Continue',
                        loading: _loading,
                        onTap: _handleContinue,
                      ),

                      const SizedBox(height: 32),

                      // divider
                      Row(children: [
                        Expanded(
                            child: Container(
                                height: 0.5,
                                color: Colors.white.withOpacity(0.12))),
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 16),
                          child: Text('or continue with',
                              style: TextStyle(
                                  color: Color(0x55FFFFFF), fontSize: 13)),
                        ),
                        Expanded(
                            child: Container(
                                height: 0.5,
                                color: Colors.white.withOpacity(0.12))),
                      ]),

                      const SizedBox(height: 24),

                      // google – disabled
                      Opacity(
                        opacity: 0.45,
                        child: IgnorePointer(
                          child: Container(
                            height: 52,
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.08),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                  color: Colors.white.withOpacity(0.12)),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Image.asset('lib/assets/Google_logo.svg',
                                    height: 24),
                                const SizedBox(width: 12),
                                const Text('Continue with Google',
                                    style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 15,
                                        fontWeight: FontWeight.w500)),
                              ],
                            ),
                          ),
                        ),
                      ),

                      const SizedBox(height: 32),

                      Text(
                        'By continuing, you agree to our Terms & Privacy Policy',
                        style: TextStyle(
                            fontSize: 12,
                            color: Colors.white.withOpacity(0.3)),
                        textAlign: TextAlign.center,
                      ),

                      const SizedBox(height: 32),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// Email field

class _EmailField extends StatelessWidget {
  final TextEditingController ctrl;
  final FocusNode focus;
  final Color accent;
  final VoidCallback onSubmit;

  const _EmailField({
    super.key,
    required this.ctrl,
    required this.focus,
    required this.accent,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.07),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.12)),
      ),
      child: TextField(
        controller: ctrl,
        focusNode: focus,
        keyboardType: TextInputType.emailAddress,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => onSubmit(),
        style: const TextStyle(color: Colors.white, fontSize: 16),
        decoration: InputDecoration(
          hintText: 'Enter your email',
          hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
          border: InputBorder.none,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
          prefixIcon: Icon(Icons.mail_outline_rounded, color: accent, size: 20),
        ),
      ),
    );
  }
}

// OTP row

class _OtpRow extends StatelessWidget {
  final List<TextEditingController> ctrls;
  final List<FocusNode> foci;
  final Color accent;
  final VoidCallback onComplete;

  const _OtpRow({
    super.key,
    required this.ctrls,
    required this.foci,
    required this.accent,
    required this.onComplete,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('  Enter the code sent to your email',
            style: TextStyle(
                color: Colors.white.withOpacity(0.4), fontSize: 12)),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: List.generate(6, (i) {
            return SizedBox(
              width: 48,
              height: 56,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.07),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.white.withOpacity(0.12)),
                ),
                child: TextField(
                  controller: ctrls[i],
                  focusNode: foci[i],
                  maxLength: 1,
                  textAlign: TextAlign.center,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w700),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    counterText: '',
                  ),
                  onChanged: (v) {
                    if (v.isEmpty && i > 0) {
                      foci[i - 1].requestFocus();
                    } else if (v.isNotEmpty && i < 5) {
                      foci[i + 1].requestFocus();
                    } else if (v.isNotEmpty && i == 5) {
                      onComplete();
                    }
                  },
                ),
              ),
            );
          }),
        ),
      ],
    );
  }
}