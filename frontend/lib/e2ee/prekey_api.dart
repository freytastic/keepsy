import 'dart:convert';
import 'dart:typed_data';

import 'prekey_bundle.dart';

// Thin wire format wrapper for the §4 prekey/SPK/OPK endpoints. Stays inside
// lib/e2ee/ : depends only on a tiny PrekeyJsonClient surface that the
// composition root wires to ApiClient. Server expects standard base64 (not
// url-safe)

class PrekeyOpk {
  final int idx;
  final Uint8List keyPub;
  const PrekeyOpk({required this.idx, required this.keyPub});
}

// Surfaced when a prekey/SPK/OPK endpoint returns a structured server error
// Translated from the data layer ApiError by the PrekeyJsonClient adapter so
// e2ee/ never has to import package:keepsy/data/
class PrekeyApiException implements Exception {
  final String code;
  final String message;
  final int httpStatus;
  const PrekeyApiException({
    required this.code,
    required this.message,
    required this.httpStatus,
  });
  @override
  String toString() =>
      'PrekeyApiException($code, http=$httpStatus, message="$message")';
}

// Bits of ApiClient that PrekeyApi actually needs. The adapter lives in
// lib/data/api/ so e2ee/ never imports the data layer
abstract class PrekeyJsonClient {
  Future<Map<String, dynamic>> getJson(String path);
  Future<void> postJson(String path, Map<String, dynamic> body);
  Future<void> putJson(String path, Map<String, dynamic> body);
}

abstract class PrekeyApi {
  Future<void> upsertIdentity({
    required Uint8List ikPub,
    required Uint8List lkPub,
    required Uint8List spkPub,
    required Uint8List spkSig,
    required int spkTs,
  });

  Future<void> rotateSpk({
    required Uint8List spkPub,
    required Uint8List spkSig,
    required int spkTs,
    required Uint8List rotationSig,
  });

  Future<void> replenishOpks({
    required List<PrekeyOpk> opks,
    required Uint8List replenishSig,
  });

  Future<int> opkCount();

  // GET /users/{id}/prekey-bundle. Returns the raw bytes-in/bytes-out value
  // type : caller MUST gate on PrekeyBundle.verify() before X3dhSession.initiate
  Future<PrekeyBundle> fetchPrekeyBundle(String userId);

  // GET /users/by-handle/{handle}/prekey-bundle (§6.1 discovery). The returned
  // bundle's userId field carries the keepsy_id, not the real user_id (server
  // never emits it) : X3dhSession.initiate ignores userId anyway hehe. Throws
  // HandleNotFoundException on 404 (unknown or malformed handle, indistinguishable)
  Future<PrekeyBundle> fetchPrekeyBundleByHandle(String handle);
}

// Thrown when a keepsy_id resolves to no user (or is malformed) : the UI shows
// a "no such keepsy ID" rather than leaking which case it was
class HandleNotFoundException implements Exception {
  final String handle;
  const HandleNotFoundException(this.handle);
  @override
  String toString() => 'HandleNotFoundException($handle)';
}

class HttpPrekeyApi implements PrekeyApi {
  final PrekeyJsonClient _client;
  HttpPrekeyApi(this._client);

  @override
  Future<void> upsertIdentity({
    required Uint8List ikPub,
    required Uint8List lkPub,
    required Uint8List spkPub,
    required Uint8List spkSig,
    required int spkTs,
  }) {
    return _client.putJson('/users/me/keys', {
      'ik_pub': base64Encode(ikPub),
      'lk_pub': base64Encode(lkPub),
      'spk_pub': base64Encode(spkPub),
      'spk_sig': base64Encode(spkSig),
      'spk_ts': spkTs,
    });
  }

  @override
  Future<void> rotateSpk({
    required Uint8List spkPub,
    required Uint8List spkSig,
    required int spkTs,
    required Uint8List rotationSig,
  }) {
    return _client.postJson('/users/me/spk', {
      'spk_pub': base64Encode(spkPub),
      'spk_sig': base64Encode(spkSig),
      'spk_ts': spkTs,
      'rotation_sig': base64Encode(rotationSig),
    });
  }

  @override
  Future<void> replenishOpks({
    required List<PrekeyOpk> opks,
    required Uint8List replenishSig,
  }) {
    return _client.postJson('/users/me/opks', {
      'opks': [
        for (final o in opks) {'idx': o.idx, 'key_pub': base64Encode(o.keyPub)},
      ],
      'replenish_sig': base64Encode(replenishSig),
    });
  }

  @override
  Future<int> opkCount() async {
    final body = await _client.getJson('/users/me/opks/count');
    return body['count'] as int;
  }

  @override
  Future<PrekeyBundle> fetchPrekeyBundle(String userId) async {
    final body = await _client.getJson('/users/$userId/prekey-bundle');
    return PrekeyBundle.fromJson(body);
  }

  @override
  Future<PrekeyBundle> fetchPrekeyBundleByHandle(String handle) async {
    try {
      final body =
          await _client.getJson('/users/by-handle/$handle/prekey-bundle');
      return PrekeyBundle.fromJson(body);
    } on PrekeyApiException catch (e) {
      if (e.httpStatus == 404) {
        throw HandleNotFoundException(handle);
      }
      rethrow;
    }
  }
}
