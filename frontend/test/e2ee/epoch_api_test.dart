import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/e2ee/epoch_api.dart';

class _Json implements EpochJsonClient {
  final Map<String, dynamic>? body;
  _Json(this.body);
  @override
  Future<Map<String, dynamic>?> getJsonOrNotFound(String path) async => body;
  @override
  Future<void> postJson(String path, Map<String, dynamic> body) async {}
}

Map<String, dynamic> _epoch(Map<String, dynamic> extra) => {
      'current_epoch': 3,
      'started_at': '2026-09-12T10:00:00Z',
      ...extra,
    };

void main() {
  test('reads the explicit rotation flag', () async {
    final cur = await HttpEpochApi(_Json(_epoch({'rotation_required': true})))
        .getCurrentEpoch('a1');
    expect(cur!.rotationRequired, isTrue);
  });

  test('falls back to the legacy pending_rotation name', () async {
    final cur = await HttpEpochApi(_Json(_epoch({'pending_rotation': true})))
        .getCurrentEpoch('a1');
    expect(cur!.rotationRequired, isTrue);
  });

  test('the explicit flag wins over the legacy name', () async {
    final cur = await HttpEpochApi(_Json(
            _epoch({'rotation_required': false, 'pending_rotation': true})))
        .getCurrentEpoch('a1');
    expect(cur!.rotationRequired, isFalse);
  });

  test('an album without either field owes nothing', () async {
    final cur = await HttpEpochApi(_Json(_epoch({}))).getCurrentEpoch('a1');
    expect(cur!.rotationRequired, isFalse);
  });
}
