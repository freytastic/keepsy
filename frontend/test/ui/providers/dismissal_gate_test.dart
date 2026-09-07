import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/ui/providers/dismissal_gate.dart';

void main() {
  late DismissalGate gate;
  setUp(() => gate = DismissalGate());

  test('a later successful refresh releases what an earlier failure held', () {
    gate.hold('b1');
    gate.release(landedMediaIds: const {}, doneByBatch: const {
      'b1': ['m1']
    });
    expect(gate.isHolding('b1'), isTrue);

    final ready = gate.release(landedMediaIds: const {
      'm1'
    }, doneByBatch: const {
      'b1': ['m1']
    });
    expect(ready, ['b1']);
  });

  test('a batch that produced nothing releases immediately', () {
    gate.hold('b1');
    final ready = gate.release(
        landedMediaIds: const {}, doneByBatch: const {'b1': <String>[]});
    expect(ready, ['b1']);
  });

  test('a batch the queue no longer knows about is not held forever', () {
    gate.hold('gone');
    final ready = gate
        .release(landedMediaIds: const {}, doneByBatch: const {'gone': null});
    expect(ready, ['gone']);
    expect(gate.isEmpty, isTrue);
  });

  test('a batch left out of the report stays held', () {
    gate.hold('b1');
    final ready = gate.release(landedMediaIds: const {}, doneByBatch: const {});
    expect(ready, isEmpty);
    expect(gate.isHolding('b1'), isTrue);
  });

  test('tracks batches independently', () {
    gate.hold('b1');
    gate.hold('b2');
    final ready = gate.release(landedMediaIds: const {
      'm1'
    }, doneByBatch: const {
      'b1': ['m1'],
      'b2': ['m2'],
    });
    expect(ready, ['b1']);
    expect(gate.isHolding('b2'), isTrue);
  });
}
