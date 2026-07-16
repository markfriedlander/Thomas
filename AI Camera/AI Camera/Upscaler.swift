//
//  Upscaler.swift
//  AI Camera
//
//  Making the drawing bigger, after the model has drawn it.
//
//  The hand draws at 512×512 — sd-turbo's native size, and the size that keeps the VAE decode
//  inside the memory budget (see HISTORY 2026-07-16: the decode is the spike, and it grows
//  with resolution). 512 is small next to a photograph (4032×3024) and below Instagram's
//  ~1080. So the enlarging happens **here, after the draw**, where it is cheap and never
//  touches the model's memory: a plain image resize, either Apple's GPU upscaler (MetalFX) or
//  Core Image.
//
//  Mark's design, 2026-07-16: *"add an option for metal FX to upscale... maybe we have both
//  core image and metal FX as options. User gets a choice. And gets a resolution choice as
//  well."* And on memory: *"I don't know if we should generate at 768 without tiling just
//  because I really don't wanna push our luck."* So: generate at 512, enlarge afterward. The
//  model is never asked for more than it can safely make.
//

import CoreGraphics
import CoreImage
import Foundation
import Metal
import MetalFX

// ==== LEGO START: 31 The Upscaler (Making The Drawing Bigger) ====

/// How large the drawing is saved. The long edge, in pixels.
///
/// `native` is the honest baseline — 512, exactly what the model drew, no enlarging. The
/// larger sizes upscale after the fact.
nonisolated enum DrawingSize: String, CaseIterable, Hashable, Sendable {
    case native      // 512 — what the model actually made
    case instagram   // 1080 — Instagram's standard
    case large       // 2048

    var pixels: Int {
        switch self {
        case .native:    return 512
        case .instagram: return 1080
        case .large:     return 2048
        }
    }

    var name: String {
        switch self {
        case .native:    return "Native (512)"
        case .instagram: return "Instagram (1080)"
        case .large:     return "Large (2048)"
        }
    }
}

/// Which upscaler enlarges the drawing.
nonisolated enum UpscaleMethod: String, CaseIterable, Hashable, Sendable {
    /// Apple's GPU spatial upscaler. Sharper. Available A13+ (every Apple-Intelligence device
    /// is A17 Pro+), but gated at runtime by `supportsDevice` — falls back to Core Image if a
    /// device somehow says no.
    case metalFX
    /// Core Image / Lanczos. Always available. Softer — it interpolates, it doesn't invent
    /// detail — which on a dreamy re-imagining may read as intentional.
    case coreImage

    var name: String {
        switch self {
        case .metalFX:   return "MetalFX (sharper)"
        case .coreImage: return "Core Image (softer)"
        }
    }
}

nonisolated enum Upscaler {

    /// Enlarge `image` so its long edge is `size.pixels`, using `method` (with MetalFX falling
    /// back to Core Image). Returns the image unchanged for `.native`, for an image already at
    /// or above the target, or if upscaling fails — a shot that lands at 512 beats one that
    /// doesn't land.
    static func enlarge(_ image: CGImage, to size: DrawingSize, method: UpscaleMethod) -> CGImage {
        guard size != .native else { return image }
        let longEdge = max(image.width, image.height)
        let target = size.pixels
        guard target > longEdge else { return image }
        let scale = Double(target) / Double(longEdge)
        let outW = Int((Double(image.width) * scale).rounded())
        let outH = Int((Double(image.height) * scale).rounded())

        let started = Date()
        let result: CGImage?
        let used: String
        switch method {
        case .metalFX:
            if let m = metalFX(image, width: outW, height: outH) {
                result = m; used = "metalFX"
            } else {
                // The fallback that makes the runtime gate honest — never assert a device
                // supports MetalFX; if it doesn't, Core Image always does.
                result = coreImage(image, width: outW, height: outH); used = "coreImage(fallback)"
            }
        case .coreImage:
            result = coreImage(image, width: outW, height: outH); used = "coreImage"
        }

        if let result {
            cameraLog("UPSCALE: \(image.width)×\(image.height) → \(result.width)×\(result.height) via \(used) in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
            return result
        }
        cameraLog("UPSCALE: failed (\(used)); keeping native \(image.width)×\(image.height)")
        return image
    }

    /// Whether this device supports MetalFX spatial scaling. Asked, never assumed.
    static func metalFXSupported() -> Bool {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        return MTLFXSpatialScalerDescriptor.supportsDevice(device)
    }

    // MARK: - Core Image (always available)

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private static func coreImage(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        let ci = CIImage(cgImage: image)
        // Lanczos: the good interpolator, not nearest/bilinear.
        guard let filter = CIFilter(name: "CILanczosScaleTransform") else { return nil }
        filter.setValue(ci, forKey: kCIInputImageKey)
        filter.setValue(Double(width) / Double(image.width), forKey: kCIInputScaleKey)
        filter.setValue(1.0, forKey: kCIInputAspectRatioKey)
        guard let output = filter.outputImage else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        return ciContext.createCGImage(output, from: rect)
    }

    // MARK: - MetalFX (GPU, A13+)

    private static func metalFX(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let device = MTLCreateSystemDefaultDevice(),
              MTLFXSpatialScalerDescriptor.supportsDevice(device),
              let queue = device.makeCommandQueue() else { return nil }

        let fmt: MTLPixelFormat = .rgba8Unorm

        // Input texture, filled from the CGImage.
        let inDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: fmt, width: image.width, height: image.height, mipmapped: false)
        inDesc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let inTex = device.makeTexture(descriptor: inDesc),
              let rgba = rgbaBytes(image) else { return nil }
        rgba.withUnsafeBytes { raw in
            inTex.replace(region: MTLRegionMake2D(0, 0, image.width, image.height),
                          mipmapLevel: 0,
                          withBytes: raw.baseAddress!,
                          bytesPerRow: image.width * 4)
        }

        // Output texture.
        let outDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: fmt, width: width, height: height, mipmapped: false)
        outDesc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        outDesc.storageMode = .shared
        guard let outTex = device.makeTexture(descriptor: outDesc) else { return nil }

        // The scaler.
        let desc = MTLFXSpatialScalerDescriptor()
        desc.inputWidth = image.width
        desc.inputHeight = image.height
        desc.outputWidth = width
        desc.outputHeight = height
        desc.colorTextureFormat = fmt
        desc.outputTextureFormat = fmt
        desc.colorProcessingMode = .perceptual
        guard let scaler = desc.makeSpatialScaler(device: device),
              let cmd = queue.makeCommandBuffer() else { return nil }
        scaler.colorTexture = inTex
        scaler.outputTexture = outTex
        scaler.encode(commandBuffer: cmd)
        cmd.commit()
        cmd.waitUntilCompleted()

        return cgImage(from: outTex, width: width, height: height)
    }

    // MARK: - CGImage ↔ bytes

    /// RGBA8 bytes of a CGImage, in a fresh premultiplied-last context so the pixel layout
    /// matches `rgba8Unorm` regardless of the source image's own format.
    private static func rgbaBytes(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return bytes
    }

    private static func cgImage(from texture: MTLTexture, width: Int, height: Int) -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!,
                             bytesPerRow: width * 4,
                             from: MTLRegionMake2D(0, 0, width, height),
                             mipmapLevel: 0)
        }
        guard let ctx = CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        return ctx.makeImage()
    }
}

// ==== LEGO END: 31 The Upscaler (Making The Drawing Bigger) ====
