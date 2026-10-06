package com.example.client

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.KeyStore
import java.security.SecureRandom
import java.util.concurrent.Executors
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec

// The Keystore wrapper key seals an envelope containing the app keys
class KeystoreBridge(private val ctx: Context) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "miuchio/keystore"
        private const val WRAP_ALIAS = "miuchio.wrap"
        private const val ENVELOPE_FILE = "miuchio_secure_store.bin"
        private const val GCM_TAG_BITS = 128
        private const val IV_BYTES = 12
        private const val HANDLE_BYTES = 16
    }

    private val ks: KeyStore by lazy {
        KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    }
    private val rng = SecureRandom()

    // One worker preserves envelope ordering without blocking the UI thread
    private val worker = Executors.newSingleThreadExecutor { r ->
        Thread(r, "miuchio-keystore").apply { isDaemon = true }
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    // Parse arguments before dispatch so failures keep their E_NATIVE mapping
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "initialize" -> dispatch(result) { initialize(); null }
                "put" -> {
                    val label = call.argument<String>("label")!!
                    val pt = call.argument<ByteArray>("plaintext")!!
                    dispatch(result) { mapOf("handleId" to put(label, pt)) }
                }

                "putMany" -> {
                    val entries = call.argument<List<Map<String, Any?>>>("entries")!!
                    dispatch(result) { putMany(entries).map { mapOf("handleId" to it) } }
                }

                "getOnce" -> {
                    val id = call.argument<String>("handleId")!!
                    dispatch(result) { mapOf("plaintext" to getOnce(id)) }
                }

                "delete" -> {
                    val id = call.argument<String>("handleId")!!
                    dispatch(result) { delete(id); null }
                }

                "list" -> {
                    val prefix = call.argument<String>("labelPrefix")
                    dispatch(result) {
                        list(prefix).map { mapOf("handleId" to it.first, "label" to it.second) }
                    }
                }

                "wipeAll" -> dispatch(result) { wipeAll(); null }
                "probe" -> dispatch(result) { probe() }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("E_NATIVE", e.message, e.stackTraceToString())
        }
    }

    private fun dispatch(result: MethodChannel.Result, work: () -> Any?) {
        worker.execute {
            try {
                val value = work()
                mainHandler.post { result.success(value) }
            } catch (e: TamperException) {
                mainHandler.post { result.error("E_KEY_TAMPER", e.message, null) }
            } catch (e: NotFoundException) {
                mainHandler.post { result.error("E_KEY_NOT_FOUND", e.message, null) }
            } catch (e: UninitializedException) {
                mainHandler.post { result.error("E_STORE_UNINITIALIZED", e.message, null) }
            } catch (e: Exception) {
                mainHandler.post { result.error("E_NATIVE", e.message, e.stackTraceToString()) }
            }
        }
    }

    private fun initialize() {
        if (ks.containsAlias(WRAP_ALIAS)) return

        val kg = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        val builder = KeyGenParameterSpec.Builder(
            WRAP_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .setUserAuthenticationRequired(false)

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

    private fun putMany(entries: List<Map<String, Any?>>): List<String> {
        val map = loadMap()
        val ids = ArrayList<String>(entries.size)
        for (e in entries) {
            val label = e["label"] as String
            val pt = e["plaintext"] as ByteArray
            val id = randomHex(HANDLE_BYTES)
            map[id] = label to pt
            ids.add(id)
        }
        saveMap(map)
        return ids
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

    private fun probe(): Map<String, Any?> {
        if (!ks.containsAlias(WRAP_ALIAS)) return mapOf("initialized" to false)
        val key = (ks.getEntry(WRAP_ALIAS, null) as KeyStore.SecretKeyEntry).secretKey
        val info = SecretKeyFactory.getInstance(key.algorithm, "AndroidKeyStore")
            .getKeySpec(key, KeyInfo::class.java) as KeyInfo
        val level = if (Build.VERSION.SDK_INT >= 31) {
            when (info.securityLevel) {
                KeyProperties.SECURITY_LEVEL_STRONGBOX -> "strongbox"
                KeyProperties.SECURITY_LEVEL_TRUSTED_ENVIRONMENT -> "tee"
                KeyProperties.SECURITY_LEVEL_SOFTWARE -> "software"
                else -> "unknown"
            }
        } else {
            @Suppress("DEPRECATION")
            if (info.isInsideSecureHardware) "hardware" else "software"
        }
        val loads = (0 until 3).map {
            val t = System.nanoTime()
            loadMap()
            (System.nanoTime() - t) / 1_000_000.0
        }
        return mapOf(
            "initialized" to true,
            "level" to level,
            "envelopeBytes" to File(ctx.filesDir, ENVELOPE_FILE).length(),
            "entries" to loadMap().size,
            "loadMs" to loads,
        )
    }

    private fun wipeAll() {
        // Report incomplete wipes so account deletion can retry
        for (name in listOf(ENVELOPE_FILE, "$ENVELOPE_FILE.tmp")) {
            val f = File(ctx.filesDir, name)
            if (f.exists() && !f.delete()) throw IllegalStateException("could not delete $name")
        }
        if (ks.containsAlias(WRAP_ALIAS)) ks.deleteEntry(WRAP_ALIAS)
        if (ks.containsAlias(WRAP_ALIAS)) throw IllegalStateException("wrapper key survived deletion")
    }

    // Only the wrapper key stays in Keystore, app keys return to memory
    private fun loadMap(): MutableMap<String, Pair<String, ByteArray>> {
        if (!ks.containsAlias(WRAP_ALIAS)) throw UninitializedException("wrapper key absent")
        val f = File(ctx.filesDir, ENVELOPE_FILE)
        if (!f.exists()) return mutableMapOf()

        val raw = f.readBytes()
        val iv = raw.copyOfRange(0, IV_BYTES)
        val ct = raw.copyOfRange(IV_BYTES, raw.size)
        val key = (ks.getEntry(WRAP_ALIAS, null) as KeyStore.SecretKeyEntry).secretKey

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

    private fun saveMap(map: Map<String, Pair<String, ByteArray>>) {
        if (!ks.containsAlias(WRAP_ALIAS)) throw UninitializedException("wrapper key absent")
        val pt = encode(map)
        val key = (ks.getEntry(WRAP_ALIAS, null) as KeyStore.SecretKeyEntry).secretKey

        // Let Android Keystore generate the GCM IV
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key)
        val iv = cipher.iv
        val ct = cipher.doFinal(pt)

        val out = ByteArray(iv.size + ct.size)
        System.arraycopy(iv, 0, out, 0, iv.size)
        System.arraycopy(ct, 0, out, iv.size, ct.size)

        val tmp = File(ctx.filesDir, "$ENVELOPE_FILE.tmp")
        tmp.writeBytes(out)
        // Replace the envelope atomically
        if (!tmp.renameTo(File(ctx.filesDir, ENVELOPE_FILE)))
            throw RuntimeException("atomic rename failed")
    }

    // Shared with iOS: count:u16 BE followed by entries
    // Entry: idLen:u8, id:ASCII, labelLen:u16 BE, label:UTF-8, valLen:u16 BE, val:bytes
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
