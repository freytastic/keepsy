import 'dart:typed_data';
import 'package:cryptography/cryptography.dart' as cg;
import 'wire_format.dart';

// Thrown when an AEAD authentication tag fails verification
// Distinct from FormatException so callers can differentiate "wire malformed"
// from "wire well formed but tampered with"
class AeadAuthFailed implements Exception {
  final String message;
  AeadAuthFailed([this.message = 'AEAD authentication failed']);
  @override
  String toString() => 'AeadAuthFailed: $message';
}

// Authenticated encryption / decryption with a 96-bit fresh CSPRNG nonce per call
// Returns / consumes wire bytes VER||NONCE||TAG||CT , no never raw ciphertext
abstract class Aead {
  static Future<Uint8List> encrypt({
    required int version,
    required Uint8List key,
    required Uint8List plaintext,
    required Uint8List aad,
  }) async {
    if (key.length != 32) {
      throw ArgumentError('key must be 32 bytes, got ${key.length}');
    }
    final algo = _algoFor(version);
    final box = await algo.encrypt(
      plaintext,
      secretKey: cg.SecretKey(key),
      aad: aad,
    );
    return WireFormat.assemble(
      version: version,
      nonce: Uint8List.fromList(box.nonce),
      tag: Uint8List.fromList(box.mac.bytes),
      ciphertext: Uint8List.fromList(box.cipherText),
    );
  }

  static Future<Uint8List> decrypt({
    required Uint8List wire,
    required Uint8List key,
    required Uint8List aad,
  }) async {
    if (key.length != 32) {
      throw ArgumentError('key must be 32 bytes, got ${key.length}');
    }
    final parsed = WireFormat.parse(wire);
    if (parsed.version == kVerStreamGcm) {
      throw UnimplementedError(
          'VER=0x03 streaming AEAD lands in p5: use the streaming pipeline.');
    }
    final algo = _algoFor(parsed.version);
    final box = cg.SecretBox(
      parsed.ciphertext,
      nonce: parsed.nonce,
      mac: cg.Mac(parsed.tag),
    );
    try {
      final pt = await algo.decrypt(
        box,
        secretKey: cg.SecretKey(key),
        aad: aad,
      );
      return Uint8List.fromList(pt);
    } on cg.SecretBoxAuthenticationError catch (e) {
      throw AeadAuthFailed(e.toString());
    }
  }

  static cg.Cipher _algoFor(int version) {
    switch (version) {
      case kVerAesGcm:
        return cg.AesGcm.with256bits();
      case kVerChaPo:
        return cg.Chacha20.poly1305Aead();
      case kVerStreamGcm:
        throw UnimplementedError('VER=0x03 streaming lands in p5');
      default:
        throw FormatException(
            'unknown VER: 0x${version.toRadixString(16).padLeft(2, '0')}');
    }
  }
}

abstract class Hkdf {
  static Future<Uint8List> derive({
    required Uint8List ikm,
    required Uint8List salt,
    required Uint8List info,
    required int length,
  }) async {
    final hkdf = cg.Hkdf(hmac: cg.Hmac.sha256(), outputLength: length);
    final out = await hkdf.deriveKey(
      secretKey: cg.SecretKey(ikm),
      nonce: salt,
      info: info,
    );
    return Uint8List.fromList(await out.extractBytes());
  }
}

abstract class Sign {
  static Future<cg.SimpleKeyPair> generateEd25519() =>
      cg.Ed25519().newKeyPair();

  static Future<Uint8List> sign(cg.SimpleKeyPair keyPair, Uint8List msg) async {
    final sig = await cg.Ed25519().sign(msg, keyPair: keyPair);
    return Uint8List.fromList(sig.bytes);
  }

  static Future<bool> verify(
      cg.SimplePublicKey pubKey, Uint8List msg, Uint8List sig) async {
    return cg.Ed25519().verify(
      msg,
      signature: cg.Signature(sig, publicKey: pubKey),
    );
  }
}

abstract class Kex {
  static Future<cg.SimpleKeyPair> generateX25519() => cg.X25519().newKeyPair();

  // X25519 Diffie Hellman : returns the 32byte shared u coordinate
  static Future<Uint8List> dh(
      cg.SimpleKeyPair self, cg.SimplePublicKey peerPub) async {
    final shared = await cg.X25519().sharedSecretKey(
          keyPair: self,
          remotePublicKey: peerPub,
        );
    return Uint8List.fromList(await shared.extractBytes());
  }
}

abstract class Csprng {
  // n random bytes from the OS CSPRNG. Backed by Dart's Random.secure() through
  // package :cryptography's SecretKeyData.random
  static Uint8List bytes(int n) {
    if (n < 0) throw ArgumentError('n must be >= 0');
    final data = cg.SecretKeyData.random(length: n);
    return Uint8List.fromList(data.bytes);
  }

  // 32-bit unsigned int in little endian over 4 random bytes
  static int u32() {
    final b = bytes(4);
    return b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24);
  }
}
