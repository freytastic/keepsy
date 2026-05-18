import 'dart:typed_data';
import 'package:keepsy/crypto/primitives.dart';

// Thin adapter : raw private bytes from SecureKeyStore → typed keypair
// All EC math now goes through libsodium via primitives.Sign/Kex
abstract class KeyHandleAdapter {
  static Future<Ed25519KeyPair> toEd25519(Uint8List seed) =>
      Sign.fromSeed(seed);

  static Future<X25519KeyPair> toX25519(Uint8List priv) => Kex.fromSeed(priv);
}
