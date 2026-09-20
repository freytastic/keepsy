package com.example.frontend

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ColorSpace
import android.graphics.Matrix
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.exifinterface.media.ExifInterface
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

// Decodes once and emits metadata-free full and thumbnail JPEGs
class ImageBridge : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "keepsy/image"
        private const val FULL_QUALITY = 90
        private const val THUMB_QUALITY = 82
        private const val THUMB_MIN_QUALITY = 60
        private const val THUMB_MAX_DIM = 640
        private const val THUMB_MIN_DIM = 320
        private const val THUMB_BUDGET = 420 * 1024
        // Stored photo cap
        private const val TARGET_PIXELS = 12_500_000L
        // Coarse decode cap before scaling exactly to TARGET_PIXELS
        private const val DECODE_CEILING = 40_000_000L
        private const val UNAVAILABLE = "E_UNAVAILABLE"
        private const val REJECTED = "E_REJECTED"
    }

    // A low-priority serial worker keeps codec work off the UI thread
    private val worker = Executors.newSingleThreadExecutor { r ->
        Thread({
            android.os.Process.setThreadPriority(
                android.os.Process.THREAD_PRIORITY_BACKGROUND
            )
            r.run()
        }, "keepsy-image").apply { isDaemon = true }
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "transcodeToJpeg") {
            result.notImplemented()
            return
        }
        val bytes = call.arguments as? ByteArray
        if (bytes == null || bytes.isEmpty()) {
            result.error(UNAVAILABLE, "no bytes", null)
            return
        }
        worker.execute {
            try {
                val out = transcode(bytes)
                mainHandler.post { result.success(out) }
            } catch (e: Unreadable) {
                // Unknown formats may still work in the Dart fallback
                mainHandler.post { result.error(UNAVAILABLE, e.message, null) }
            } catch (e: OutOfMemoryError) {
                // Never retry a known image with the uncapped Dart decoder
                mainHandler.post { result.error(REJECTED, "out of memory", null) }
            } catch (e: Exception) {
                mainHandler.post { result.error(REJECTED, e.message, null) }
            }
        }
    }

    private class Unreadable(message: String) : Exception(message)

    private fun transcode(bytes: ByteArray): Map<String, Any> {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
            throw Unreadable("no dimensions")
        }

        // Retry allocation failures at a lower resolution
        var sample = sampleSizeFor(bounds.outWidth, bounds.outHeight)
        var decoded: Bitmap? = null
        while (decoded == null) {
            val options = BitmapFactory.Options().apply {
                inSampleSize = sample
                inPreferredConfig = Bitmap.Config.ARGB_8888
                // Force sRGB so the encoder does not attach a color profile
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    inPreferredColorSpace = ColorSpace.get(ColorSpace.Named.SRGB)
                }
            }
            try {
                decoded = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
                    ?: throw Exception("decode returned nothing")
            } catch (e: OutOfMemoryError) {
                if (pixelsAt(bounds.outWidth, bounds.outHeight, sample) <= TARGET_PIXELS) {
                    throw e
                }
                sample *= 2
            }
        }
        // Remove the gainmap so output has one SDR image and no XMP or MPF
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE &&
            decoded.hasGainmap()
        ) {
            decoded.gainmap = null
        }

        var capped: Bitmap? = null
        var full: Bitmap? = null
        var thumbSrc: Bitmap? = null
        try {
            capped = capToTarget(decoded)
            // Bake orientation into pixels before dropping EXIF
            full = applyOrientation(capped, orientationOf(bytes))
            val fullJpeg = encode(full, FULL_QUALITY) ?: throw Exception("encode failed")
            thumbSrc = scaleLongEdge(full, THUMB_MAX_DIM)
            val thumbJpeg = encodeThumbUnderBudget(thumbSrc)
                ?: throw Exception("thumb encode failed")
            return mapOf(
                "file" to fullJpeg,
                "thumb" to thumbJpeg,
                "width" to full.width,
                "height" to full.height
            )
        } finally {
            if (thumbSrc !== full) thumbSrc?.recycle()
            if (full !== capped) full?.recycle()
            if (capped !== decoded) capped?.recycle()
            decoded.recycle()
        }
    }

    private fun encode(bitmap: Bitmap, quality: Int): ByteArray? {
        val out = ByteArrayOutputStream()
        if (!bitmap.compress(Bitmap.CompressFormat.JPEG, quality, out)) return null
        return out.toByteArray()
    }

    // Reduce quality before dimensions to meet the thumbnail limit
    private fun encodeThumbUnderBudget(src: Bitmap): ByteArray? {
        var image = src
        var quality = THUMB_QUALITY
        var scratch: Bitmap? = null
        try {
            while (true) {
                val bytes = encode(image, quality) ?: return null
                if (bytes.size <= THUMB_BUDGET) return bytes
                if (quality > THUMB_MIN_QUALITY) {
                    quality = maxOf(THUMB_MIN_QUALITY, quality - 8)
                    continue
                }
                val longEdge = maxOf(image.width, image.height)
                if (longEdge <= THUMB_MIN_DIM) return bytes
                val next = scaleLongEdge(image, longEdge * 3 / 4)
                if (next === image) return bytes
                scratch?.recycle()
                scratch = next
                image = next
                quality = THUMB_QUALITY
            }
        } finally {
            if (scratch !== src) scratch?.recycle()
        }
    }

    private fun scaleLongEdge(src: Bitmap, maxDim: Int): Bitmap {
        val longEdge = maxOf(src.width, src.height)
        if (longEdge <= maxDim) return src
        val scale = maxDim.toDouble() / longEdge
        val w = maxOf(1, (src.width * scale).toInt())
        val h = maxOf(1, (src.height * scale).toInt())
        return Bitmap.createScaledBitmap(src, w, h, true)
    }

    // Long avoids overflow from hostile dimensions
    private fun pixelsAt(width: Int, height: Int, sample: Int): Long =
        width.toLong() / sample * height.toLong() / sample

    private fun sampleSizeFor(width: Int, height: Int): Int {
        var sample = 1
        while (pixelsAt(width, height, sample) > DECODE_CEILING) {
            sample *= 2
        }
        return sample
    }

    // Scale the sampled bitmap to the exact storage cap
    private fun capToTarget(src: Bitmap): Bitmap {
        val pixels = src.width.toLong() * src.height.toLong()
        if (pixels <= TARGET_PIXELS) return src
        val ratio = kotlin.math.sqrt(TARGET_PIXELS.toDouble() / pixels)
        val w = maxOf(1, (src.width * ratio).toInt())
        val h = maxOf(1, (src.height * ratio).toInt())
        return Bitmap.createScaledBitmap(src, w, h, true)
    }

    private fun orientationOf(bytes: ByteArray): Int =
        try {
            ByteArrayInputStream(bytes).use {
                ExifInterface(it).getAttributeInt(
                    ExifInterface.TAG_ORIENTATION,
                    ExifInterface.ORIENTATION_NORMAL
                )
            }
        } catch (e: Exception) {
            ExifInterface.ORIENTATION_NORMAL
        }

    // Apply all EXIF orientations, including mirrors
    private fun applyOrientation(src: Bitmap, orientation: Int): Bitmap {
        val m = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> m.setScale(-1f, 1f)
            ExifInterface.ORIENTATION_ROTATE_180 -> m.setRotate(180f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> m.setScale(1f, -1f)
            ExifInterface.ORIENTATION_TRANSPOSE -> {
                m.setRotate(90f)
                m.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_ROTATE_90 -> m.setRotate(90f)
            ExifInterface.ORIENTATION_TRANSVERSE -> {
                m.setRotate(270f)
                m.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_ROTATE_270 -> m.setRotate(270f)
            else -> return src
        }
        return Bitmap.createBitmap(src, 0, 0, src.width, src.height, m, true)
    }
}
