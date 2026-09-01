import 'package:flutter/material.dart';

import 'package:keepsy/e2ee/identity_trust.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';

// the out of band comparison ritual. Deliberately says "Not verified"
// rather than anything reassuring until the user has actually read the digits
// back to the human : trust on first use cannot rule out a MITM who was there
// at first sight, and implying otherwise would be a lie
class SafetyNumberSheet extends StatelessWidget {
  final String displayName;
  final String digits;
  final TrustState state;
  // Fired only after the user confirms every digit. There is no accept-without
  // comparing path because verification also grants signer authority
  final VoidCallback onVerify;

  const SafetyNumberSheet({
    super.key,
    required this.displayName,
    required this.digits,
    required this.state,
    required this.onVerify,
  });

  // Verification is durable across shared albums and may authorize a blocked
  // signer, so require a deliberate confirmation
  Future<void> _confirmThenVerify(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Did every digit match?'),
        content: const Text(
          'Only confirm if all 30 digits match exactly on both phones. This '
          "can't be undone, and it tells Keepsy to trust this key from now on.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text("They didn't"),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('They matched'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    Navigator.of(context).maybePop();
    onVerify();
  }

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
                  color: Warm.inkGhost,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 18),
            if (changed) ...[
              _Banner(
                text: "$displayName's security key changed. Keepsy has stopped "
                    'trusting it. Read the digits below to them directly : '
                    'that is the only way to tell a real change from someone '
                    'intercepting this album.',
              ),
              const SizedBox(height: 16),
            ],
            Text(
              'Safety number with $displayName',
              style: TextStyle(
                color: Warm.ink,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            _StatusPill(state: state),
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
              decoration: BoxDecoration(
                color: Warm.stoneBottom,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Warm.inkGhost),
              ),
              child: Text(
                digits,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Warm.ink,
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
              style: const TextStyle(
                  color: Warm.inkSoft, fontSize: 13, height: 1.45),
            ),
            const SizedBox(height: 20),
            if (!verified)
              FilledButton(
                onPressed: () => _confirmThenVerify(context),
                style: FilledButton.styleFrom(
                  backgroundColor: Warm.ctaTop,
                  foregroundColor: Warm.ctaInk,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: const Text('They match : Mark as verified',
                    style: TextStyle(fontWeight: FontWeight.w700)),
              ),
          ],
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final TrustState state;

  const _StatusPill({required this.state});

  @override
  Widget build(BuildContext context) {
    final (label, color, icon) = switch (state) {
      TrustState.verified => (
          'Verified',
          Warm.ctaTop,
          Icons.verified_user_outlined
        ),
      TrustState.changed => (
          'Key changed',
          const Color(0xFFF87171),
          Icons.error_outline
        ),
      TrustState.unverified => (
          'Not verified',
          Warm.inkFaint,
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
  final String text;

  const _Banner({required this.text});

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
                style: const TextStyle(
                    color: Warm.ink, fontSize: 13, height: 1.4)),
          ),
        ],
      ),
    );
  }
}
