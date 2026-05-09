import 'wrap_envelope.dart';

// Bits of the album epoch endpoints EpochProcessor needs. The HTTP impl lives
// here (mirrors HttpPrekeyApi), with a thin EpochJsonClient port that the
// composition root wires to ApiClient. Keeping the abstract + impl in
// lib/e2ee/ means EpochProcessor never imports package:keepsy/data

class EpochCurrent {
  final int currentEpoch;
  final DateTime startedAt;
  const EpochCurrent({required this.currentEpoch, required this.startedAt});
}

abstract class EpochApi {
  // null when the album has no epoch yet (server returns 404)
  Future<EpochCurrent?> getCurrentEpoch(String albumId);

  // Throws EpochWrapNotFoundException on 404 so the processor's catch up loop
  // can apply the D7 retry with backoff for racy fetches
  Future<WrapEnvelope> getWrap(String albumId, int epoch);
}

abstract class EpochJsonClient {
  // Returns null on 404 : rethrows other ApiErrors from the data layer
  Future<Map<String, dynamic>?> getJsonOrNotFound(String path);
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
}
