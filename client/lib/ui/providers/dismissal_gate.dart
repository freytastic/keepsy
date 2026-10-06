// Holds optimistic tiles until their confirmed records reach the album listing
class DismissalGate {
  final Set<String> _held = {};

  void hold(String batchId) => _held.add(batchId);
  bool get isEmpty => _held.isEmpty;
  bool isHolding(String batchId) => _held.contains(batchId);
  List<String> get held => List.unmodifiable(_held);

  // Entries omitted from doneByBatch stay held
  List<String> release({
    required Set<String> landedMediaIds,
    required Map<String, List<String>?> doneByBatch,
  }) {
    final ready = <String>[];
    for (final entry in doneByBatch.entries) {
      if (!_held.contains(entry.key)) continue;
      final done = entry.value;
      if (done != null && !done.every(landedMediaIds.contains)) continue;
      _held.remove(entry.key);
      ready.add(entry.key);
    }
    return ready;
  }
}
