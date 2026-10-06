import 'package:flutter/material.dart';

typedef SharedAlbumRow = ({String name, int members});

// Deleting an account deletes the albums it administers for everyone in them,
// so that must be confirmed on its own and never folded into generic copy
class DeleteSharedAlbumsDialog extends StatefulWidget {
  final List<SharedAlbumRow> albums;
  // The plan changed after the user last reviewed it
  final bool changed;

  const DeleteSharedAlbumsDialog({
    super.key,
    required this.albums,
    this.changed = false,
  });

  @override
  State<DeleteSharedAlbumsDialog> createState() =>
      _DeleteSharedAlbumsDialogState();
}

class _DeleteSharedAlbumsDialogState extends State<DeleteSharedAlbumsDialog> {
  bool _understood = false;

  @override
  Widget build(BuildContext context) {
    final n = widget.albums.length;
    return AlertDialog(
      title: Text(n == 1
          ? 'You administer 1 shared album'
          : 'You administer $n shared albums'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.changed)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text('Your albums changed. Review them again.'),
              ),
            Text(n == 1
                ? 'Deleting your account will permanently remove this album '
                    'for all members.'
                : 'Deleting your account will permanently remove these albums '
                    'for all members.'),
            const SizedBox(height: 12),
            for (final a in widget.albums)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                    '${a.name} · ${a.members} ${a.members == 1 ? 'member' : 'members'}'),
              ),
            const SizedBox(height: 8),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _understood,
              onChanged: (v) => setState(() => _understood = v ?? false),
              title: Text(n == 1
                  ? 'Delete it for everyone'
                  : 'Delete them for everyone'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _understood ? () => Navigator.of(context).pop(true) : null,
          child: const Text('Delete everything'),
        ),
      ],
    );
  }
}
