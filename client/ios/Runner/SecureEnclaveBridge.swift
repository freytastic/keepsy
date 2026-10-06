import Foundation
import Flutter
import CryptoKit
import Security

// On devices, a Secure Enclave P-256 key derives the AES key that seals app keys
// The encrypted envelope lives in Keychain
final class SecureEnclaveBridge: NSObject, FlutterPlugin {
    static let CHANNEL = "miuchio/keystore"
    static let WRAP_TAG = "com.freytastic.miuchio.wrap"
    static let ENVELOPE_TAG = "com.freytastic.miuchio.envelope"
    static let HKDF_INFO = "miuchio.envelope.v1"

    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: CHANNEL, binaryMessenger: registrar.messenger())
        let instance = SecureEnclaveBridge()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    // One serial queue keeps envelope reads and rewrites in order without
    // blocking the UI thread, matching the Android worker
    private let queue = DispatchQueue(label: "miuchio.keystore", qos: .userInitiated)

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = (call.arguments as? [String: Any]) ?? [:]
        let work: () throws -> Any?
        switch call.method {
        case "initialize":
            work = { try self.initialize(); return nil }
        case "put":
            work = {
                let id = try self.put(label: try Self.string(args, "label"),
                                      plaintext: try Self.bytes(args, "plaintext"))
                return ["handleId": id]
            }
        case "putMany":
            work = {
                guard let entries = args["entries"] as? [[String: Any]] else {
                    throw Err.native("entries missing")
                }
                let parsed = try entries.map { (try Self.string($0, "label"), try Self.bytes($0, "plaintext")) }
                return try self.putMany(parsed).map { ["handleId": $0] }
            }
        case "getOnce":
            work = {
                let pt = try self.getOnce(handleId: try Self.string(args, "handleId"))
                return ["plaintext": FlutterStandardTypedData(bytes: pt)]
            }
        case "delete":
            work = { try self.delete(handleId: try Self.string(args, "handleId")); return nil }
        case "list":
            work = {
                let prefix = args["labelPrefix"] as? String
                return try self.list(prefix: prefix).map { ["handleId": $0.0, "label": $0.1] }
            }
        case "wipeAll":
            work = { try self.wipeAll(); return nil }
        default:
            result(FlutterMethodNotImplemented)
            return
        }
        queue.async {
            let reply: Any?
            do {
                reply = try work()
            } catch let e as Err {
                reply = FlutterError(code: e.code, message: e.message, details: nil)
            } catch {
                reply = FlutterError(code: "E_NATIVE", message: "\(error)", details: nil)
            }
            DispatchQueue.main.async { result(reply) }
        }
    }

    private static func string(_ args: [String: Any], _ key: String) throws -> String {
        guard let v = args[key] as? String else { throw Err.native("\(key) missing") }
        return v
    }

    private static func bytes(_ args: [String: Any], _ key: String) throws -> Data {
        guard let v = args[key] as? FlutterStandardTypedData else { throw Err.native("\(key) missing") }
        return v.data
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
            kSecAttrKeyClass as String:       kSecAttrKeyClassPrivate,
            kSecReturnRef as String:          true
        ]
        var item: CFTypeRef?
        let s = SecItemCopyMatching(q as CFDictionary, &item)
        guard s == errSecSuccess, let key = item else { throw Err.notFound("wrap key") }
        return (key as! SecKey)
    }

    private func createWrapKey() throws -> SecKey {
        var error: Unmanaged<CFError>?
        var privateAttrs: [String: Any] = [
            kSecAttrIsPermanent as String:     true,
            kSecAttrApplicationTag as String:  Self.WRAP_TAG.data(using: .utf8)!
        ]
        var attrs: [String: Any] = [
            kSecAttrKeyType as String:        kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String:  256
        ]
        #if targetEnvironment(simulator)
        // Use a software key in the simulator with the same accessibility policy
        privateAttrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #else
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            .privateKeyUsage,
            &error
        ) else { throw Err.native("SecAccessControl: \(error!.takeRetainedValue())") }
        privateAttrs[kSecAttrAccessControl as String] = access
        // The private bytes of this key are non-extractable from the SE hardware
        attrs[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave
        #endif
        attrs[kSecPrivateKeyAttrs as String] = privateAttrs

        guard let key = SecKeyCreateRandomKey(attrs as CFDictionary, &error) else {
            throw Err.native("SecKeyCreateRandomKey: \(error!.takeRetainedValue())")
        }
        return key
    }

    // MARK:  Envelope persistence

    // Re-derive the AES key from the stored ephemeral public key and wrapper key
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

    private func saveEnvelope(_ map: [String: (label: String, value: Data)]) throws {
        guard (try? loadWrapKey()) != nil else { throw Err.uninitialized("wrapper key absent") }

        // Generate an ephemeral keypair on the CPU, then derive exactly as reads do
        let eph = P256.KeyAgreement.PrivateKey()
        let ephPubBytes = eph.publicKey.x963Representation
        let salt = randomBytes(16)
        let aesKey = try deriveAesKey(ephPub: ephPubBytes, salt: salt)

        let pt = encode(map)
        let sealed = try AES.GCM.seal(pt, using: aesKey, nonce: AES.GCM.Nonce(data: randomBytes(12)))
        let iv = sealed.nonce.withUnsafeBytes { Data($0) }

        // Retain the ephemeral public key and salt to derive the same key on reads
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
            // Available after first unlock and cannot migrate to another device
            kSecAttrAccessible as String:  kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let s = SecItemAdd(addAttrs as CFDictionary, nil)
        if s != errSecSuccess { throw Err.native("SecItemAdd envelope: \(s)") }
    }

    private func deriveAesKey(ephPub: Data, salt: Data) throws -> SymmetricKey {
        let wrapKey = try loadWrapKey()
        var error: Unmanaged<CFError>?
        let ephAttrs: [String: Any] = [
            kSecAttrKeyType as String:  kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic
        ]
        guard let ephAsSecKey = SecKeyCreateWithData(ephPub as CFData, ephAttrs as CFDictionary, &error) else {
            throw Err.native("eph SecKey: \(error!.takeRetainedValue())")
        }
        var dhErr: Unmanaged<CFError>?
        guard let shared = SecKeyCopyKeyExchangeResult(
            wrapKey,
            .ecdhKeyExchangeStandardX963SHA256,
            ephAsSecKey,
            // The X9.63 KDF fails without an output size
            [SecKeyKeyExchangeParameter.requestedSize.rawValue: 32] as CFDictionary,
            &dhErr
        ) as Data? else { throw Err.native("ECDH: \(dhErr!.takeRetainedValue())") }
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

    private func putMany(_ entries: [(String, Data)]) throws -> [String] {
        var map = try loadEnvelope()
        let ids = entries.map { entry -> String in
            let id = randomHex(16)
            map[id] = (entry.0, entry.1)
            return id
        }
        try saveEnvelope(map)
        return ids
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

    // Account deletion trusts this, so a delete that did not happen must throw
    private func wipeAll() throws {
        let envelope = SecItemDelete([
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: Self.ENVELOPE_TAG
        ] as CFDictionary)
        let wrap = SecItemDelete([
            kSecClass as String:              kSecClassKey,
            kSecAttrApplicationTag as String: Self.WRAP_TAG.data(using: .utf8)!
        ] as CFDictionary)
        for (what, status) in [("envelope", envelope), ("wrap key", wrap)]
        where status != errSecSuccess && status != errSecItemNotFound {
            throw Err.native("SecItemDelete \(what): \(status)")
        }
        let left = SecItemCopyMatching([
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: Self.ENVELOPE_TAG
        ] as CFDictionary, nil)
        if left != errSecItemNotFound { throw Err.native("envelope survived deletion: \(left)") }
        if (try? loadWrapKey()) != nil { throw Err.native("wrap key survived deletion") }
    }

    // MARK:  Envelope plaintext format shared with Android

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
