# Miuchio app

The Flutter app for Android and iPhone. Setup, running and tests are described in the [main README](../README.md#running-locally).

| Path | What is in it |
| --- | --- |
| `lib/crypto/` | Primitives, the X3DH handshake and the wire formats |
| `lib/e2ee/` | Epochs, invites, removal, trust and the photo pipeline |
| `lib/secure_store/` | Key storage backed by the Android Keystore and the Secure Enclave |
| `lib/data/` | API client, local storage and the upload queue |
| `lib/domain/` | Account, album, activity and upload logic |
| `lib/ui/` | Screens and widgets |
| `android/`, `ios/` | Native key store bridges and, on Android, photo processing |
| `test/`, `integration_test/` | Unit, widget and device tests |

Run `flutter test` from this folder, because the cross-language tests read `../test_vectors/crypto_kat.json`.
