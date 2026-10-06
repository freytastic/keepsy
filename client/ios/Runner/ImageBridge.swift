import Foundation
import Flutter
import ImageIO
import CoreGraphics

// Decodes once and emits metadata-free full and thumbnail JPEGs, matching the
// Android ImageBridge sizes, qualities and error codes
final class ImageBridge: NSObject, FlutterPlugin {
    static let CHANNEL = "miuchio/image"
    private static let FULL_QUALITY: CGFloat = 0.90
    private static let THUMB_QUALITY = 82
    private static let THUMB_MIN_QUALITY = 60
    private static let THUMB_MAX_DIM = 640
    private static let THUMB_MIN_DIM = 320
    private static let THUMB_BUDGET = 420 * 1024
    private static let TARGET_PIXELS = 12_500_000.0
    private static let UNAVAILABLE = "E_UNAVAILABLE"
    private static let REJECTED = "E_REJECTED"

    // A low-priority serial queue keeps codec work off the UI thread
    private let queue = DispatchQueue(label: "miuchio.image", qos: .utility)

    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: CHANNEL, binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(ImageBridge(), channel: channel)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard call.method == "transcodeToJpeg" else {
            result(FlutterMethodNotImplemented)
            return
        }
        guard let bytes = (call.arguments as? FlutterStandardTypedData)?.data, !bytes.isEmpty else {
            result(FlutterError(code: Self.UNAVAILABLE, message: "no bytes", details: nil))
            return
        }
        queue.async {
            let reply: Any
            do {
                reply = try autoreleasepool { try self.transcode(bytes) }
            } catch Failure.unreadable(let m) {
                // Unknown formats may still work in the Dart fallback
                reply = FlutterError(code: Self.UNAVAILABLE, message: m, details: nil)
            } catch {
                reply = FlutterError(code: Self.REJECTED, message: "\(error)", details: nil)
            }
            DispatchQueue.main.async { result(reply) }
        }
    }

    private enum Failure: Error {
        case unreadable(String)
        case failed(String)
    }

    private func transcode(_ bytes: Data) throws -> [String: Any] {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(bytes as CFData, options as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { throw Failure.unreadable("no dimensions") }

        // Downsample while decoding and bake orientation into the pixels
        let pixels = Double(width) * Double(height)
        let scale = min(1.0, (Self.TARGET_PIXELS / pixels).squareRoot())
        let maxEdge = max(1, Int((Double(max(width, height)) * scale).rounded(.down)))
        let decodeOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxEdge,
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, decodeOptions as CFDictionary) else {
            throw Failure.failed("decode returned nothing")
        }

        // Redraw in sRGB so wide-gamut photos keep their colours once the
        // colour profile is stripped with the rest of the metadata
        let full = try redraw(decoded, width: decoded.width, height: decoded.height)
        let fullJpeg = try encode(full, quality: Self.FULL_QUALITY)
        let thumbSrc = try scaleLongEdge(full, to: Self.THUMB_MAX_DIM)
        let thumbJpeg = try encodeThumbUnderBudget(thumbSrc)
        return [
            "file": FlutterStandardTypedData(bytes: fullJpeg),
            "thumb": FlutterStandardTypedData(bytes: thumbJpeg),
            "width": full.width,
            "height": full.height,
        ]
    }

    private func redraw(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { throw Failure.failed("no drawing context") }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let out = ctx.makeImage() else { throw Failure.failed("draw failed") }
        return out
    }

    private func scaleLongEdge(_ image: CGImage, to maxDim: Int) throws -> CGImage {
        let longEdge = max(image.width, image.height)
        if longEdge <= maxDim { return image }
        let scale = Double(maxDim) / Double(longEdge)
        let w = max(1, Int(Double(image.width) * scale))
        let h = max(1, Int(Double(image.height) * scale))
        return try redraw(image, width: w, height: h)
    }

    private func encode(_ image: CGImage, quality: CGFloat) throws -> Data {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out as CFMutableData, "public.jpeg" as CFString, 1, nil
        ) else { throw Failure.failed("no encoder") }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw Failure.failed("encode failed") }
        return out as Data
    }

    // Reduce quality before dimensions to meet the thumbnail limit
    private func encodeThumbUnderBudget(_ src: CGImage) throws -> Data {
        var image = src
        var quality = Self.THUMB_QUALITY
        while true {
            let bytes = try encode(image, quality: CGFloat(quality) / 100)
            if bytes.count <= Self.THUMB_BUDGET { return bytes }
            if quality > Self.THUMB_MIN_QUALITY {
                quality = max(Self.THUMB_MIN_QUALITY, quality - 8)
                continue
            }
            let longEdge = max(image.width, image.height)
            if longEdge <= Self.THUMB_MIN_DIM { return bytes }
            let next = try scaleLongEdge(image, to: longEdge * 3 / 4)
            if next === image { return bytes }
            image = next
            quality = Self.THUMB_QUALITY
        }
    }
}
