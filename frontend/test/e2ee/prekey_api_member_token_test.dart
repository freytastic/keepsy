import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/e2ee/prekey_api.dart';

class _FakeJsonClient implements PrekeyJsonClient {
  String? lastGetPath;
  final Map<String, dynamic> Function() body;
  _FakeJsonClient(this.body);

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    lastGetPath = path;
    return body();
  }

  @override
  Future<void> postJson(String path, Map<String, dynamic> b) async =>
      throw UnimplementedError();
  @override
  Future<void> putJson(String path, Map<String, dynamic> b) async =>
      throw UnimplementedError();
}

Map<String, dynamic> _bundleJson(String userId) => {
      'user_id': userId,
      'ik_pub': base64Encode(List<int>.filled(32, 1)),
      'lk_pub': base64Encode(List<int>.filled(32, 2)),
      'spk_pub': base64Encode(List<int>.filled(32, 3)),
      'spk_sig': base64Encode(List<int>.filled(64, 4)),
      'spk_ts': 1234567890,
    };

void main() {
  test('fetchPrekeyBundleByMemberToken puts an unpadded url-safe token in path',
      () async {
    // All-0xFF token: its std base64 is all '/' with '=' padding, so if the
    // client used std base64 the path would contain '/' (breaking routing) and
    // '='. url safe no pad must contain neither
    final token = Uint8List.fromList(List<int>.filled(32, 0xFF));
    final client = _FakeJsonClient(() => _bundleJson('ignored'));
    final api = HttpPrekeyApi(client);

    await api.fetchPrekeyBundleByMemberToken('album-uuid-1', token);

    final path = client.lastGetPath!;
    expect(path, startsWith('/albums/album-uuid-1/members/'));
    expect(path, endsWith('/prekey-bundle'));
    final seg = path.substring(
      '/albums/album-uuid-1/members/'.length,
      path.length - '/prekey-bundle'.length,
    );
    expect(seg.contains('+'), isFalse, reason: 'std base64 + leaked into path');
    expect(seg.contains('/'), isFalse, reason: 'std base64 / leaked into path');
    expect(seg.contains('='), isFalse, reason: 'padding leaked into path');
    expect(seg, base64Url.encode(token).replaceAll('=', ''));
  });

  test('fetchPrekeyBundleByMemberToken maps 404 to MemberBundleNotFound',
      () async {
    final client = _FakeJsonClient(() => throw const PrekeyApiException(
        code: 'E_NOT_FOUND', message: 'no such member', httpStatus: 404));
    final api = HttpPrekeyApi(client);
    await expectLater(
      api.fetchPrekeyBundleByMemberToken('a', Uint8List(32)),
      throwsA(isA<MemberBundleNotFoundException>()),
    );
  });
}
