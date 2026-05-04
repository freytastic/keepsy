import Foundation
import Flutter
import CryptoKit
import Security

 // It uses a P-256 key in the Secure Enclave as a master "wrapper"
// Since the Enclave cannot do AES, we use it for ECDH to derive a symmetric
 // key that encrypts the actual "envelope" of handles stored in the Keychain
final class SecureEnclaveBridge: NSObject, FlutterPlugin {
    static let CHANNEL = "keepsy/keystore"
    static let WRAP_TAG = "com.example.frontend.keepsy.wrap"
    static let ENVELOPE_TAG = "com.example.frontend.keepsy.envelope"
    static let HKDF_INFO = "keepsy.envelope.v1"

    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: CHANNEL, binaryMessenger: registrar.messenger())
        let instance = SecureEnclaveBridge()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        do {
            let args = (call.arguments as? [String: Any]) ?? [:]
            switch call.method {
            case "initialize":
                try initialize(); result(nil)
            case "put":
                let label = args["label"] as! String
                let pt = (args["plaintext"] as! FlutterStandardTypedData).data
                let id = try put(label: label, plaintext: pt)
                result(["handleId": id])
            case "getOnce":
                let id = args["handleId"] as! String
                let pt = try getOnce(handleId: id)
                result(["plaintext": FlutterStandardTypedData(bytes: pt)])
            case "delete":
                try delete(handleId: args["handleId"] as! String); result(nil)
            case "list":
                let prefix = args["labelPrefix"] as? String
                result(try list(prefix: prefix).map { ["handleId": $0.0, "label": $0.1] })
            case "wipeAll":
                try wipeAll(); result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        } catch let e as Err {
            result(FlutterError(code: e.code, message: e.message, details: nil))
        } catch {
            result(FlutterError(code: "E_NATIVE", message: "\(error)", details: nil))
        }
    }

    // MARK:  Wrapper key

    private func loadOrCreateWrapKey() throws -> SecKey {
        if let k = try? loadWrapKey() { return k }
        return try createWrapKey()
    }

    private func loadWrapKey() throws -> SecKey {
        let q: [String: Any] = [
            kSecClass as String:              kSecClassKey,
            kSecAttrApplicationTag as String: Self.WRAP_TAG.data(using: .utf8)!,
            kSecAttrKeyType as String:        kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String:          true
        ]
        var item: CFTypeRef?
        let s = SecItemCopyMatching(q as CFDictionary, &item)
        guard s == errSecSuccess, let key = item else { throw Err.notFound("wrap key") }
        return (key as! SecKey)
    }

    private func createWrapKey() throws -> SecKey {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            .privateKeyUsage,
            &error
        ) else { throw Err.native("SecAccessControl: \(error!.takeRetainedValue())") }

        var attrs: [String: Any] = [
            kSecAttrKeyType as String:        kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String:  256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String:     true,
                kSecAttrApplicationTag as String:  Self.WRAP_TAG.data(using: .utf8)!,
                kSecAttrAccessControl as String:   access
            ]
        ]
        #if !targetEnvironment(simulator)
        // SecureEnclave.isAvailable is only true on physical devices
        // The private bytes of this key are non-extractable from the SE hardware
        attrs[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave
        #endif

        guard let key = SecKeyCreateRandomKey(attrs as CFDictionary, &error) else {
            throw Err.native("SecKeyCreateRandomKey: \(error!.takeRetainedValue())")
        }
        return key
    }

    // MARK:  Envelope persistence


     // Decrypts the envelope by re-deriving the AES key via ECDH between the
     //stored ephemeral public key and the SE-resident master private key
    private func loadEnvelope() throws -> [String: (label: String, value: Data)] {
        // Distinguish post wipeAll (E_STORE_UNINITIALIZED) from a mere missing handle
        guard (try? loadWrapKey()) != nil else { throw Err.uninitialized("wrapper key absent") }

        let q: [String: Any] = [
            kSecClass as String:           kSecClassGenericPassword,
            kSecAttrAccount as String:     Self.ENVELOPE_TAG,
            kSecReturnData as String:      true,
            kSecMatchLimit as String:      kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let s = SecItemCopyMatching(q as CFDictionary, &item)
        if s == errSecItemNotFound { return [:] }
        if s != errSecSuccess { throw Err.native("SecItemCopyMatching: \(s)") }

        let blob = item as! Data
        // Layout : ephPubLen u8 | ephPub | salt(16) | iv(12) | ct||tag
        var off = 0
        let ephLen = Int(blob[off]); off += 1
        let ephPub = blob.subdata(in: off..<off+ephLen); off += ephLen
        let salt   = blob.subdata(in: off..<off+16);    off += 16
        let iv     = blob.subdata(in: off..<off+12);    off += 12
        let ct     = blob.subdata(in: off..<blob.count)

        let aesKey = try deriveAesKey(ephPub: ephPub, salt: salt)
        let sealed = try AES.GCM.SealedBox(combined: iv + ct)
        let pt: Data
        do {
            pt = try AES.GCM.open(sealed, using: aesKey)
        } catch {
            throw Err.tamper("envelope auth tag invalid")
        }
        return decode(pt)
    }

     // Saves the envelope
     //Uses Hybrid Encryption (ECDH) because the Secure Enclave math is restricted to EC
    private func saveEnvelope(_ map: [String: (label: String, value: Data)]) throws {
        let wrapKey: SecKey
        do { wrapKey = try loadWrapKey() }
        catch { throw Err.uninitialized("wrapper key absent") }
        guard SecKeyCopyPublicKey(wrapKey) != nil else { throw Err.native("no wrap pub") }

        // Generate an ephemeral keypair on the CPU
        let eph = P256.KeyAgreement.PrivateKey()
        let ephPubBytes = eph.publicKey.x963Representation
        let salt = randomBytes(16)

        var error: Unmanaged<CFError>?
        let ephSecKeyAttrs: [String: Any] = [
            kSecAttrKeyType as String:  kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic
        ]
        guard let ephAsSecKey = SecKeyCreateWithData(ephPubBytes as CFData, ephSecKeyAttrs as CFDictionary, &error) else {
            throw Err.native("eph SecKey: \(error!.takeRetainedValue())")
        }

        // ECDH : The SE hardware multiplies its private key by our ephemeral public key
        // The resulting shared secret never existed as bytes on disk
        var dhErr: Unmanaged<CFError>?
        guard let shared = SecKeyCopyKeyExchangeResult(
            wrapKey,
            .ecdhKeyExchangeStandardX963SHA256,
            ephAsSecKey,
            [:] as CFDictionary,
            &dhErr
        ) as Data? else { throw Err.native("ECDH: \(dhErr!.takeRetainedValue())") }

        // HKDF turns the shared secret into a symmetric 32-byte AES key
        let aesKey = SymmetricKey(data: HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: shared),
            salt: salt,
            info: Self.HKDF_INFO.data(using: .utf8)!,
            outputByteCount: 32
        ))

        let pt = encode(map)
        let sealed = try AES.GCM.seal(pt, using: aesKey, nonce: AES.GCM.Nonce(data: randomBytes(12)))
        let iv = sealed.nonce.withUnsafeBytes { Data($0) }

        // Storage : The ephemeral public key and salt must be saved so we can redo ECDH later
        var blob = Data()
        blob.append(UInt8(ephPubBytes.count))
        blob.append(ephPubBytes)
        blob.append(salt)
        blob.append(iv)
        blob.append(sealed.ciphertext)
        blob.append(sealed.tag)

        SecItemDelete([
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: Self.ENVELOPE_TAG
        ] as CFDictionary)
        let addAttrs: [String: Any] = [
            kSecClass as String:           kSecClassGenericPassword,
            kSecAttrAccount as String:     Self.ENVELOPE_TAG,
            kSecValueData as String:       blob,
            // AccessibleAfterFirstUnlock: survive reboot
            // ThisDeviceOnly: ensure the key doesnt leak to iCloud or other devices
            kSecAttrAccessible as String:  kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let s = SecItemAdd(addAttrs as CFDictionary, nil)
        if s != errSecSuccess { throw Err.native("SecItemAdd envelope: \(s)") }
    }
    }

    private func deriveAesKey(ephPub: Data, salt: Data) throws -> SymmetricKey {
        let wrapKey = try loadWrapKey()
        var error: Unmanaged<CFError>?
        let ephAttrs: [String: Any] = [
            kSecAttrKeyType as String:  kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic
        ]
        guard let ephAsSecKey = SecKeyCreateWithData(ephPub as CFData, ephAttrs as CFDictionary, &error) else {
            throw Err.native("eph SecKey on read: \(error!.takeRetainedValue())")
        }
        var dhErr: Unmanaged<CFError>?
        guard let shared = SecKeyCopyKeyExchangeResult(
            wrapKey,
            .ecdhKeyExchangeStandardX963SHA256,
            ephAsSecKey,
            [:] as CFDictionary,
            &dhErr
        ) as Data? else { throw Err.native("ECDH read: \(dhErr!.takeRetainedValue())") }
        return SymmetricKey(data: HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: shared),
            salt: salt,
            info: Self.HKDF_INFO.data(using: .utf8)!,
            outputByteCount: 32
        ))
    }

    // MARK:  Public API

    private func initialize() throws { _ = try loadOrCreateWrapKey() }

    private func put(label: String, plaintext: Data) throws -> String {
        var map = try loadEnvelope()
        let id = randomHex(16)
        map[id] = (label, plaintext)
        try saveEnvelope(map)
        return id
    }

    private func getOnce(handleId: String) throws -> Data {
        let map = try loadEnvelope()
        guard let entry = map[handleId] else { throw Err.notFound(handleId) }
        return entry.value
    }

    private func delete(handleId: String) throws {
        var map = try loadEnvelope()
        guard map.removeValue(forKey: handleId) != nil else { throw Err.notFound(handleId) }
        try saveEnvelope(map)
    }

    private func list(prefix: String?) throws -> [(String, String)] {
        let map = try loadEnvelope()
        return map.compactMap { (k, v) in
            (prefix == nil || v.label.hasPrefix(prefix!)) ? (k, v.label) : nil
        }
    }

    private func wipeAll() throws {
        SecItemDelete([
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: Self.ENVELOPE_TAG
        ] as CFDictionary)
        SecItemDelete([
            kSecClass as String:              kSecClassKey,
            kSecAttrApplicationTag as String: Self.WRAP_TAG.data(using: .utf8)!
        ] as CFDictionary)
    }

    // MARK:  Wire format (matches Android byte for byte)

    private func encode(_ map: [String: (label: String, value: Data)]) -> Data {
        var d = Data()
        var n = UInt16(map.count).bigEndian
        d.append(Data(bytes: &n, count: 2))
        for (id, lv) in map {
            let idB = id.data(using: .ascii)!
            let labelB = lv.label.data(using: .utf8)!
            d.append(UInt8(idB.count))
            d.append(idB)
            var ll = UInt16(labelB.count).bigEndian
            d.append(Data(bytes: &ll, count: 2))
            d.append(labelB)
            var vl = UInt16(lv.value.count).bigEndian
            d.append(Data(bytes: &vl, count: 2))
            d.append(lv.value)
        }
        return d
    }

    private func decode(_ blob: Data) -> [String: (label: String, value: Data)] {
        var off = 0
        func u16() -> Int {
            let v = Int(blob[off]) << 8 | Int(blob[off+1]); off += 2; return v
        }
        let n = u16()
        var out: [String: (String, Data)] = [:]
        for _ in 0..<n {
            let idLen = Int(blob[off]); off += 1
            let id = String(data: blob.subdata(in: off..<off+idLen), encoding: .ascii)!; off += idLen
            let labelLen = u16()
            let label = String(data: blob.subdata(in: off..<off+labelLen), encoding: .utf8)!; off += labelLen
            let valLen = u16()
            let value = blob.subdata(in: off..<off+valLen); off += valLen
            out[id] = (label, value)
        }
        return out
    }

    // MARK:  Helpers

    private func randomBytes(_ n: Int) -> Data {
        var d = Data(count: n)
        _ = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) }
        return d
    }

    private func randomHex(_ n: Int) -> String {
        randomBytes(n).map { String(format: "%02x", $0) }.joined()
    }

    enum Err: Error {
        case tamper(String), notFound(String), uninitialized(String), native(String)
        var code: String {
            switch self {
            case .tamper:        return "E_KEY_TAMPER"
            case .notFound:      return "E_KEY_NOT_FOUND"
            case .uninitialized: return "E_STORE_UNINITIALIZED"
            case .native:        return "E_NATIVE"
            }
        }
        var message: String {
            switch self {
            case .tamper(let m), .notFound(let m), .uninitialized(let m), .native(let m): return m
            }
        }
    }
}
