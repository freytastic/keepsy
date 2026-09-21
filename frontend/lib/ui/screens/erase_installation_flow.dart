import 'package:flutter/material.dart';

import 'package:keepsy/domain/account/account_deletion.dart' show TerminalWipe;

import 'account_conflict_screens.dart';

// Shared confirmation path for every irreversible local wipe
Future<void> confirmAndEraseInstallation(
  BuildContext context,
  TerminalWipe wipe,
) async {
  final navigator = Navigator.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Erase this Keepsy?'),
      content: const Text(
          'Every photo and key the other account kept on this phone is '
          'removed. Their account itself is not touched, and this cannot be '
          'undone.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Erase'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;

  // The screen reports wipe failure and owns retry
  await navigator.pushAndRemoveUntil(
    MaterialPageRoute<void>(
      builder: (_) => EraseInstallationScreen(wipe: wipe.run),
    ),
    (_) => false,
  );
}
