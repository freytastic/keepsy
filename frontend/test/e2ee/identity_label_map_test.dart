import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/e2ee/identity_label_map.dart';

class _FakeKv implements IdentityKv {
  final Map<String, String> store = {};

  @override
  Future<String?> read(String key) async => store[key];

  @override
  Future<void> write(String key, String value) async {
    store[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    store.remove(key);
  }
}

void main() {
  group('IdentityLabelMap', () {
    test('round-trips through a fresh instance backed by the same KV',
        () async {
      final kv = _FakeKv();

      final a = IdentityLabelMap(kv: kv);
      await a.load();
      await a.set(kLabelIK, 'h-ik');
      await a.set('${kLabelOpkPrefix}3', 'h-opk-3');
      await a.setSpkTs(1714838400);

      // Fresh instance = app restart : must read what me wrote
      final b = IdentityLabelMap(kv: kv);
      await b.load();
      expect(b.handleId(kLabelIK), 'h-ik');
      expect(b.handleId('${kLabelOpkPrefix}3'), 'h-opk-3');
      expect(await b.getSpkTs(), 1714838400);
    });

    test('labelsWithPrefix returns only matching keys', () async {
      final kv = _FakeKv();
      final m = IdentityLabelMap(kv: kv);
      await m.load();
      await m.set(kLabelIK, 'h-ik');
      await m.set('${kLabelOpkPrefix}0', 'h0');
      await m.set('${kLabelOpkPrefix}1', 'h1');
      await m.set('${kLabelOpkPrefix}2', 'h2');
      final opks = m.labelsWithPrefix(kLabelOpkPrefix);
      expect(opks.length, 3);
      expect(opks.toSet(), {
        '${kLabelOpkPrefix}0',
        '${kLabelOpkPrefix}1',
        '${kLabelOpkPrefix}2'
      });
    });

    test('handleId before load throws', () {
      final m = IdentityLabelMap(kv: _FakeKv());
      expect(() => m.handleId(kLabelIK), throwsStateError);
    });
  });
}
