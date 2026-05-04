import 'dart:typed_data';
import 'package:cryptography/cryptography.dart' as cg;

// Adapter to convert raw private bytes from SecureKeyStore into
// cryptography package objects for actual use
abstract class KeyHandleAdapter {
  // Wraps a 32 byte Ed25519 seed into a SimpleKeyPair

  // This is async because the cryptography package derives the
  // public key from the seed, which may happen on a native delegate
  static Future<cg.SimpleKeyPair> toEd25519(Uint8List seed) async {
    if (seed.length != 32) {
      throw ArgumentError('Ed25519 seed must be 32 bytes, got ${seed.length}');
    }
    return cg.Ed25519().newKeyPairFromSeed(seed);
  }

  // Wraps a 32 byte X25519 private scalar into a SimpleKeyPair
  static Future<cg.SimpleKeyPair> toX25519(Uint8List priv) async {
    if (priv.length != 32) {
      throw ArgumentError('X25519 scalar must be 32 bytes, got ${priv.length}');
    }
    return cg.X25519().newKeyPairFromSeed(priv);
  }
}
