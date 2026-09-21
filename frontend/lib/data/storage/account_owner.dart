import 'dart:convert';
import 'dart:typed_data';

import 'package:keepsy/secure_store/key_handle.dart';
import 'package:keepsy/secure_store/secure_key_store.dart';

// Keep the owner with vault keys so iOS Keychain persistence cannot separate
// surviving keys from their account binding
const String kAccountOwnerLabel = 'keepsy.account.owner';

// Raised when a second account tries to claim a vault that is already bound
class AccountOwnerConflict implements Exception {
  final String boundTo;
  final String attempted;
  const AccountOwnerConflict({required this.boundTo, required this.attempted});

  @override
  String toString() => 'AccountOwnerConflict(bound to a different account)';
}

class AccountOwnerStore {
  final SecureKeyStore _store;

  AccountOwnerStore(this._store);

  Future<String?> read() async {
    final h = await _handle();
    if (h == null) return null;
    return _store.use(h, (bytes) async => utf8.decode(bytes));
  }

  // Rebinding requires the installation to be erased first
  Future<void> bind(String userId) async {
    if (userId.isEmpty) {
      throw ArgumentError('userId must not be empty');
    }
    final current = await read();
    if (current != null) {
      if (current == userId) return;
      throw AccountOwnerConflict(boundTo: current, attempted: userId);
    }
    await _store.put(
        kAccountOwnerLabel, Uint8List.fromList(utf8.encode(userId)));
  }

  Future<void> clear() async {
    for (final h in await _store.list(labelPrefix: kAccountOwnerLabel)) {
      await _store.delete(h);
    }
  }

  Future<KeyHandle?> _handle() async {
    final all = await _store.list(labelPrefix: kAccountOwnerLabel);
    return all.isEmpty ? null : all.first;
  }
}
