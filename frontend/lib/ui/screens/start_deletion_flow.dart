import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:keepsy/domain/account/account_deletion.dart';
import 'package:keepsy/domain/account/deletion_launch.dart';
import 'package:keepsy/ui/providers/app_state.dart';
import 'package:keepsy/ui/widgets/delete_shared_albums_dialog.dart';

import 'account_deletion_screen.dart';

// Shared UI path that always opens AccountDeletionScreen with a plan
Future<void> startDeletionFlow(BuildContext context) async {
  final AccountDeletion deletion;
  try {
    deletion = context.read<AccountDeletion>();
  } catch (_) {
    return;
  }
  final state = context.read<AppState>();
  final navigator = Navigator.of(context, rootNavigator: true);
  final messenger = ScaffoldMessenger.of(context);

  try {
    await launchAccountDeletion(
      deletion: deletion,
      confirmShared: (shared) async =>
          await showDialog<bool>(
            context: navigator.context,
            builder: (_) => DeleteSharedAlbumsDialog(
              changed: false,
              albums: [
                for (final a in shared)
                  (
                    name: state.albumDisplayName(a.albumId) ?? 'Untitled album',
                    members: a.activeMemberCount,
                  ),
              ],
            ),
          ) ==
          true,
      openScreen: (plan) => navigator.push<DeletionResult>(
        MaterialPageRoute(
          builder: (_) => AccountDeletionScreen(deletion: deletion, plan: plan),
        ),
      ),
    );
  } catch (_) {
    messenger.showSnackBar(const SnackBar(
      content: Text('Could not delete your account. Try again.'),
      behavior: SnackBarBehavior.floating,
    ));
  }
}
