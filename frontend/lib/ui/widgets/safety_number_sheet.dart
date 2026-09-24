import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:keepsy/e2ee/identity_trust.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';
import 'package:keepsy/ui/widgets/warm_button.dart';

// the out of band comparison ritual. Never says anything reassuring until the
// user has actually read the digits back to the human : trust on first use
// cannot rule out a MITM who was there at first sight
class SafetyNumberSheet extends StatefulWidget {
  final String displayName;
  final String digits;
  final TrustState state;
  final String? subtitle;
  final Widget? face;
  // Fired only after the user confirms every digit. There is no accept-without
  // comparing path because verification also grants signer authority
  final VoidCallback onVerify;

  const SafetyNumberSheet({
    super.key,
    required this.displayName,
    required this.digits,
    required this.state,
    required this.onVerify,
    this.subtitle,
    this.face,
  });

  @override
  State<SafetyNumberSheet> createState() => _SafetyNumberSheetState();
}

// Seconds for the reels: shared spin, then one digit locking after another
const double _reelBase = 0.35;
const double _reelStep = 0.025;
const double _reelSettle = 0.35;

class _SafetyNumberSheetState extends State<SafetyNumberSheet>
    with SingleTickerProviderStateMixin {
  late final List<String> _groups =
      widget.digits.split(RegExp(r'\s+')).where((g) => g.isNotEmpty).toList();
  late final int _count = _groups.fold(0, (n, g) => n + g.length);
  late final double _total = _reelBase + _count * _reelStep + _reelSettle;
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: (_total * 1000).round()),
  );
  bool _why = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_spin.isAnimating || _spin.isCompleted) return;
    // The number rolls in on open and lands on the real digits
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _spin.value = 1;
    } else {
      _spin.forward();
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  // Verification is durable across shared albums and may authorize a blocked
  // signer, so require a deliberate confirmation
  Future<void> _confirmThenVerify() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Warm.ground,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: Text('Did every digit match?', style: Warm.sheetTitle),
        content: Text(
          'Only confirm if all ${_count > 0 ? _count : 30} digits match '
          "exactly on both phones. This can't be undone, and it tells Keepsy "
          'to trust this key from now on.',
          style: Warm.pageSoft.copyWith(color: Warm.inkSoft),
        ),
        actionsAlignment: MainAxisAlignment.end,
        actions: [
          WarmTextButton(
            label: "They didn't",
            onTap: () => Navigator.of(ctx).pop(false),
          ),
          WarmButton(
            label: 'They matched',
            small: true,
            onTap: () => Navigator.of(ctx).pop(true),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    Navigator.of(context).maybePop();
    widget.onVerify();
  }

  @override
  Widget build(BuildContext context) {
    final changed = widget.state == TrustState.changed;
    final verified = widget.state == TrustState.verified;
    final name = widget.displayName;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(26, 12, 26, 22),
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
            Row(
              children: [
                if (widget.face != null) ...[
                  widget.face!,
                  const SizedBox(width: 13),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name,
                          style: Warm.sheetTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      if (widget.subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(widget.subtitle!,
                            style: Warm.rowValue,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Semantics(
              label: widget.digits,
              excludeSemantics: true,
              child: _Reels(
                groups: _groups,
                spin: _spin,
                total: _total,
                settled: verified,
              ),
            ),
            const SizedBox(height: 18),
            Center(
              child: verified
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.check_rounded,
                            size: 17, color: Warm.ink),
                        const SizedBox(width: 6),
                        Text('Verified', style: Warm.pageSubhead),
                      ],
                    )
                  : Text(
                      changed
                          ? "$name's security key changed. Keepsy stopped "
                              'trusting it until you compare these numbers '
                              'in person.'
                          : "Compare this with $name's screen, in person.",
                      textAlign: TextAlign.center,
                      style: Warm.acCardBody
                          .copyWith(color: changed ? Warm.warn : Warm.inkSoft),
                    ),
            ),
            AnimatedSize(
              duration: Warm.quick,
              curve: Warm.easeOut,
              child: _why
                  ? Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        'These numbers come from keys only your two phones '
                        'hold. If they match, nobody is in between you. '
                        "Keepsy isn't told when you check.",
                        textAlign: TextAlign.center,
                        style: Warm.pageSoft,
                      ),
                    )
                  : const SizedBox(width: double.infinity),
            ),
            if (!verified) ...[
              const SizedBox(height: 22),
              AnimatedBuilder(
                animation: _spin,
                builder: (_, __) => WarmButton(
                  label: 'They match',
                  onTap: _spin.isCompleted ? _confirmThenVerify : null,
                ),
              ),
              const SizedBox(height: 6),
              Center(
                child: WarmTextButton(
                  label: _why ? 'Hide' : 'Why compare?',
                  onTap: () => setState(() => _why = !_why),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// Each digit spins on its own reel and always lands back on itself
class _Reels extends StatelessWidget {
  final List<String> groups;
  final Animation<double> spin;
  // Seconds the whole spin takes
  final double total;
  final bool settled;

  const _Reels({
    required this.groups,
    required this.spin,
    required this.total,
    required this.settled,
  });

  static const double _cell = 13.5;
  static const double _line = 27;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontFamily: 'monospace',
      fontSize: 19,
      height: _line / 19,
      fontWeight: FontWeight.w600,
      color: settled ? Warm.inkSoft : Warm.ink,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    var index = 0;
    final cells = <Widget>[];
    for (final g in groups) {
      final reels = <Widget>[];
      for (final ch in g.split('')) {
        final stop = (_reelBase + index * _reelStep + _reelSettle) / total;
        reels.add(_Reel(
          digit: ch,
          seed: index,
          stop: stop.clamp(0.05, 1.0),
          spin: spin,
          style: style,
        ));
        index++;
      }
      cells.add(Row(mainAxisSize: MainAxisSize.min, children: reels));
    }
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 22,
      runSpacing: 8,
      children: cells,
    );
  }
}

class _Reel extends StatelessWidget {
  final String digit;
  final int seed;
  // Fraction of the whole spin at which this reel locks
  final double stop;
  final Animation<double> spin;
  final TextStyle style;

  const _Reel({
    required this.digit,
    required this.seed,
    required this.stop,
    required this.spin,
    required this.style,
  });

  static const _rate = 22;

  @override
  Widget build(BuildContext context) {
    final rnd = math.Random(seed * 7919 + digit.codeUnitAt(0));
    final spins = math.max(6, (stop * _rate * 1.6).round());
    final strip = [
      digit,
      for (var i = 0; i < spins; i++) '${rnd.nextInt(10)}',
      digit,
    ];
    const cell = _Reels._cell;
    const line = _Reels._line;
    return SizedBox(
      width: cell,
      height: line,
      child: ClipRect(
        child: AnimatedBuilder(
          animation: spin,
          builder: (_, __) {
            final t = (spin.value / stop).clamp(0.0, 1.0);
            if (t >= 1) return Center(child: Text(digit, style: style));
            final y =
                -(strip.length - 1) * line * Curves.easeOutCubic.transform(t);
            return OverflowBox(
              alignment: Alignment.topCenter,
              maxHeight: double.infinity,
              child: Transform.translate(
                offset: Offset(0, y),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final d in strip)
                      SizedBox(
                          height: line,
                          child: Center(child: Text(d, style: style))),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
