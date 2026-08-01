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

// Server held key state used only to reconcile ambiguous publications. Local
// private keys remain the authority for identity decisions
class OwnKeys {
  final Uint8List ikPub;
  final Uint8List lkPub;
  final Uint8List spkPub;
  final int? spkTs;
  const OwnKeys({
    required this.ikPub,
    required this.lkPub,
    required this.spkPub,
    required this.spkTs,
  });

  factory OwnKeys.fromJson(Map<String, dynamic> json) {
    Uint8List dec(String? s) =>
        s == null || s.isEmpty ? Uint8List(0) : base64Decode(s);
    final ts = json['spk_ts'];
    return OwnKeys(
      ikPub: dec(json['ik_pub'] as String?),
      lkPub: dec(json['lk_pub'] as String?),
      spkPub: dec(json['spk_pub'] as String?),
      spkTs: ts is num ? ts.toInt() : null,
    );
  }
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

  // Side-effect-free self-read; unlike bundle fetches, it pops no OPK
  Future<OwnKeys> fetchOwnKeys();

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

// MemberBundleFetcher : the by nickname bundle lookup used by member removal
// An admin rotating an album fetches remaining members' bundles by member_token
// (identity hidden) rather than by user_id, which it does not know. Kept a
// separate narrow interface so EpochRotator can depend on just this capability
// and the many PrekeyApi test fakes stay untouched. HttpPrekeyApi implements both
abstract class MemberBundleFetcher {
  // GET /albums/{albumId}/members/{member_token}/prekey-bundle. The returned
  // bundle's userId field carries the member_token, not the real user_id
  // Throws MemberBundleNotFoundException on 404 (token not in this album)
  Future<PrekeyBundle> fetchPrekeyBundleByMemberToken(
    String albumId,
    Uint8List memberToken,
  );
}

// Thrown when a member_token resolves to no member of the album (revoked,
// removed, or foreign token) : indistinguishable on purpose
class MemberBundleNotFoundException implements Exception {
  const MemberBundleNotFoundException();
  @override
  String toString() => 'MemberBundleNotFoundException()';
}

class HttpPrekeyApi implements PrekeyApi, MemberBundleFetcher {
  final PrekeyJsonClient _client;
  HttpPrekeyApi(this._client);

  @override
  Future<PrekeyBundle> fetchPrekeyBundleByMemberToken(
    String albumId,
    Uint8List memberToken,
  ) async {
    // member_token goes in the URL path : std base64 has '/' and '+' which
    // break routing, so carry it as base64url with the padding stripped
    // (the server accepts padded or unpadded url/std)
    final tokenPath = base64Url.encode(memberToken).replaceAll('=', '');
    try {
      final body = await _client
          .getJson('/albums/$albumId/members/$tokenPath/prekey-bundle');
      return PrekeyBundle.fromJson(body);
    } on PrekeyApiException catch (e) {
      if (e.httpStatus == 404) {
        throw const MemberBundleNotFoundException();
      }
      rethrow;
    }
  }

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
  Future<OwnKeys> fetchOwnKeys() async {
    final body = await _client.getJson('/users/me/keys');
    return OwnKeys.fromJson(body);
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
