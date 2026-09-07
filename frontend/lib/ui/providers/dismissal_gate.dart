// Holds optimistic tiles until their confirmed records reach the album listing
class DismissalGate {
  final Set<String> _held = {};

  void hold(String batchId) => _held.add(batchId);
  bool get isEmpty => _held.isEmpty;
  bool isHolding(String batchId) => _held.contains(batchId);
  List<String> get held => List.unmodifiable(_held);

  // Null means the queue no longer owns the batch
  List<String> release({
    required Set<String> landedMediaIds,
    required Map<String, List<String>?> doneByBatch,
  }) {
    final ready = <String>[];
    for (final batchId in _held.toList()) {
      final done = doneByBatch[batchId];
      if (done == null) {
        _held.remove(batchId);
        ready.add(batchId);
        continue;
      }
      if (!done.every(landedMediaIds.contains)) continue;
      _held.remove(batchId);
      ready.add(batchId);
    }
    return ready;
  }
}
