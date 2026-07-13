import 'package:flutter/material.dart';

import 'package:keepsy/e2ee/identity_trust.dart';
import 'package:keepsy/ui/theme/app_theme.dart';

// the out of band comparison ritual. Deliberately says "Not verified"
// rather than anything reassuring until the user has actually read the digits
// back to the human : trust on first use cannot rule out a MITM who was there
// at first sight, and implying otherwise would be a lie
class SafetyNumberSheet extends StatelessWidget {
  final String displayName;
  final String digits;
  final TrustState state;
  final bool dark;
  final Color accent;
  final VoidCallback onVerify;
  // "that really was them re installing" : re pins the new key, still unverified
  final VoidCallback onAccept;

  const SafetyNumberSheet({
    super.key,
    required this.displayName,
    required this.digits,
    required this.state,
    required this.dark,
    required this.accent,
    required this.onVerify,
    required this.onAccept,
  });

  @override
  Widget build(BuildContext context) {
    final changed = state == TrustState.changed;
    final verified = state == TrustState.verified;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: K.borderCol(dark),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 18),
            if (changed) ...[
              _Banner(
                dark: dark,
                text: "$displayName's security key changed. If that wasn't a "
                    'new phone or a reinstall, someone may be intercepting '
                    'this album. Check with them directly.',
              ),
              const SizedBox(height: 16),
            ],
            Text(
              'Safety number with $displayName',
              style: TextStyle(
                color: K.t1(dark),
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            _StatusPill(state: state, dark: dark, accent: accent),
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
              decoration: BoxDecoration(
                color: K.cardCol(dark),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: K.borderCol(dark)),
              ),
              child: Text(
                digits,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: K.t1(dark),
                  fontSize: 19,
                  height: 1.7,
                  letterSpacing: 1.6,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'Call $displayName, or meet them, and read these digits to each '
              'other. If they match on both phones, no one is sitting in the '
              'middle of this album.',
              style: TextStyle(color: K.t2(dark), fontSize: 13, height: 1.45),
            ),
            const SizedBox(height: 20),
            if (!verified)
              FilledButton(
                onPressed: () {
                  Navigator.of(context).maybePop();
                  onVerify();
                },
                style: FilledButton.styleFrom(
                  backgroundColor: accent,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: const Text('They match : Mark as verified',
                    style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            if (changed) ...[
              const SizedBox(height: 8),
              TextButton(
                onPressed: () {
                  Navigator.of(context).maybePop();
                  onAccept();
                },
                child: Text(
                  "It's them : they got a new phone",
                  style: TextStyle(color: K.t2(dark), fontSize: 13),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final TrustState state;
  final bool dark;
  final Color accent;

  const _StatusPill(
      {required this.state, required this.dark, required this.accent});

  @override
  Widget build(BuildContext context) {
    final (label, color, icon) = switch (state) {
      TrustState.verified => ('Verified', accent, Icons.verified_user_outlined),
      TrustState.changed => (
          'Key changed',
          const Color(0xFFF87171),
          Icons.error_outline
        ),
      TrustState.unverified => (
          'Not verified',
          K.t3(dark),
          Icons.shield_outlined
        ),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 5),
        Text(label,
            style: TextStyle(
                color: color, fontSize: 12, fontWeight: FontWeight.w600)),
      ],
    );
  }
}

class _Banner extends StatelessWidget {
  final bool dark;
  final String text;

  const _Banner({required this.dark, required this.text});

  @override
  Widget build(BuildContext context) {
    const red = Color(0xFFF87171);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: red.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: red.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, size: 18, color: red),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: TextStyle(color: K.t1(dark), fontSize: 13, height: 1.4)),
          ),
        ],
      ),
    );
  }
}
