import 'dart:convert';
import 'dart:typed_data';

// Wire wrapper for the §6.1/§6.3 invite endpoints. Mirrors HttpPrekeyApi /
// HttpEpochApi: the abstract API + HTTP impl live in lib/e2ee/, depending only
// on a thin InviteJsonClient port the composition root wires to ApiClient

// DeliverEnvelope : one per epoch MK wrap for the invitee. wrapNonce(12) +
// wrapTagCt(48) are the §4.2 blob split (server stores them separately)
// senderSig is Ed25519(IK_priv_admin, SHA256(album_id ‖ u32_be(epoch) ‖ wrap_blob))
class DeliverEnvelope {
  final int epoch;
  final Uint8List wrapNonce;
  final Uint8List wrapTagCt;
  final Uint8List senderSig;
  const DeliverEnvelope({
    required this.epoch,
    required this.wrapNonce,
    required this.wrapTagCt,
    required this.senderSig,
  });
}

abstract class InviteApi {
  // POST /albums/{id}/invites/existing-user. Returns the new member_token bytes
  Future<Uint8List> deliverExistingUser({
    required String albumId,
    required String targetKeepsyId,
    required Uint8List ekPub,
    int? opkIdx,
    required List<DeliverEnvelope> envelopes,
  });

  // POST /albums/{id}/joins. Signed receipt that the caller installed 'epoch'
  Future<void> postJoinComplete({
    required String albumId,
    required int epoch,
    required Uint8List ekPubAdmin,
    required Uint8List sig,
  });
}

abstract class InviteJsonClient {
  // POST returning the decoded JSON response body (deliver → {member_token})
  Future<Map<String, dynamic>> postJsonForResult(
      String path, Map<String, dynamic> body);
  // POST with no response body (join → 204)
  Future<void> postJson(String path, Map<String, dynamic> body);
}

class HttpInviteApi implements InviteApi {
  final InviteJsonClient _client;
  HttpInviteApi(this._client);

  @override
  Future<Uint8List> deliverExistingUser({
    required String albumId,
    required String targetKeepsyId,
    required Uint8List ekPub,
    int? opkIdx,
    required List<DeliverEnvelope> envelopes,
  }) async {
    final body = await _client
        .postJsonForResult('/albums/$albumId/invites/existing-user', {
      'target_keepsy_id': targetKeepsyId,
      'ek_pub': base64Encode(ekPub),
      'opk_idx_used': opkIdx,
      'envelopes': [
        for (final e in envelopes)
          {
            'epoch': e.epoch,
            'wrap_nonce': base64Encode(e.wrapNonce),
            'wrap_tag_ct': base64Encode(e.wrapTagCt),
            'sender_sig': base64Encode(e.senderSig),
          },
      ],
    });
    return base64Decode(body['member_token'] as String);
  }

  @override
  Future<void> postJoinComplete({
    required String albumId,
    required int epoch,
    required Uint8List ekPubAdmin,
    required Uint8List sig,
  }) {
    return _client.postJson('/albums/$albumId/joins', {
      'epoch': epoch,
      'ek_pub_admin': base64Encode(ekPubAdmin),
      'sig': base64Encode(sig),
    });
  }
}
