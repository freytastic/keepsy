import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:cryptography/cryptography.dart' as cg;
import 'package:keepsy/crypto/x3dh.dart';
import 'package:keepsy/crypto/safety_numbers.dart';
import 'package:keepsy/crypto/canonical_json.dart';

// For cross language KATs. Mirror of the Go runner at
// server/internal/crypto/kat_test.go : if either side fails on a vector,
// byte-level parity is broken
const String _katFile = '../test_vectors/crypto_kat.json';

Uint8List _hex(String s) {
  if (s.length % 2 != 0) {
    throw FormatException('odd hex length: ${s.length}');
  }
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

Map<String, dynamic> _loadKat() {
  final f = File(_katFile);
  if (!f.existsSync()) {
    throw StateError(
        'KAT file not found at $_katFile (cwd=${Directory.current.path}). '
        'Run flutter test from the frontend/ package root.');
  }
  return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
}

void main() {
  final kat = _loadKat();

  group('KAT: AES-256-GCM decrypt', () {
    final vectors = (kat['aead_aes_gcm_decrypt'] as List).cast<Map>();
    for (final tv in vectors) {
      test(tv['name'] as String, () async {
        final algo = cg.AesGcm.with256bits();
        final ct = _hex(tv['ct_hex'] as String);
        final tag = _hex(tv['tag_hex'] as String);
        final box = cg.SecretBox(ct,
            nonce: _hex(tv['nonce_hex'] as String), mac: cg.Mac(tag));
        final pt = await algo.decrypt(box,
            secretKey: cg.SecretKey(_hex(tv['key_hex'] as String)),
            aad: _hex(tv['aad_hex'] as String));
        expect(pt, orderedEquals(_hex(tv['pt_hex'] as String)));
      });
    }
  });

  group('KAT: ChaCha20-Poly1305 decrypt', () {
    final vectors = (kat['aead_chacha_poly_decrypt'] as List).cast<Map>();
    for (final tv in vectors) {
      test(tv['name'] as String, () async {
        final algo = cg.Chacha20.poly1305Aead();
        final ct = _hex(tv['ct_hex'] as String);
        final tag = _hex(tv['tag_hex'] as String);
        final box = cg.SecretBox(ct,
            nonce: _hex(tv['nonce_hex'] as String), mac: cg.Mac(tag));
        final pt = await algo.decrypt(box,
            secretKey: cg.SecretKey(_hex(tv['key_hex'] as String)),
            aad: _hex(tv['aad_hex'] as String));
        expect(pt, orderedEquals(_hex(tv['pt_hex'] as String)));
      });
    }
  });

  group('KAT: HKDF-SHA256', () {
    final vectors = (kat['hkdf_sha256'] as List).cast<Map>();
    for (final tv in vectors) {
      test(tv['name'] as String, () async {
        final hkdf =
            cg.Hkdf(hmac: cg.Hmac.sha256(), outputLength: tv['length'] as int);
        final out = await hkdf.deriveKey(
          secretKey: cg.SecretKey(_hex(tv['ikm_hex'] as String)),
          nonce: _hex(tv['salt_hex'] as String),
          info: _hex(tv['info_hex'] as String),
        );
        expect(await out.extractBytes(),
            orderedEquals(_hex(tv['okm_hex'] as String)));
      });
    }
  });

  group('KAT: X25519', () {
    final vectors = (kat['x25519'] as List).cast<Map>();
    for (final tv in vectors) {
      test(tv['name'] as String, () async {
        // package:cryptography clamps internally per RFC 7748, matching
        // the bytes the KAT was generated against
        final kp = await cg
            .X25519()
            .newKeyPairFromSeed(_hex(tv['scalar_hex'] as String));
        final peer = cg.SimplePublicKey(_hex(tv['u_hex'] as String),
            type: cg.KeyPairType.x25519);
        final shared = await cg
            .X25519()
            .sharedSecretKey(keyPair: kp, remotePublicKey: peer);
        expect(await shared.extractBytes(),
            orderedEquals(_hex(tv['shared_hex'] as String)));
      });
    }
  });

  group('KAT: Ed25519', () {
    final vectors = (kat['ed25519'] as List).cast<Map>();
    for (final tv in vectors) {
      test(tv['name'] as String, () async {
        final seed = _hex(tv['seed_hex'] as String);
        final kp = await cg.Ed25519().newKeyPairFromSeed(seed);
        final pk = await kp.extractPublicKey() as cg.SimplePublicKey;
        expect(pk.bytes, orderedEquals(_hex(tv['pubkey_hex'] as String)),
            reason: 'pubkey derivation diverged from RFC 8032');

        final msg = _hex(tv['msg_hex'] as String);
        final sig = await cg.Ed25519().sign(msg, keyPair: kp);
        expect(sig.bytes, orderedEquals(_hex(tv['sig_hex'] as String)),
            reason: 'deterministic signature diverged from RFC 8032');

        final ok = await cg.Ed25519().verify(msg,
            signature:
                cg.Signature(_hex(tv['sig_hex'] as String), publicKey: pk));
        expect(ok, isTrue);
      });
    }
  });

  group('KAT: X3DH 4-DH (with OPK)', () {
    final vectors = (kat['x3dh_4dh'] as List).cast<Map>();
    for (final tv in vectors) {
      test(tv['name'] as String, () async {
        final lkA = await cg
            .X25519()
            .newKeyPairFromSeed(_hex(tv['lk_a_seed_hex'] as String));
        final ekA = await cg
            .X25519()
            .newKeyPairFromSeed(_hex(tv['ek_a_seed_hex'] as String));
        final lkB = await cg
            .X25519()
            .newKeyPairFromSeed(_hex(tv['lk_b_seed_hex'] as String));
        final spkB = await cg
            .X25519()
            .newKeyPairFromSeed(_hex(tv['spk_b_seed_hex'] as String));
        final opkB = await cg
            .X25519()
            .newKeyPairFromSeed(_hex(tv['opk_b_seed_hex'] as String));
        final albumId = _hex(tv['album_id_hex'] as String);
        final wantShared = _hex(tv['shared_secret_hex'] as String);

        // Pubkey parity : the seed→pub derivation must match Go's curve25519
        final lkAPub = await lkA.extractPublicKey() as cg.SimplePublicKey;
        expect(lkAPub.bytes, orderedEquals(_hex(tv['lk_a_pub_hex'] as String)),
            reason: 'lk_a pub diverged');
        final lkBPub = await lkB.extractPublicKey() as cg.SimplePublicKey;
        final spkBPub = await spkB.extractPublicKey() as cg.SimplePublicKey;
        final opkBPub = await opkB.extractPublicKey() as cg.SimplePublicKey;
        final ekAPub = await ekA.extractPublicKey() as cg.SimplePublicKey;

        final aShared = await X3dh.initiator(
          lkSkA: lkA,
          ekSkA: ekA,
          lkPkB: lkBPub,
          spkPkB: spkBPub,
          opkPkB: opkBPub,
          albumId: albumId,
        );
        expect(aShared, orderedEquals(wantShared),
            reason: 'initiator shared diverged from frozen Go-generated KAT');

        final bShared = await X3dh.responder(
          lkSkB: lkB,
          spkSkB: spkB,
          opkSkB: opkB,
          lkPkA: lkAPub,
          ekPkA: ekAPub,
          albumId: albumId,
        );
        expect(bShared, orderedEquals(wantShared),
            reason: 'responder shared diverged from frozen Go-generated KAT');
      });
    }
  });

  group('KAT: X3DH 3-DH (OPK exhausted)', () {
    final vectors = (kat['x3dh_3dh'] as List).cast<Map>();
    for (final tv in vectors) {
      test(tv['name'] as String, () async {
        final lkA = await cg
            .X25519()
            .newKeyPairFromSeed(_hex(tv['lk_a_seed_hex'] as String));
        final ekA = await cg
            .X25519()
            .newKeyPairFromSeed(_hex(tv['ek_a_seed_hex'] as String));
        final lkB = await cg
            .X25519()
            .newKeyPairFromSeed(_hex(tv['lk_b_seed_hex'] as String));
        final spkB = await cg
            .X25519()
            .newKeyPairFromSeed(_hex(tv['spk_b_seed_hex'] as String));
        final albumId = _hex(tv['album_id_hex'] as String);
        final wantShared = _hex(tv['shared_secret_hex'] as String);

        final lkAPub = await lkA.extractPublicKey() as cg.SimplePublicKey;
        final lkBPub = await lkB.extractPublicKey() as cg.SimplePublicKey;
        final spkBPub = await spkB.extractPublicKey() as cg.SimplePublicKey;
        final ekAPub = await ekA.extractPublicKey() as cg.SimplePublicKey;

        final aShared = await X3dh.initiator(
          lkSkA: lkA,
          ekSkA: ekA,
          lkPkB: lkBPub,
          spkPkB: spkBPub,
          albumId: albumId,
        );
        expect(aShared, orderedEquals(wantShared));

        final bShared = await X3dh.responder(
          lkSkB: lkB,
          spkSkB: spkB,
          lkPkA: lkAPub,
          ekPkA: ekAPub,
          albumId: albumId,
        );
        expect(bShared, orderedEquals(wantShared));
      });
    }
  });

  group('KAT: SafetyNumber', () {
    final vectors = (kat['safety_numbers'] as List).cast<Map>();
    for (final tv in vectors) {
      test(tv['name'] as String, () async {
        final got = await SafetyNumber.compute(
          ikPubA: _hex(tv['ik_pub_a_hex'] as String),
          ikPubB: _hex(tv['ik_pub_b_hex'] as String),
          albumId: _hex(tv['album_id_hex'] as String),
        );
        expect(got, equals(tv['digits'] as String));
      });
    }
  });

  group('KAT: CanonicalJSON', () {
    final vectors = (kat['canonical_json'] as List).cast<Map>();
    for (final tv in vectors) {
      test(tv['name'] as String, () {
        final input = jsonDecode(tv['input_json'] as String);
        final got = utf8.decode(CanonicalJson.encode(input));
        expect(got, equals(tv['expected_utf8'] as String));
      });
    }
  });
}
