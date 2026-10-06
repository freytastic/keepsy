import 'package:flutter_secure_storage/flutter_secure_storage.dart';

// The iOS plugin filters bulk reads and deletes by accessibility, so every
// caller must share these options
// Tokens and identity sidecars cannot migrate to another device, matching
// the Secure Enclave wrapper key
const FlutterSecureStorage appSecureStorage = FlutterSecureStorage(
  iOptions: IOSOptions(
    accessibility: KeychainAccessibility.first_unlock_this_device,
  ),
);
