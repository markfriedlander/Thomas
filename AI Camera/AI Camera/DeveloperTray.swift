//
//  DeveloperTray.swift
//  AI Camera
//
//  The Developer Tray's machinery (Thomas 1.1, begun 2026-11-05): a per-step trace of the drawing,
//  turned into pictures with TAESD, and the two keepsakes a shot can also save to Photos, a contact
//  sheet and a flipbook video.
//
//  Real data only (Mark, 2026-11-04, non-negotiable). Every frame is the drawing engine's actual
//  latent at that step, not an animation made to look like one. What a frame is gets said on the
//  frame: which view (the working image, or the engine's best guess), and that the in-between
//  pictures are quick TAESD previews while the last tile is the finished, full-quality drawing.
//

import AVFoundation
import Foundation
import MLX
import UIKit

// ==== LEGO START: 37 The Developer Tray (Trace, Contact Sheet, Flipbook) ====

/// Which of two true things the drawing engine reports at each step. Chosen in Preferences and frozen
/// per shot (Mark, 2026-11-05: "the user could choose... we wouldn't run both simultaneously").
nonisolated enum DevelopView: String, CaseIterable, Codable, Sendable {
    /// The engine's actual working latent: static that slowly becomes a picture.
    case working
    /// The engine's current prediction of the finished picture: blurry at first, sharpening.
    /// Only the Core ML hand exposes this; the MLX hand falls back to `.working` and says so.
    case guess

    var name: String {
        switch self {
        case .working: return "The working image"
        case .guess:   return "Its best guess"
        }
    }
}

/// What a shot also saves to Photos about its own development. Off costs nothing (no decode, no
/// render), per Mark's rule: never needless processing, but every option available.
nonisolated enum DevelopmentKeepsake: String, CaseIterable, Codable, Sendable {
    case off, contactSheet, flipbook, both

    var name: String {
        switch self {
        case .off:          return "Off"
        case .contactSheet: return "Contact sheet"
        case .flipbook:     return "Flipbook"
        case .both:         return "Both"
        }
    }
    var wantsSheet: Bool { self == .contactSheet || self == .both }
    var wantsFlipbook: Bool { self == .flipbook || self == .both }
}

/// The developing frames of the most recent draw: the real latent the engine held at every step.
/// Small on purpose: a 20-step Core ML shot is 21 x 16,384 floats (~1.3 MB), overwritten by the next.
/// A lock, not an actor, because both engines report steps synchronously.
nonisolated final class DevelopTrace: @unchecked Sendable {
    static let shared = DevelopTrace()
    private let lock = NSLock()

    struct Snapshot: Sendable {
        let prompt: String
        let steps: Int
        let isGuess: Bool          // what was actually captured, not what was asked for
        let channelsLast: Bool     // MLX hand: [1, H, W, 4]; Core ML hand: [1, 4, H, W]
        let hand: String           // display name of the drawing model
        let shape: [Int]
        let latents: [[Float]]     // one per completed step, in order
    }

    private var current: Snapshot?

    /// Forget the previous draw, so a shot that draws nothing can never pick up another shot's trace.
    func reset() { lock.withLock { current = nil } }

    func begin(prompt: String, steps: Int, isGuess: Bool, channelsLast: Bool, hand: String) {
        lock.withLock {
            current = Snapshot(prompt: prompt, steps: steps, isGuess: isGuess,
                               channelsLast: channelsLast, hand: hand, shape: [], latents: [])
        }
    }

    func record(_ values: [Float], shape: [Int]) {
        lock.withLock {
            guard let c = current else { return }
            current = Snapshot(prompt: c.prompt, steps: c.steps, isGuess: c.isGuess,
                               channelsLast: c.channelsLast, hand: c.hand, shape: shape,
                               latents: c.latents + [values])
        }
    }

    func snapshot() -> Snapshot? { lock.withLock { current } }
}

/// A trace turned into pictures. `@unchecked Sendable` only so it can leave the model lane; the
/// images are immutable once made.
nonisolated struct DevelopFrames: @unchecked Sendable {
    let images: [CGImage]
    let steps: [Int]          // which step each image is (1-based)
    let totalSteps: Int
    let isGuess: Bool
    let hand: String

    /// The label every keepsake carries, so nobody mistakes a preview for the finished drawing.
    var viewName: String { isGuess ? DevelopView.guess.name : DevelopView.working.name }
}

nonisolated enum DeveloperTray {

    /// Decode a trace to pictures with TAESD, the quick previews it was invented for. This is model
    /// work (GPU), so callers run it inside `ModelLane`. `every` keeps every nth step (the last is
    /// always kept).
    static func decode(_ t: DevelopTrace.Snapshot, every: Int = 1) -> DevelopFrames? {
        guard !t.latents.isEmpty, t.shape.count == 4,
              let taesd = try? TAESDDecoder.bundled() else { return nil }
        let n = t.latents.count
        var images: [CGImage] = []
        var steps: [Int] = []
        for (i, values) in t.latents.enumerated() where (i + 1) % max(1, every) == 0 || i == n - 1 {
            var z = MLXArray(values, t.shape)
            if !t.channelsLast { z = z.transposed(0, 2, 3, 1) }   // [1,4,H,W] -> [1,H,W,4]
            let raster = (taesd.decodePixels(z) * 255).asType(.uint8).squeezed()
            eval(raster)
            images.append(SDImage(raster).asCGImage())
            steps.append(i + 1)
        }
        MLX.Memory.clearCache()
        return DevelopFrames(images: images, steps: steps, totalSteps: n,
                             isGuess: t.isGuess, hand: t.hand)
    }
}

@MainActor
extension DeveloperTray {

    /// Every step in a grid, then the finished drawing as the last tile, in Thomas's grammar: black
    /// ground, a title bar that names the view, and the place/date footer every frame carries.
    static func contactSheet(_ f: DevelopFrames, final: CGImage?, place: String?, date: Date) -> UIImage {
        var tiles: [(CGImage, String)] = zip(f.images, f.steps).map { ($0, "\($1)") }
        if let final { tiles.append((final, "saved")) }

        let cols = Int(ceil(Double(tiles.count).squareRoot()))
        let rows = Int(ceil(Double(tiles.count) / Double(cols)))
        let tile: CGFloat = 300
        let gutter: CGFloat = 10
        let margin: CGFloat = 24
        let width = margin * 2 + CGFloat(cols) * tile + CGFloat(cols - 1) * gutter
        let titleBar = (width * 0.075).rounded()
        let footerBar = (width * 0.07).rounded()
        let height = titleBar + CGFloat(rows) * tile + CGFloat(rows - 1) * gutter + footerBar
        let canvas = CGSize(width: width, height: height)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: canvas, format: format).image { ctx in
            UIColor.black.setFill()
            ctx.cgContext.fill(CGRect(origin: .zero, size: canvas))

            let titleSize = width * 0.022
            let title = "\(f.viewName) · \(f.totalSteps) steps · \(f.hand)" as NSString
            title.draw(at: CGPoint(x: margin, y: titleBar * 0.22),
                       withAttributes: [.font: UIFont.systemFont(ofSize: titleSize, weight: .semibold),
                                        .foregroundColor: UIColor.white])
            let note = "Each step is a quick preview. The last tile is the finished drawing." as NSString
            note.draw(at: CGPoint(x: margin, y: titleBar * 0.22 + titleSize * 1.35),
                      withAttributes: [.font: UIFont.systemFont(ofSize: titleSize * 0.7),
                                       .foregroundColor: UIColor(white: 0.7, alpha: 1)])

            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: tile * 0.07, weight: .semibold),
                .foregroundColor: UIColor.white,
            ]
            for (i, (img, label)) in tiles.enumerated() {
                let r = CGRect(x: margin + CGFloat(i % cols) * (tile + gutter),
                               y: titleBar + CGFloat(i / cols) * (tile + gutter),
                               width: tile, height: tile)
                UIImage(cgImage: img).draw(in: r)
                let text = label as NSString
                let ts = text.size(withAttributes: labelAttrs)
                let chip = CGRect(x: r.minX + 6, y: r.minY + 6, width: ts.width + 12, height: ts.height + 4)
                UIColor(white: 0, alpha: 0.55).setFill()
                UIBezierPath(roundedRect: chip, cornerRadius: chip.height / 2).fill()
                text.draw(at: CGPoint(x: chip.minX + 6, y: chip.minY + 2), withAttributes: labelAttrs)
            }

            Darkroom.drawFooter(place: place, date: date, in: ctx.cgContext, canvas: canvas,
                                bar: footerBar, margin: margin, size: width * 0.018)
        }
    }

    /// The steps as a short video, ending on the finished drawing held for a moment. Each frame
    /// carries the same grammar as the sheet: title bar naming the view and step, footer stamp.
    /// A video rather than a GIF: it plays smoothly in Photos, shares anywhere, and looks sharper.
    static func flipbook(_ f: DevelopFrames, final: CGImage?, place: String?, date: Date) async throws -> URL {
        let side: CGFloat = 720
        let titleBar: CGFloat = 64
        let footerBar: CGFloat = 80
        let canvas = CGSize(width: side, height: side + titleBar + footerBar)   // 720 x 864, both even

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: canvas, format: format)

        func frame(_ image: CGImage, title: String) -> CGImage? {
            renderer.image { ctx in
                UIColor.black.setFill()
                ctx.cgContext.fill(CGRect(origin: .zero, size: canvas))
                (title as NSString).draw(
                    at: CGPoint(x: 24, y: titleBar * 0.3),
                    withAttributes: [.font: UIFont.monospacedDigitSystemFont(ofSize: 22, weight: .semibold),
                                     .foregroundColor: UIColor.white])
                UIImage(cgImage: image).draw(in: CGRect(x: 0, y: titleBar, width: side, height: side))
                Darkroom.drawFooter(place: place, date: date, in: ctx.cgContext, canvas: canvas,
                                    bar: footerBar, margin: 24, size: 20)
            }.cgImage
        }

        var frames: [CGImage] = []
        var durations: [Double] = []
        for (img, step) in zip(f.images, f.steps) {
            if let c = frame(img, title: "Step \(step) of \(f.totalSteps) · \(f.viewName.lowercased())") {
                frames.append(c); durations.append(0.3)
            }
        }
        if let final, let c = frame(final, title: "The finished drawing") {
            frames.append(c); durations.append(2.5)
        }
        return try await writeVideo(FrameBox(frames: frames), durations: durations, size: canvas)
    }

    private struct FrameBox: @unchecked Sendable { let frames: [CGImage] }

    /// H.264 into a temp .mp4, off the main actor, on the iOS 27 writer API (a pixel-buffer receiver
    /// with async append; the older adaptor/isReadyForMoreMediaData path is deprecated in iOS 27).
    /// Variable frame durations come from the presentation times.
    nonisolated private static func writeVideo(_ box: FrameBox, durations: [Double],
                                               size: CGSize) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("thomas-flipbook-\(UUID().uuidString).mp4")
        let width = Int(size.width), height = Int(size.height)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        let attributes = CVPixelBufferCreationAttributes(
            pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_32BGRA),
            size: CVImageSize(width: width, height: height))
        let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: attributes)
        try writer.start()
        writer.startSession(atSourceTime: .zero)

        // The receiver's own pool when it offers one, else one built from the same attributes. Chosen
        // up front because the buffers are move-only (`~Copyable`), which `??` cannot hand back.
        let pool = try receiver.pixelBufferPool
            ?? CVMutablePixelBuffer.Pool(pixelBufferAttributes: attributes)
        func append(_ image: CGImage, at time: CMTime) async throws {
            var buffer = try pool.makeMutablePixelBuffer()
            buffer.accessUnsafeMutableRawPlaneBytes { planes in
                guard let plane = planes.first,
                      let ctx = CGContext(data: plane.bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: plane.properties.bytesPerRow,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                              | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            try await receiver.append(CVReadOnlyPixelBuffer(buffer), with: time)
        }

        var t = CMTime.zero
        for (image, seconds) in zip(box.frames, durations) {
            try await append(image, at: t)
            t = t + CMTime(seconds: seconds, preferredTimescale: 600)
        }
        // A video file does not record how long its LAST frame lasts, so players show it for about
        // one frame. Repeat the final image just before the end so its hold (the finished drawing,
        // 2.5 s) really plays. Measured 2026-11-05: without this the flipbook ran 6.6 s, not 8.8 s.
        if let last = box.frames.last {
            try await append(last, at: t - CMTime(value: 1, timescale: 30))
        }
        receiver.finish()
        writer.endSession(atSourceTime: t)
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        return url
    }
}

// ==== LEGO END: 37 The Developer Tray (Trace, Contact Sheet, Flipbook) ====
