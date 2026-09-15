import 'package:flutter/material.dart';
import 'package:keepsy/domain/account/account_deletion.dart';
import 'package:keepsy/ui/screens/account_deleted_screen.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';

enum _Phase { working, offline, stuck, unconfirmed }

// Server silence keeps the app blocked until the user chooses the next action
class AccountDeletionScreen extends StatefulWidget {
  final AccountDeletion deletion;
  final DeletionPlan? plan;
  final WidgetBuilder? onNotAccepted;

  const AccountDeletionScreen({
    super.key,
    required this.deletion,
    this.plan,
    this.onNotAccepted,
  });

  @override
  State<AccountDeletionScreen> createState() => _AccountDeletionScreenState();
}

class _AccountDeletionScreenState extends State<AccountDeletionScreen> {
  _Phase _phase = _Phase.working;

  @override
  void initState() {
    super.initState();
    final plan = widget.plan;
    _run(plan != null
        ? () => widget.deletion.confirm(plan)
        : () async =>
            await widget.deletion.resume() ?? DeletionResult.notAccepted);
  }

  Future<void> _run(Future<DeletionResult> Function() step) async {
    setState(() => _phase = _Phase.working);
    final nav = Navigator.of(context);
    try {
      final result = await step();
      if (!mounted) return;
      switch (result) {
        case DeletionResult.deleted:
          nav.pushAndRemoveUntil(
            MaterialPageRoute(builder: (_) => const AccountDeletedScreen()),
            (_) => false,
          );
        case DeletionResult.unconfirmed:
          setState(() => _phase = _Phase.unconfirmed);
        case DeletionResult.planChanged:
        case DeletionResult.notAccepted:
          final next = widget.onNotAccepted;
          if (next != null) {
            nav.pushReplacement(MaterialPageRoute(builder: next));
          } else {
            nav.pop(result);
          }
      }
    } on WipeIncomplete {
      if (mounted) setState(() => _phase = _Phase.stuck);
    } catch (_) {
      if (mounted) setState(() => _phase = _Phase.offline);
    }
  }

  Future<DeletionResult> _resume() async =>
      await widget.deletion.resume() ?? DeletionResult.notAccepted;

  @override
  Widget build(BuildContext context) {
    final (title, body) = switch (_phase) {
      _Phase.working => (
          'Deleting your account',
          'Keep Keepsy open. This finishes in a moment.',
        ),
      _Phase.offline => (
          "Couldn't reach Keepsy",
          'Your deletion may already be underway. Connect to the internet and '
              'try again.',
        ),
      _Phase.stuck => (
          "Couldn't finish clearing this phone",
          'Your account is deleted on our servers, but some data on this phone '
              'is still here. Try again to remove it.',
        ),
      _Phase.unconfirmed => (
          'Finish deleting your account?',
          "Keepsy hasn't confirmed your deletion yet. Continue to send it "
              'again, or keep your account.',
        ),
    };
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
                Text(title, style: Warm.h1),
                const SizedBox(height: Warm.headingToLead),
                Text(body, style: Warm.sub),
                const SizedBox(height: 32),
                ..._actions(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _actions() => switch (_phase) {
        _Phase.working => const [
            SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ],
        _Phase.offline || _Phase.stuck => [
            TextButton(
              onPressed: () => _run(_resume),
              child: const Text('Try again'),
            ),
          ],
        _Phase.unconfirmed => [
            TextButton(
              onPressed: () => _run(widget.deletion.continueDeleting),
              child: const Text('Continue deleting'),
            ),
            TextButton(
              onPressed: () => _run(widget.deletion.keepAccount),
              child: const Text('Keep my account'),
            ),
          ],
      };
}
