package com.example.frontend

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.spec.GCMParameterSpec

//  It uses the Android Keystore system to protect a master "wrapper" key,
// which in turn encrypts an "envelope" file containing the actual private keys
class KeystoreBridge(private val ctx: Context) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "keepsy/keystore"
        private const val WRAP_ALIAS = "keepsy.wrap"
        private const val ENVELOPE_FILE = "keepsy_secure_store.bin"
        private const val GCM_TAG_BITS = 128
        private const val IV_BYTES = 12
        private const val HANDLE_BYTES = 16
    }

    private val ks: KeyStore by lazy {
        KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    }
    private val rng = SecureRandom()

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "initialize" -> { initialize(); result.success(null) }
                "put" -> {
                    val label = call.argument<String>("label")!!
                    val pt = call.argument<ByteArray>("plaintext")!!
                    result.success(mapOf("handleId" to put(label, pt)))
                }
                "getOnce" -> {
                    val id = call.argument<String>("handleId")!!
                    result.success(mapOf("plaintext" to getOnce(id)))
                }
                "delete" -> {
                    val id = call.argument<String>("handleId")!!
                    delete(id); result.success(null)
                }
                "list" -> {
                    val prefix = call.argument<String>("labelPrefix")
                    result.success(list(prefix).map { mapOf("handleId" to it.first, "label" to it.second) })
                }
                "wipeAll" -> { wipeAll(); result.success(null) }
                else -> result.notImplemented()
            }
        } catch (e: TamperException)         { result.error("E_KEY_TAMPER", e.message, null) }
        catch (e: NotFoundException)         { result.error("E_KEY_NOT_FOUND", e.message, null) }
        catch (e: UninitializedException)    { result.error("E_STORE_UNINITIALIZED", e.message, null) }
        catch (e: Exception)                 { result.error("E_NATIVE", e.message, e.stackTraceToString()) }
    }

    private fun initialize() {
        if (ks.containsAlias(WRAP_ALIAS)) return

        // Generate a hardware backed AES-GCM key for wrapping the envelope
        val kg = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        val builder = KeyGenParameterSpec.Builder(
            WRAP_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .setUserAuthenticationRequired(false)

        // Use StrongBox (dedicated HSM) if available (Android 9+)
        // fallback to TEE if not supported on this specific hardware
        val wantStrongBox = Build.VERSION.SDK_INT >= 28 &&
            ctx.packageManager.hasSystemFeature(PackageManager.FEATURE_STRONGBOX_KEYSTORE)
        if (wantStrongBox) builder.setIsStrongBoxBacked(true)

        try {
            kg.init(builder.build()); kg.generateKey()
        } catch (e: StrongBoxUnavailableException) {
            kg.init(builder.setIsStrongBoxBacked(false).build()); kg.generateKey()
        }
    }

    private fun put(label: String, plaintext: ByteArray): String {
        val map = loadMap()
        val id = randomHex(HANDLE_BYTES)
        map[id] = label to plaintext
        saveMap(map)
        return id
    }

    private fun getOnce(handleId: String): ByteArray {
        val map = loadMap()
        return map[handleId]?.second ?: throw NotFoundException("no such handle $handleId")
    }

    private fun delete(handleId: String) {
        val map = loadMap()
        if (map.remove(handleId) == null) throw NotFoundException("no such handle $handleId")
        saveMap(map)
    }

    private fun list(prefix: String?): List<Pair<String, String>> {
        return loadMap().entries
            .filter { prefix == null || it.value.first.startsWith(prefix) }
            .map { it.key to it.value.first }
    }

    private fun wipeAll() {
        // Shred the data file and the hardware backed wrapper key
        File(ctx.filesDir, ENVELOPE_FILE).delete()
        if (ks.containsAlias(WRAP_ALIAS)) ks.deleteEntry(WRAP_ALIAS)
    }

     //Reads the encrypted envelope from disk and decrypts it using the master key

     // The master key material stays inside the TEE/StrongBox : the main CPU only
     // sees the decrypted "envelope" contents
    private fun loadMap(): MutableMap<String, Pair<String, ByteArray>> {
        if (!ks.containsAlias(WRAP_ALIAS)) throw UninitializedException("wrapper key absent")
        val f = File(ctx.filesDir, ENVELOPE_FILE)
        if (!f.exists()) return mutableMapOf()

        val raw = f.readBytes()
        val iv = raw.copyOfRange(0, IV_BYTES)
        val ct = raw.copyOfRange(IV_BYTES, raw.size)
        val key = (ks.getEntry(WRAP_ALIAS, null) as KeyStore.SecretKeyEntry).secretKey

        // Decrypt with AES-GCM. GCM provides AEAD, meaning the 16 byte tag
        // ensures the file hasnt been tampered with
        val pt = try {
            Cipher.getInstance("AES/GCM/NoPadding").run {
                init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(GCM_TAG_BITS, iv))
                doFinal(ct)
            }
        } catch (e: javax.crypto.AEADBadTagException) {
            throw TamperException("envelope auth tag invalid")
        }
        return decode(pt)
    }

     // Encrypts and saves the envelope
     // Uses an atomic rename pattern to ensure file integrity on crash
    private fun saveMap(map: Map<String, Pair<String, ByteArray>>) {
        if (!ks.containsAlias(WRAP_ALIAS)) throw UninitializedException("wrapper key absent")
        val pt = encode(map)
        val iv = ByteArray(IV_BYTES).also(rng::nextBytes)
        val key = (ks.getEntry(WRAP_ALIAS, null) as KeyStore.SecretKeyEntry).secretKey

        val ct = Cipher.getInstance("AES/GCM/NoPadding").run {
            init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(GCM_TAG_BITS, iv))
            doFinal(pt)
        }

        val out = ByteArray(IV_BYTES + ct.size)
        System.arraycopy(iv, 0, out, 0, IV_BYTES)
        System.arraycopy(ct, 0, out, IV_BYTES, ct.size)

        val tmp = File(ctx.filesDir, "$ENVELOPE_FILE.tmp")
        tmp.writeBytes(out)
        // Atomic rename ensures we dont leave a half written file on crash/power loss
        if (!tmp.renameTo(File(ctx.filesDir, ENVELOPE_FILE)))
            throw RuntimeException("atomic rename failed")
    }

     //Custom binary format for cross platform parity with iOS
     //[count: u16 BE]
     //For each: [idLen: u8] [id: ASCII] [labelLen: u16 BE] [label: UTF-8] [valLen: u16 BE] [val: bytes]
    private fun encode(map: Map<String, Pair<String, ByteArray>>): ByteArray {
        val bb = ByteBuffer.allocate(estimateSize(map)).order(ByteOrder.BIG_ENDIAN)
        bb.putShort(map.size.toShort())
        for ((id, lv) in map) {
            val idB = id.toByteArray(Charsets.US_ASCII)
            val labelB = lv.first.toByteArray(Charsets.UTF_8)
            bb.put(idB.size.toByte())
            bb.put(idB)
            bb.putShort(labelB.size.toShort())
            bb.put(labelB)
            bb.putShort(lv.second.size.toShort())
            bb.put(lv.second)
        }
        return bb.array().copyOf(bb.position())
    }

    private fun decode(blob: ByteArray): MutableMap<String, Pair<String, ByteArray>> {
        val bb = ByteBuffer.wrap(blob).order(ByteOrder.BIG_ENDIAN)
        val n = bb.short.toInt() and 0xFFFF
        val out = LinkedHashMap<String, Pair<String, ByteArray>>(n)
        repeat(n) {
            val idLen = bb.get().toInt() and 0xFF
            val idB = ByteArray(idLen).also(bb::get)
            val labelLen = bb.short.toInt() and 0xFFFF
            val labelB = ByteArray(labelLen).also(bb::get)
            val valLen = bb.short.toInt() and 0xFFFF
            val valB = ByteArray(valLen).also(bb::get)
            out[String(idB, Charsets.US_ASCII)] = String(labelB, Charsets.UTF_8) to valB
        }
        return out
    }

    private fun estimateSize(map: Map<String, Pair<String, ByteArray>>): Int {
        var n = 2
        for ((id, lv) in map) n += 1 + id.length + 2 + lv.first.toByteArray(Charsets.UTF_8).size + 2 + lv.second.size
        return n
    }

    private fun randomHex(n: Int): String {
        val b = ByteArray(n).also(rng::nextBytes)
        return b.joinToString("") { "%02x".format(it) }
    }

    private class TamperException(msg: String) : RuntimeException(msg)
    private class NotFoundException(msg: String) : RuntimeException(msg)
    private class UninitializedException(msg: String) : RuntimeException(msg)
}
