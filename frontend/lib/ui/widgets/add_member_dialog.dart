import 'package:flutter/material.dart';
import 'package:keepsy/data/api/api_error.dart';
import 'package:keepsy/e2ee/handle.dart';
import 'package:keepsy/e2ee/prekey_api.dart' show HandleNotFoundException;

// Normalizes a keepsy ID before handing it to the X3DH invite flow
class AddMemberDialog extends StatefulWidget {
  final Future<void> Function(String keepsyId) onInvite;
  const AddMemberDialog({super.key, required this.onInvite});

  @override
  State<AddMemberDialog> createState() => _AddMemberDialogState();
}

class _AddMemberDialogState extends State<AddMemberDialog> {
  final _controller = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final String handle;
    try {
      handle = normalizeHandle(_controller.text);
    } on FormatException {
      setState(() => _error = 'Enter a valid 8-character keepsy ID');
      return;
    }
    setState(() {
      _error = null;
      _busy = true;
    });
    try {
      await widget.onInvite(handle);
      if (mounted) Navigator.of(context).pop(true);
    } on HandleNotFoundException {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'No keepsy user with that ID';
        });
      }
    } on ApiError catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.code == 'E_EPOCH_PENDING_ROTATION'
              ? "This album's keys are updating. Invite them once that finishes."
              : 'Could not send invite. Try again.';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Could not send invite. Try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add member'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Enter the keepsy ID they shared with you.'),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            enabled: !_busy,
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(
              labelText: 'keepsy ID',
              hintText: 'XXXX-XXXX',
              errorText: _error,
            ),
            onSubmitted: (_) {
              if (!_busy) _submit();
            },
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Invite'),
        ),
      ],
    );
  }
}
