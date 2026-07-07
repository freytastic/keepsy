import 'dart:convert';
import 'dart:typed_data';

import 'wrap_envelope.dart';

// Bits of the album epoch endpoints EpochProcessor needs. The HTTP impl lives
// here (mirrors HttpPrekeyApi), with a thin EpochJsonClient port that the
// composition root wires to ApiClient. Keeping the abstract + impl in
// lib/e2ee/ means EpochProcessor never imports package:keepsy/data

class EpochCurrent {
  final int currentEpoch;
  final DateTime startedAt;
  // pendingRotation : true when the album is in the revoke→rotate window (a
  // removed member is still covered by the current epoch, or the active set
  // shrank). An admin's client uses it to auto heal on album open
  final bool pendingRotation;
  const EpochCurrent({
    required this.currentEpoch,
    required this.startedAt,
    this.pendingRotation = false,
  });
}

// SetEpochWrap : one row in the POST /albums/{id}/epoch wraps[] array
// wrap is the full 61 byte VER‖NONCE‖TAG‖CT (server splits + stores nonce
// and tag_ct separately : the client builds the full wire). senderSig is
// Ed25519_sign(IK_priv_sender, SHA256(album_id ‖ u32_be(epoch) ‖ wrap_blob))
class SetEpochWrap {
  final Uint8List recipientToken;
  final Uint8List ekPub;
  final int? opkIdxUsed;
  final Uint8List wrap;
  final Uint8List senderSig;
  const SetEpochWrap({
    required this.recipientToken,
    required this.ekPub,
    required this.opkIdxUsed,
    required this.wrap,
    required this.senderSig,
  });
}

class SetEpochRequest {
  final int epoch;
  final Uint8List memberSetHash;
  final List<SetEpochWrap> wraps;
  final Uint8List envelopeSig;
  const SetEpochRequest({
    required this.epoch,
    required this.memberSetHash,
    required this.wraps,
    required this.envelopeSig,
  });
}

abstract class EpochApi {
  // null when the album has no epoch yet (server returns 404)
  Future<EpochCurrent?> getCurrentEpoch(String albumId);

  // Throws EpochWrapNotFoundException on 404 so the processor's catch up loop
  // can apply the D7 retry with backoff for racy fetches
  Future<WrapEnvelope> getWrap(String albumId, int epoch);

  // POST /albums/{id}/epoch. Used by EpochRotator on album create (bootstrap
  // epoch 0) and on member add/remove. Server validates wraps_hash +
  // envelope_sig + role gate : on success fires e2ee.epoch_changed fanout
  Future<void> setEpoch(String albumId, SetEpochRequest req);
}

abstract class EpochJsonClient {
  // Returns null on 404 : rethrows other ApiErrors from the data layer
  Future<Map<String, dynamic>?> getJsonOrNotFound(String path);
  // POST a JSON body. Rethrows ApiError on non 2xx
  Future<void> postJson(String path, Map<String, dynamic> body);
}

class EpochWrapNotFoundException implements Exception {
  final String albumId;
  final int epoch;
  const EpochWrapNotFoundException(this.albumId, this.epoch);
  @override
  String toString() =>
      'EpochWrapNotFoundException(albumId=$albumId, epoch=$epoch)';
}

class HttpEpochApi implements EpochApi {
  final EpochJsonClient _client;
  HttpEpochApi(this._client);

  @override
  Future<EpochCurrent?> getCurrentEpoch(String albumId) async {
    final body = await _client.getJsonOrNotFound('/albums/$albumId/epoch');
    if (body == null) return null;
    return EpochCurrent(
      currentEpoch: (body['current_epoch'] as num).toInt(),
      startedAt: DateTime.parse(body['started_at'] as String),
      pendingRotation: body['pending_rotation'] as bool? ?? false,
    );
  }

  @override
  Future<WrapEnvelope> getWrap(String albumId, int epoch) async {
    final body =
        await _client.getJsonOrNotFound('/albums/$albumId/epoch/$epoch/wrap');
    if (body == null) {
      throw EpochWrapNotFoundException(albumId, epoch);
    }
    return WrapEnvelope.fromJson(body);
  }

  @override
  Future<void> setEpoch(String albumId, SetEpochRequest req) async {
    final wraps = req.wraps
        .map((w) => <String, dynamic>{
              'recipient_token': base64Encode(w.recipientToken),
              'ek_pub': base64Encode(w.ekPub),
              'opk_idx_used': w.opkIdxUsed,
              'wrap': base64Encode(w.wrap),
              'sender_sig': base64Encode(w.senderSig),
            })
        .toList();
    await _client.postJson('/albums/$albumId/epoch', {
      'epoch': req.epoch,
      'member_set_hash': base64Encode(req.memberSetHash),
      'wraps': wraps,
      'envelope_sig': base64Encode(req.envelopeSig),
    });
  }
}
