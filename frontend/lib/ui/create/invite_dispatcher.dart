typedef SendInvite = Future<void> Function(String miuchioId);

// Sends invites sequentially after epoch 0 is installed
class InviteDispatcher {
  final SendInvite _send;

  const InviteDispatcher(this._send);

  // Returns failures without aborting the batch
  Future<int> sendAll(List<String> miuchioIds) async {
    var failed = 0;
    for (final id in miuchioIds) {
      try {
        await _send(id);
      } catch (_) {
        failed++;
      }
    }
    return failed;
  }
}
