typedef SendInvite = Future<void> Function(String keepsyId);

// Sends invites sequentially after epoch 0 is installed
class InviteDispatcher {
  final SendInvite _send;

  const InviteDispatcher(this._send);

  // Returns failures without aborting the batch
  Future<int> sendAll(List<String> keepsyIds) async {
    var failed = 0;
    for (final id in keepsyIds) {
      try {
        await _send(id);
      } catch (_) {
        failed++;
      }
    }
    return failed;
  }
}
