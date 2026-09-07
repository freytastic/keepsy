import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/domain/upload/rate_estimator.dart';

void main() {
  group('RateEstimator', () {
    late DateTime t;
    setUp(() => t = DateTime.utc(2026, 9, 7));

    test('reports nothing until the window is wide enough to mean anything',
        () {
      final r = RateEstimator();
      r.add(1000, t);
      expect(
          r.bytesPerSecond(t.add(const Duration(milliseconds: 100))), isNull);
    });

    test('averages bytes over the elapsed span', () {
      final r = RateEstimator();
      for (var i = 1; i <= 4; i++) {
        r.add(1000, t.add(Duration(milliseconds: 250 * i)));
      }
      final rate = r.bytesPerSecond(t.add(const Duration(seconds: 1)))!;
      expect(rate, closeTo(4000 / 0.75, 1));
    });

    test('drops samples that age out of the window', () {
      final r = RateEstimator(window: const Duration(seconds: 2));
      r.add(5000, t);
      final later = t.add(const Duration(seconds: 5));
      expect(r.bytesPerSecond(later), isNull);
    });

    test('reset clears the reading so a retry does not inherit it', () {
      final r = RateEstimator();
      r.add(1000, t);
      r.add(1000, t.add(const Duration(seconds: 1)));
      expect(r.bytesPerSecond(t.add(const Duration(seconds: 1))), isNotNull);
      r.reset();
      expect(r.bytesPerSecond(t.add(const Duration(seconds: 1))), isNull);
    });
  });

  group('EtaEstimator', () {
    test('has no estimate before the first photo lands', () {
      expect(EtaEstimator().estimate(remaining: 5), isNull);
    });

    test('projects remaining photos from observed wall time', () {
      final e = EtaEstimator();
      e.addCompleted(const Duration(seconds: 4));
      expect(e.estimate(remaining: 3), const Duration(seconds: 12));
    });

    test('subtracts what the active photo has already spent', () {
      final e = EtaEstimator();
      e.addCompleted(const Duration(seconds: 4));
      expect(
          e.estimate(remaining: 2, activeElapsed: const Duration(seconds: 3)),
          const Duration(seconds: 5));
    });

    test('never goes negative when a photo runs long', () {
      final e = EtaEstimator();
      e.addCompleted(const Duration(seconds: 2));
      expect(
          e.estimate(remaining: 1, activeElapsed: const Duration(seconds: 30)),
          Duration.zero);
    });

    test('weights recent photos more than the first one', () {
      final e = EtaEstimator(alpha: 0.5);
      e.addCompleted(const Duration(seconds: 10));
      e.addCompleted(const Duration(seconds: 2));
      expect(e.estimate(remaining: 1), const Duration(seconds: 6));
    });
  });
}
