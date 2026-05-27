import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/e2ee/invite_api.dart';
import 'package:keepsy/e2ee/prekey_api.dart';

class _FakeInviteJsonClient implements InviteJsonClient {
  String? path;
  Map<String, dynamic>? body;
  Map<String, dynamic> result = {};

  @override
  Future<Map<String, dynamic>> postJsonForResult(
      String p, Map<String, dynamic> b) async {
    path = p;
    body = b;
    return result;
  }

  @override
  Future<void> postJson(String p, Map<String, dynamic> b) async {
    path = p;
    body = b;
  }
}

class _Fake404PrekeyClient implements PrekeyJsonClient {
  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    throw const PrekeyApiException(
        code: 'E_NOT_FOUND', message: 'no', httpStatus: 404);
  }

  @override
  Future<void> postJson(String path, Map<String, dynamic> body) async {}
  @override
  Future<void> putJson(String path, Map<String, dynamic> body) async {}
}

void main() {
  test('deliverExistingUser encodes the §5.3 wire shape', () async {
    final fake = _FakeInviteJsonClient()
      ..result = {
        'member_token': base64Encode(Uint8List.fromList(List.filled(32, 7)))
      };
    final token = await HttpInviteApi(fake).deliverExistingUser(
      albumId: 'alb-1',
      targetKeepsyId: 'K7F29QXM',
      ekPub: Uint8List(32),
      opkIdx: 3,
      envelopes: [
        DeliverEnvelope(
            epoch: 0,
            wrapNonce: Uint8List(12),
            wrapTagCt: Uint8List(48),
            senderSig: Uint8List(64)),
        DeliverEnvelope(
            epoch: 1,
            wrapNonce: Uint8List(12),
            wrapTagCt: Uint8List(48),
            senderSig: Uint8List(64)),
      ],
    );

    expect(fake.path, '/albums/alb-1/invites/existing-user');
    expect(fake.body!['target_keepsy_id'], 'K7F29QXM');
    expect(fake.body!['opk_idx_used'], 3);
    final envs = fake.body!['envelopes'] as List;
    expect(envs.length, 2);
    final e0 = envs[0] as Map<String, dynamic>;
    expect(e0['epoch'], 0);
    expect(e0.keys.toSet(),
        {'epoch', 'wrap_nonce', 'wrap_tag_ct', 'sender_sig'});
    expect(token.length, 32);
    expect(token[0], 7);
  });

  test('postJoinComplete encodes the §5.5 wire shape', () async {
    final fake = _FakeInviteJsonClient();
    await HttpInviteApi(fake).postJoinComplete(
        albumId: 'alb-2', epoch: 5, ekPubAdmin: Uint8List(32), sig: Uint8List(64));

    expect(fake.path, '/albums/alb-2/joins');
    expect(fake.body!['epoch'], 5);
    expect(fake.body!.keys.toSet(), {'epoch', 'ek_pub_admin', 'sig'});
  });

  test('fetchPrekeyBundleByHandle maps 404 to HandleNotFoundException', () {
    final api = HttpPrekeyApi(_Fake404PrekeyClient());
    expect(() => api.fetchPrekeyBundleByHandle('K7F29QXM'),
        throwsA(isA<HandleNotFoundException>()));
  });
}
