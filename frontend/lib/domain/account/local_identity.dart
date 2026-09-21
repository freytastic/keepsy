import 'dart:typed_data';

import 'package:keepsy/e2ee/identity_label_map.dart';
import 'package:keepsy/secure_store/key_handle_adapter.dart';
import 'package:keepsy/secure_store/secure_key_store.dart';

import 'sign_in_gate.dart';

// Read keys from the keystore because iOS can preserve it after the label map
Future<IdentityPair> readLocalIdentity(SecureKeyStore store) async => (
      ik: await _derivePub(store, kLabelIK,
          (b) async => (await KeyHandleAdapter.toEd25519(b)).publicKey),
      lk: await _derivePub(store, kLabelLK,
          (b) async => (await KeyHandleAdapter.toX25519(b)).publicKey),
    );

// Derive inside use() so private bytes are not copied onto the Dart heap
Future<Uint8List?> _derivePub(
  SecureKeyStore store,
  String label,
  Future<Uint8List> Function(Uint8List priv) derive,
) async {
  final handles = await store.list(labelPrefix: label);
  // Prefix lookup can return future sublabels, so require an exact match
  final exact = handles.where((h) => h.label == label);
  if (exact.isEmpty) return null;
  return store.use(exact.first, derive);
}
