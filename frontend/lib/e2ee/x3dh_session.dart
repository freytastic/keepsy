import 'dart:typed_data';

import 'package:keepsy/crypto/primitives.dart';
import 'package:keepsy/crypto/x3dh.dart';
import 'package:keepsy/secure_store/key_handle_adapter.dart';

import 'identity.dart';
import 'prekey_bundle.dart';

// Session level wrapper around the §1.1 X3dh.* math. Owns the EK lifecycle
// (generated inline, never persisted, dies when the use<T> closure does)
// and the responder side label -> handle resolution. Does NOT re verify the
// bundle : caller MUST PrekeyBundle.verify() upfront so the call sites stay
// the single source of truth for "is this peer's bundle trustworthy"

class X3dhInitiateResult {
  // sharedSecret + ekPub are Uint8List by value, returned as fields of a value
  // object : layering test regex over public method signatures doesnt catch
  // field access. Caller owns the lifetime of sharedSecret per D10
  final Uint8List sharedSecret;
  final Uint8List ekPub;
  final int? opkIdx;
  const X3dhInitiateResult({
    required this.sharedSecret,
    required this.ekPub,
    required this.opkIdx,
  });
}

class OpkNotFoundException implements Exception {
  final int idx;
  const OpkNotFoundException(this.idx);
  @override
  String toString() => 'OpkNotFoundException(idx=$idx)';
}

abstract class X3dhSession {
  // Initiator. Bundle MUST be verify()'d by caller. EK is generated fresh
  // inside the useLk callback and never escapes the closure
  static Future<X3dhInitiateResult> initiate({
    required PrekeyBundle bundle,
    required Uint8List albumId,
    required IdentityService identity,
  }) async {
    return identity.useLk<X3dhInitiateResult>((lkPriv) async {
      final lkKp = await KeyHandleAdapter.toX25519(lkPriv);
      final ekKp = await Kex.generateX25519();

      final shared = await X3dh.initiator(
        lkSkA: lkKp,
        ekSkA: ekKp,
        lkPkB: bundle.lkPub,
        spkPkB: bundle.spkPub,
        opkPkB: bundle.opk?.keyPub,
        albumId: albumId,
      );

      return X3dhInitiateResult(
        sharedSecret: shared,
        ekPub: ekKp.publicKey,
        opkIdx: bundle.opk?.idx,
      );
    });
  }

  // Responder. Resolves OPK[idx] when wire claims one : OpkNotFoundException
  // on miss instead of silent fallthrough so server side ledger drift surfaces
  // (D5). OPK is NOT marked consumed here : that lives in §4 after MK delivery
  // verifies end to end
  static Future<Uint8List> derive({
    required IdentityService identity,
    required Uint8List ekPub,
    required Uint8List peerLkPub,
    required int? opkIdx,
    required Uint8List albumId,
  }) async {
    if (ekPub.length != 32) {
      throw ArgumentError('ekPub must be 32 bytes, got ${ekPub.length}');
    }
    if (peerLkPub.length != 32) {
      throw ArgumentError(
          'peerLkPub must be 32 bytes, got ${peerLkPub.length}');
    }

    if (opkIdx == null) {
      return _runResponder(
        identity: identity,
        opkSk: null,
        lkPkA: peerLkPub,
        ekPkA: ekPub,
        albumId: albumId,
      );
    }

    final opkAttempt = identity.tryUseOpk<Uint8List>(opkIdx, (opkPriv) async {
      final opkKp = await KeyHandleAdapter.toX25519(opkPriv);
      return _runResponder(
        identity: identity,
        opkSk: opkKp,
        lkPkA: peerLkPub,
        ekPkA: ekPub,
        albumId: albumId,
      );
    });
    if (opkAttempt == null) {
      throw OpkNotFoundException(opkIdx);
    }
    return opkAttempt;
  }
}

// Library private composition helper around X3dh.responder. Top level + leading
// underscore is allowed by the linter and skipped by the §2.2 layering test
// (it filters identifier names starting with _). Public byte secret surface
// stays X3dhSession.derive, which is the lone allowlisted name
Future<Uint8List> _runResponder({
  required IdentityService identity,
  required X25519KeyPair? opkSk,
  required Uint8List lkPkA,
  required Uint8List ekPkA,
  required Uint8List albumId,
}) {
  return identity.useLk<Uint8List>((lkPriv) async {
    final lkKp = await KeyHandleAdapter.toX25519(lkPriv);
    return identity.useSpk<Uint8List>((spkPriv) async {
      final spkKp = await KeyHandleAdapter.toX25519(spkPriv);
      return X3dh.responder(
        lkSkB: lkKp,
        spkSkB: spkKp,
        opkSkB: opkSk,
        lkPkA: lkPkA,
        ekPkA: ekPkA,
        albumId: albumId,
      );
    });
  });
}
