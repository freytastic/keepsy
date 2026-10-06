import 'dart:collection';

class _Sample {
  final DateTime at;
  final int bytes;
  const _Sample(this.at, this.bytes);
}

// Sliding wire rate that returns null when no recent bytes are moving
class RateEstimator {
  final Duration window;
  final Duration minSpan;
  final Queue<_Sample> _samples = Queue<_Sample>();
  int _bytesInWindow = 0;

  RateEstimator({
    this.window = const Duration(seconds: 5),
    this.minSpan = const Duration(milliseconds: 300),
  });

  void reset() {
    _samples.clear();
    _bytesInWindow = 0;
  }

  void add(int deltaBytes, DateTime now) {
    if (deltaBytes <= 0) return;
    _samples.addLast(_Sample(now, deltaBytes));
    _bytesInWindow += deltaBytes;
    _trim(now);
  }

  void _trim(DateTime now) {
    final cutoff = now.subtract(window);
    while (_samples.isNotEmpty && _samples.first.at.isBefore(cutoff)) {
      _bytesInWindow -= _samples.removeFirst().bytes;
    }
  }

  double? bytesPerSecond(DateTime now) {
    _trim(now);
    if (_samples.isEmpty) return null;
    final span = now.difference(_samples.first.at);
    if (span < minSpan) return null;
    final seconds = span.inMicroseconds / Duration.microsecondsPerSecond;
    if (seconds <= 0) return null;
    return _bytesInWindow / seconds;
  }
}

// Uses observed per photo wall time, including preparation
class EtaEstimator {
  final double alpha;
  double? _meanSeconds;

  EtaEstimator({this.alpha = 0.4});

  bool get hasSample => _meanSeconds != null;

  void addCompleted(Duration wallTime) {
    final seconds = wallTime.inMicroseconds / Duration.microsecondsPerSecond;
    final mean = _meanSeconds;
    _meanSeconds = mean == null ? seconds : mean + alpha * (seconds - mean);
  }

  // Remaining includes the active item
  Duration? estimate({
    required int remaining,
    Duration activeElapsed = Duration.zero,
  }) {
    final mean = _meanSeconds;
    if (mean == null || remaining <= 0) return null;
    final seconds = mean * remaining -
        activeElapsed.inMicroseconds / Duration.microsecondsPerSecond;
    return Duration(
        microseconds: seconds <= 0
            ? 0
            : (seconds * Duration.microsecondsPerSecond).round());
  }
}
