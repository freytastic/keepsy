import 'dart:convert';
import 'dart:typed_data';

import 'wrap_envelope.dart';

class EpochCurrent {
  final int currentEpoch;
  final DateTime startedAt;
  // Set by every revoke, cleared only by the next committed epoch. Feeds the
  // app level rotation recovery
  final bool rotationRequired;
  const EpochCurrent({
    required this.currentEpoch,
    required this.startedAt,
    this.rotationRequired = false,
  });
}

// The client carries the full wrap wire while the server stores its parts
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

  Future<void> setEpoch(String albumId, SetEpochRequest req);
}

abstract class EpochJsonClient {
  Future<Map<String, dynamic>?> getJsonOrNotFound(String path);
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
      // Servers before the explicit flag only send pending_rotation
      rotationRequired:
          (body['rotation_required'] ?? body['pending_rotation']) as bool? ??
              false,
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
