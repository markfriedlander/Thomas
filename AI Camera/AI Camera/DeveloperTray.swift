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
import SwiftUI
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

/// The development of the most recent shot, as it happens: which shot, its photograph, what the eye
/// said, the drawing engine's real latent at every step, and the finished drawing. The tray watches this
/// live (polling `version`); the keepsakes read it when the shot is done. Small on purpose: a 20-step
/// Core ML shot is 21 x 16,384 floats (~1.3 MB), and everything is replaced when the next shot starts.
/// A lock, not an actor, because both engines report steps synchronously.
nonisolated final class DevelopTrace: @unchecked Sendable {
    static let shared = DevelopTrace()
    private let lock = NSLock()

    /// `@unchecked Sendable`: it carries immutable CGImages across to the tray.
    struct Snapshot: @unchecked Sendable {
        let version: Int
        let shotID: UUID?
        let photo: CGImage?
        let eyeWords: String?      // what the eye said (frame 2), once it has spoken
        let wordsFromEye: Bool     // false in the silent loop, where the words are the user's instruction
        let prompt: String         // what the hand received (may be the eye's words condensed)
        let steps: Int             // steps planned for the drawing (0 until it starts)
        let isGuess: Bool          // what was actually captured, not what was asked for
        let channelsLast: Bool     // MLX hand: [1, H, W, 4]; Core ML hand: [1, 4, H, W]
        let hand: String           // display name of the drawing model
        let shape: [Int]
        let latents: [[Float]]     // one per completed step, in order
        let final: CGImage?        // the finished drawing at the model's own size, once drawn
        let eye: EyeWorkings?      // the eye's numbers and gaze, when the eye can show them (EyeWorkings.swift)
        let eyeName: String?       // which eye looked, so the tray can say why there are no workings
    }

    private var version = 0
    private var shotID: UUID?
    private var photo: CGImage?
    private var eyeWords: String?
    private var wordsFromEye = true
    private var prompt = ""
    private var steps = 0
    private var isGuess = false
    private var channelsLast = false
    private var hand = ""
    private var shape: [Int] = []
    private var latents: [[Float]] = []
    private var final: CGImage?
    private var eye: EyeWorkings?
    private var eyeName: String?
    private var eyeOpen = false

    /// A new shot begins developing: forget everything from the last one, so a shot that draws
    /// nothing can never inherit another shot's steps.
    func startShot(id: UUID?, photo: CGImage?) {
        lock.withLock {
            shotID = id; self.photo = photo; eyeWords = nil; wordsFromEye = true; prompt = ""; steps = 0
            isGuess = false; channelsLast = false; hand = ""; shape = []; latents = []; final = nil
            eye = nil; eyeName = nil; eyeOpen = id != nil
            version += 1
        }
    }

    func noteEyeWords(_ words: String, fromEye: Bool = true) {
        lock.withLock { eyeWords = words; wordsFromEye = fromEye; eyeOpen = false; version += 1 }
    }

    /// Which eye is about to look at this shot (any eye, including Apple's, which shows no workings).
    func noteEyeName(_ name: String) {
        lock.withLock { if eyeOpen { eyeName = name; version += 1 } }
    }

    // The eye's workings (EyeRecorder). Recording is allowed exactly once per shot, for the look
    // that comes between `startShot` and the shot's words, so no other use of the eye (the condense
    // call, an antenna /look) can ever write into a shot's trace.
    func openEyeRecording(model: String) -> Bool {
        lock.withLock {
            guard eyeOpen, eye == nil else { return false }
            eye = EyeWorkings(model: model); eyeName = model; version += 1
            return true
        }
    }

    func noteEyeNumbers(_ features: [Float], width: Int, rows: Int, cols: Int) {
        lock.withLock {
            eye?.features = features; eye?.width = width; eye?.rows = rows; eye?.cols = cols; version += 1
        }
    }

    func appendEyePiece(_ piece: EyeWorkings.Piece) {
        lock.withLock { eye?.pieces.append(piece); version += 1 }
    }

    func finishEyeRecording(recorderMS: Double, layers: Int, heads: Int) {
        lock.withLock {
            eye?.done = true; eye?.recorderMS = recorderMS; eye?.layers = layers; eye?.heads = heads
            version += 1
        }
    }

    /// The drawing starts (called by the engine once it is loaded).
    func begin(prompt: String, steps: Int, isGuess: Bool, channelsLast: Bool, hand: String) {
        lock.withLock {
            self.prompt = prompt; self.steps = steps; self.isGuess = isGuess
            self.channelsLast = channelsLast; self.hand = hand; shape = []; latents = []; final = nil
            version += 1
        }
    }

    func record(_ values: [Float], shape: [Int]) {
        lock.withLock { self.shape = shape; latents.append(values); version += 1 }
    }

    func finish(drawing: CGImage) {
        lock.withLock { final = drawing; version += 1 }
    }

    /// Cheap check for "anything new?" without copying the latents.
    func currentVersion() -> Int { lock.withLock { version } }

    func snapshot() -> Snapshot? {
        lock.withLock {
            guard shotID != nil || !latents.isEmpty else { return nil }
            return Snapshot(version: version, shotID: shotID, photo: photo, eyeWords: eyeWords,
                            wordsFromEye: wordsFromEye, prompt: prompt, steps: steps, isGuess: isGuess, channelsLast: channelsLast,
                            hand: hand, shape: shape, latents: latents, final: final,
                            eye: eye, eyeName: eyeName)
        }
    }
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

// ==== LEGO START: 38 The Developer Tray Screen (Watch It Develop) ====

/// One moment on the tray's timeline, in true order. Only moments that really happened appear:
/// no eye stage when the eye was off, no drawing stages when the hand did not draw, and no numbers
/// or gaze unless the eye could show them (Qwen 3.5, through `EyeRecorder`).
nonisolated enum TrayFrame: Hashable, Sendable {
    case reality, numbers, gaze(Int), words, mixing, step(Int), finished
}

/// One word as the tray shows it, built from the eye's word pieces ("bl" + "inding" + "ly"). Its
/// gaze is the average of its letter pieces' gaze; punctuation rides along in the text but adds
/// nothing to where the word looked.
nonisolated struct TrayWord: Identifiable, Sendable {
    let id: Int
    let text: String
    let gaze: [Float]
    let imageShare: Float

    static func words(from pieces: [EyeWorkings.Piece]) -> [TrayWord] {
        var texts: [String] = []
        var gazes: [[[Float]]] = []
        var shares: [[Float]] = []
        for p in pieces {
            let trimmed = p.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let hasLetters = trimmed.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
            let startsWord = p.text.first?.isWhitespace ?? false
            if texts.isEmpty || (startsWord && hasLetters) {
                texts.append(trimmed); gazes.append([]); shares.append([])
            } else {
                texts[texts.count - 1] += trimmed
            }
            if hasLetters { gazes[gazes.count - 1].append(p.gaze); shares[shares.count - 1].append(p.imageShare) }
        }
        return texts.indices.compactMap { (i: Int) -> TrayWord? in
            guard let first = gazes[i].first else { return nil }   // punctuation alone is not a word
            var sum = [Float](repeating: 0, count: first.count)
            for g in gazes[i] where g.count == sum.count { for j in sum.indices { sum[j] += g[j] } }
            let n = Float(gazes[i].count)
            return TrayWord(id: i, text: texts[i], gaze: sum.map { $0 / n },
                            imageShare: shares[i].reduce(0, +) / Float(shares[i].count))
        }
        .enumerated().map { TrayWord(id: $0.offset, text: $0.element.text, gaze: $0.element.gaze, imageShare: $0.element.imageShare) }
    }
}

/// How the numbers frame shows the photograph: the colours over it, the colours alone, or the
/// photograph alone (tap the stage's toggle to cycle).
nonisolated enum NumbersLook: String, CaseIterable, Sendable {
    case blend, colours, photo
    var next: NumbersLook { self == .blend ? .colours : self == .colours ? .photo : .blend }
    var label: String { self == .blend ? "Both" : self == .colours ? "Colours" : "Photo" }
}

/// Turns recorded steps into pictures for the screen, one at a time, only while the tray is open.
/// An actor so its TAESD model is touched by one thread. While the Core ML hand is drawing (on the
/// Neural Engine) the GPU is otherwise idle, so it decodes directly; at every other time it waits its
/// turn in `ModelLane` like any other model work (the one-at-a-time rule).
actor TrayPreviewDecoder {
    private var taesd: TAESDDecoder?

    struct Picture: @unchecked Sendable { let image: CGImage }

    func decode(_ values: [Float], shape: [Int], channelsLast: Bool) -> Picture? {
        if taesd == nil { taesd = try? TAESDDecoder.bundled() }
        guard let taesd, shape.count == 4 else { return nil }
        var z = MLXArray(values, shape)
        if !channelsLast { z = z.transposed(0, 2, 3, 1) }
        let raster = (taesd.decodePixels(z) * 255).asType(.uint8).squeezed()
        eval(raster)
        return Picture(image: SDImage(raster).asCGImage())
    }

    func release() {
        taesd = nil
        MLX.Memory.clearCache()
    }
}

/// The tray's state for one shot: what has happened so far (from `DevelopTrace`), which moment is
/// on screen, and whether it follows the development live.
@MainActor @Observable
final class TrayModel {
    let shotID: UUID
    private(set) var trace: DevelopTrace.Snapshot?
    private(set) var frames: [TrayFrame] = [.reality]
    var index = 0
    /// True: the screen jumps to each new moment as it happens. Scrubbing turns it off; Live turns
    /// it back on.
    var following = true
    private(set) var playing = false
    private(set) var previews: [Int: UIImage] = [:]   // step (1-based) -> quick preview
    private var requested: Set<Int> = []
    /// Live mode keeps at most one preview decoding at a time. A preview takes about as long as the
    /// engine takes per step (~0.65 s measured 2026-11-05), so queueing every step made the screen trail
    /// by 2-3 steps; with one in flight it grabs the newest step each time and trails by about one.
    private var liveInFlight = false
    private var lastVersion = -1
    private var pollTask: Task<Void, Never>?
    private var playTask: Task<Void, Never>?
    /// Set once the tray has looked for this shot's kept negative (a shot that is no longer the one
    /// developing live is opened from the Dark Room's negatives).
    private var negativeRequested = false
    private let decoder = TrayPreviewDecoder()

    // The eye's workings (EyeWorkings.swift), when this shot's eye could show them.
    private(set) var eyeWords: [TrayWord] = []
    private var piecesSeen = -1
    private(set) var summary: EyeNumbersSummary?
    private var summaryRequested = false
    var numbersLook: NumbersLook = .blend
    /// The square whose raw numbers are open in a sheet.
    var openSquare: Int?

    #if DEBUG
    /// The open tray, so the antenna can read and scrub it (human parity).
    static weak var current: TrayModel?
    #endif

    init(shotID: UUID) { self.shotID = shotID }

    var current: TrayFrame { frames[min(max(index, 0), frames.count - 1)] }
    var isMine: Bool { trace?.shotID == shotID }
    var drawingDone: Bool { trace?.final != nil }

    func start() {
        #if DEBUG
        TrayModel.current = self
        #endif
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel(); playTask?.cancel()
        Task { await decoder.release() }
    }

    /// Pull anything new from the trace (cheap version check first) and rebuild the timeline.
    private func refresh() {
        let v = DevelopTrace.shared.currentVersion()
        let developing = DarkRoomWorker.shared.currentShotID == shotID
        let mixingNow = developing && DarkRoomWorker.shared.currentStage == .mixing
        if v != lastVersion, let snap = DevelopTrace.shared.snapshot(), snap.shotID == shotID {
            lastVersion = v
            trace = snap
        }
        // Not the shot in the live trace: open its negative instead (NegativeStore), once.
        if trace == nil, !developing, !negativeRequested {
            negativeRequested = true
            let id = shotID
            Task {
                if let kept = await NegativeStore.shared.load(id) { self.trace = kept }
                cameraLog("TRAY: opened \(id.uuidString.prefix(8)) from its negative: \(self.trace == nil ? "none kept" : "ok")")
            }
        }
        guard let t = trace, isMine else { rebuild(nil, mixingNow: mixingNow); return }
        if let e = t.eye {
            if e.pieces.count != piecesSeen {
                piecesSeen = e.pieces.count
                eyeWords = TrayWord.words(from: e.pieces)
            }
            // The colour summary needs only the numbers, which exist before the first word.
            if summary == nil, !summaryRequested, e.squares > 0, e.features.count == e.squares * e.width {
                summaryRequested = true
                Task {
                    let started = Date()
                    let made = await Task.detached(priority: .userInitiated) { EyeNumbersSummary(e) }.value
                    self.summary = made
                    cameraLog("TRAY: numbers summary in \(Int(Date().timeIntervalSince(started) * 1000)) ms, explains \(Int((made?.explained ?? 0) * 100))%")
                }
            }
        }
        rebuild(t, mixingNow: mixingNow)
        if following && !playing { index = frames.count - 1 }
        requestPreview(for: current)
        if t.final != nil { prefetchAll() }   // done: decode the rest so play and scrub are smooth
    }

    private func rebuild(_ t: DevelopTrace.Snapshot?, mixingNow: Bool) {
        var f: [TrayFrame] = [.reality]
        if let e = t?.eye, e.squares > 0 {
            f.append(.numbers)
            for i in eyeWords.indices { f.append(.gaze(i)) }
        }
        if let w = t?.eyeWords, !w.isEmpty { f.append(.words) }
        if mixingNow || (t?.steps ?? 0) > 0 { f.append(.mixing) }
        for k in 0..<(t?.latents.count ?? 0) { f.append(.step(k + 1)) }
        if t?.final != nil { f.append(.finished) }
        if f != frames { frames = f }
        if index >= frames.count { index = frames.count - 1 }
    }

    /// Decode a step for the screen if it is not already. The MLX hand shares the GPU with the
    /// preview decoder, so its steps wait until its drawing is done.
    func requestPreview(for frame: TrayFrame) {
        guard case .step(let k) = frame, previews[k] == nil, !requested.contains(k),
              let t = trace, k <= t.latents.count else { return }
        if t.channelsLast && t.final == nil { return }
        // Live: only the newest step is worth decoding; older ones would arrive already stale. The
        // gaps are filled once the drawing is done (`prefetchAll`), for scrubbing and replay.
        let live = following && t.final == nil
        if live && (k < t.latents.count || liveInFlight) { return }
        if live { liveInFlight = true }
        requested.insert(k)
        let values = t.latents[k - 1], shape = t.shape, channelsLast = t.channelsLast
        let direct = !t.channelsLast && t.final == nil   // Core ML hand mid-draw: the GPU is idle
        let decoder = self.decoder
        Task {
            let started = Date()
            let pic: TrayPreviewDecoder.Picture?
            if direct {
                pic = await decoder.decode(values, shape: shape, channelsLast: channelsLast)
            } else {
                pic = await ModelLane.shared.run("tray") {
                    await decoder.decode(values, shape: shape, channelsLast: channelsLast)
                }
            }
            if let pic { self.previews[k] = UIImage(cgImage: pic.image) }
            self.requested.remove(k)
            if live { self.liveInFlight = false; self.requestPreview(for: self.current) }
            cameraLog("TRAY: step \(k) preview in \(Int(Date().timeIntervalSince(started) * 1000)) ms (\(direct ? "direct" : "lane"))")
        }
    }

    private func prefetchAll() {
        guard let t = trace else { return }
        for k in 1...max(1, t.latents.count) where previews[k] == nil { requestPreview(for: .step(k)) }
    }

    func scrub(to i: Int) {
        playTask?.cancel(); playing = false
        following = false
        index = min(max(i, 0), frames.count - 1)
        requestPreview(for: current)
    }

    func goLive() {
        playTask?.cancel(); playing = false
        following = true
        index = frames.count - 1
    }

    /// Replay the development from the photograph to the newest moment.
    func play() {
        playTask?.cancel()
        following = false
        playing = true
        index = 0
        playTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.index < self.frames.count - 1 {
                let hold: UInt64 = {
                    switch self.current {
                    case .step: return 300_000_000
                    case .gaze: return 330_000_000
                    case .numbers: return 2_500_000_000
                    default: return 1_200_000_000
                    }
                }()
                try? await Task.sleep(nanoseconds: hold)
                if Task.isCancelled { break }
                self.index += 1
                self.requestPreview(for: self.current)
            }
            self?.playing = false
        }
    }

    func pause() { playTask?.cancel(); playing = false }

    /// Tap a word: jump to the moment the eye chose it.
    func jump(toWord i: Int) {
        if let at = frames.firstIndex(of: .gaze(i)) { scrub(to: at) }
    }

    /// The word on screen, on a gaze frame.
    var currentWord: TrayWord? {
        if case .gaze(let i) = current, eyeWords.indices.contains(i) { return eyeWords[i] }
        return nil
    }

    /// The step actually on screen for step `k`: itself if decoded, else the newest decoded step
    /// before it (so the screen never sits on a spinner while a preview is on its way).
    func shownStep(for k: Int) -> Int? {
        if previews[k] != nil { return k }
        return previews.keys.filter { $0 < k }.max()
    }

    /// What the frame on screen is, in words. Every frame says what it is (Principle 2, and the tray's
    /// own honesty rule: the in-between pictures are quick previews, not the drawing).
    var caption: String {
        let total = trace?.latents.count ?? 0
        switch current {
        case .reality: return "Reality: your photograph"
        case .numbers:
            guard let e = trace?.eye else { return "The numbers" }
            return "The numbers: \(e.squares) squares, \(e.width.formatted()) numbers each, made before any word"
        case .gaze(let i):
            guard eyeWords.indices.contains(i) else { return "Where it looked" }
            return "\u{201C}\(eyeWords[i].text)\u{201D}: where it looked as it chose this word"
        case .words:   return (trace?.wordsFromEye ?? true) ? "What the eye said" : "Your instruction to the hand"
        case .mixing:  return "Mixing the developer"
        case .step(let k):
            let view = (trace?.isGuess ?? false) ? DevelopView.guess.name : DevelopView.working.name
            let of = max(total, trace?.steps ?? 0)
            guard let shown = shownStep(for: k) else { return "Step \(k) of \(of) · preview on its way" }
            // After the drawing, missing previews go through the model lane, which holds work while the
            // phone is hot (ThermalGovernor). Say that, rather than implying it is merely slow.
            let hot = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
            let waiting = (drawingDone && hot) ? "waits for the phone to cool" : "is on its way"
            let lag = shown == k ? "" : " (step \(k) \(waiting))"
            return "Step \(shown) of \(of) · \(view.lowercased()) (quick preview)\(lag)"
        case .finished: return "The finished drawing"
        }
    }

    /// The second line under the caption: how to read the frame, and what it is a summary of.
    var detail: String? {
        switch current {
        case .numbers:
            guard let s = summary else { return "Summarizing them as colours…" }
            return "Colours summarize the numbers: squares the eye thinks alike come out alike (3 colours carry \(Int((s.explained * 100).rounded()))% of the variation). Tap a square to see its real numbers."
        case .gaze(let i):
            guard eyeWords.indices.contains(i), let e = trace?.eye else { return nil }
            let share = Int((eyeWords[i].imageShare * 100).rounded())
            let how = e.layers > 0 && e.heads > 0
                ? "measured in \(e.layers) attention layers, averaged over \(e.heads) heads"
                : "measured in its attention layers"
            return "Brightest squares got the most attention; \(share)% of its attention was on the picture, the rest on words (\(how)). Tap a word to jump to it."
        case .words:
            guard trace?.eye == nil, let name = trace?.eyeName, trace?.wordsFromEye ?? true else { return nil }
            if name == Seer.apple.name { return "Apple's eye doesn't show its workings; choose Qwen as the eye to see them." }
            return "\(name) doesn't show its workings here yet."
        default:
            return nil
        }
    }
}

/// The Developer Tray: watch one shot develop, live, and scrub back through every real moment.
struct DeveloperTrayView: View {
    @State private var model: TrayModel
    @State private var worker = DarkRoomWorker.shared

    init(shotID: UUID) { _model = State(initialValue: TrayModel(shotID: shotID)) }

    var body: some View {
        // Scrolls, so the stage always gets the full width: the eye stages add a caption line and the
        // sentence, and in a fixed column they squeezed the picture to a thumbnail (device, 2026-11-05).
        ScrollView {
        VStack(spacing: 14) {
            Text(stageLine)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            // A square stage. The black square sets the size; the frame sits on it. (Sizing the content
            // itself collapsed to the height of a spinner on the first device test, 2026-11-05.)
            Color.black
                .aspectRatio(1, contentMode: .fit)
                .overlay { frameView }
                .clipShape(RoundedRectangle(cornerRadius: 10))

            Text(model.caption)
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
            if let detail = model.detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if showsWordStrip { wordStrip }

            scrubber

            HStack {
                Button { model.playing ? model.pause() : model.play() } label: {
                    Label(model.playing ? "Pause" : "Play", systemImage: model.playing ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.bordered)
                .disabled(model.frames.count < 2)
                Spacer()
                if isDeveloping {
                    Button { model.goLive() } label: {
                        Label("Live", systemImage: "dot.radiowaves.left.and.right")
                    }
                    .buttonStyle(.bordered)
                    .tint(model.following ? .red : .accentColor)
                }
            }

            Text("Everything here is real: your photograph, the numbers the eye made of it, where it looked as it chose each word, its own words, and the drawing engine's actual state at each step. The colours and the step pictures are summaries and quick previews, and say so; the finished drawing is the real one.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        }
        .navigationTitle("The Developer Tray")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .sheet(item: Binding(get: { model.openSquare.map(SquareRef.init) },
                             set: { model.openSquare = $0?.id })) { ref in
            if let e = model.trace?.eye {
                SquareNumbersSheet(eye: e, square: ref.id, photo: model.trace?.photo)
            }
        }
        #if DEBUG
        .onChange(of: AntennaUIBridge.shared.trayScrubTo) { _, v in
            guard let v else { return }
            if v == -2 { model.play() } else if v < 0 { model.goLive() } else { model.scrub(to: v) }
            AntennaUIBridge.shared.trayScrubTo = nil
        }
        .onChange(of: AntennaUIBridge.shared.trayTap) { _, tap in
            guard let tap else { return }
            let parts = tap.split(separator: ":")
            switch (parts.first, parts.count > 1 ? Int(parts[1]) : nil) {
            case ("word"?, let i?): model.jump(toWord: i)
            case ("square"?, let n?): model.openSquare = n
            case ("close"?, _): model.openSquare = nil
            case ("look"?, _): model.numbersLook = model.numbersLook.next
            default: break
            }
            AntennaUIBridge.shared.trayTap = nil
        }
        #endif
    }

    private var isDeveloping: Bool { worker.currentShotID == model.shotID }

    private var stageLine: String {
        guard isDeveloping else { return model.drawingDone ? "Developed" : "Finished" }
        switch worker.currentStage {
        case .seeing?: return "Seeing…"
        case .mixing?: return "Mixing the developer…"
        case .drawing?:
            let n = model.trace?.latents.count ?? 0
            let total = model.trace?.steps ?? 0
            return n == 0 ? "Developing…" : "Developing · step \(n) of \(max(n, total))"
        case .saving?: return "Saving to Photos…"
        case .none: return "Developing…"
        }
    }

    private var showsWordStrip: Bool {
        guard !model.eyeWords.isEmpty else { return false }
        switch model.current {
        case .numbers, .gaze: return true
        default: return false
        }
    }

    /// The eye's sentence, word by word; the word on screen is lit, and every word is a button.
    private var wordStrip: some View {
        ScrollViewReader { proxy in
            ScrollView {
                WordFlow(spacing: 4) {
                    ForEach(model.eyeWords) { w in
                        let lit = model.currentWord?.id == w.id
                        Button { model.jump(toWord: w.id) } label: {
                            Text(w.text)
                                .font(.callout.weight(lit ? .bold : .regular))
                                .padding(.horizontal, 3)
                                .background(lit ? Color.yellow.opacity(0.35) : .clear, in: RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                        .id(w.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 96)
            .onChange(of: model.currentWord?.id) { _, id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }

    @ViewBuilder
    private var frameView: some View {
        switch model.current {
        case .reality:
            if let photo = model.trace?.photo {
                Image(uiImage: UIImage(cgImage: photo)).resizable().scaledToFit()
            } else {
                card("Waiting for the photograph…")
            }
        case .numbers:
            if let photo = model.trace?.photo, let e = model.trace?.eye {
                let s = model.summary
                let opacity: Double = model.numbersLook == .blend ? 0.72 : model.numbersLook == .colours ? 1 : 0
                EyeGridPhoto(photo: photo, rows: e.rows, cols: e.cols, tint: { i in
                    guard let s, i < s.colors.count, opacity > 0 else { return .clear }
                    let c = s.colors[i]
                    return Color(red: Double(c.0), green: Double(c.1), blue: Double(c.2)).opacity(opacity)
                }, onTap: { model.openSquare = $0 })
                .overlay(alignment: .bottomTrailing) {
                    Button { model.numbersLook = model.numbersLook.next } label: {
                        Text(model.numbersLook.label).font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                }
            }
        case .gaze(let i):
            if let photo = model.trace?.photo, let e = model.trace?.eye, model.eyeWords.indices.contains(i) {
                let g = model.eyeWords[i].gaze
                let top = max(g.max() ?? 0, .leastNonzeroMagnitude)
                // Darken by how little attention each square got, scaled to this word's strongest.
                EyeGridPhoto(photo: photo, rows: e.rows, cols: e.cols, tint: { j in
                    guard j < g.count else { return .clear }
                    return Color.black.opacity(0.78 * Double(1 - g[j] / top))
                })
            }
        case .words:
            ScrollView {
                Text(model.trace?.eyeWords ?? "")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                if let t = model.trace, let w = t.eyeWords, !t.prompt.isEmpty, t.prompt != w {
                    Text("The hand received a shorter version: \"\(t.prompt)\"")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 20)
                }
            }
        case .mixing:
            VStack(spacing: 12) {
                if isDeveloping && worker.currentStage == .mixing { ProgressView().tint(.white) }
                Text("Loading the drawing model\((model.trace?.channelsLast ?? false) ? "" : " onto the Neural Engine"). The first time after installing or updating takes a couple of minutes; after that, a second or two.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(24)
            }
        case .step(let k):
            if let shown = model.shownStep(for: k), let img = model.previews[shown] {
                Image(uiImage: img).resizable().scaledToFit()
            } else if let t = model.trace, t.channelsLast, t.final == nil {
                card("\(t.hand) is using the graphics chip; its step previews appear when the drawing finishes.")
            } else {
                ProgressView().tint(.white)
            }
        case .finished:
            if let f = model.trace?.final {
                Image(uiImage: UIImage(cgImage: f)).resizable().scaledToFit()
            }
        }
    }

    private struct SquareRef: Identifiable { let id: Int }

    private func card(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.white.opacity(0.8))
            .multilineTextAlignment(.center)
            .padding(24)
    }

    private var scrubber: some View {
        VStack(spacing: 4) {
            Slider(value: Binding(
                get: { Double(model.index) },
                set: { model.scrub(to: Int($0.rounded())) }
            ), in: 0...Double(max(1, model.frames.count - 1)), step: 1)
            .disabled(model.frames.count < 2)
            HStack {
                Text("Photo").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(model.drawingDone ? "Finished" : "Now").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// The photograph with one colour laid over each of the eye's squares (rows x cols, the grid the
/// vision encoder made). Optional tap: which square was touched.
struct EyeGridPhoto: View {
    let photo: CGImage
    let rows: Int
    let cols: Int
    let tint: (Int) -> Color
    var onTap: ((Int) -> Void)? = nil

    var body: some View {
        Image(uiImage: UIImage(cgImage: photo)).resizable().scaledToFit()
            .overlay {
                GeometryReader { geo in
                    Canvas { ctx, size in
                        guard rows > 0, cols > 0 else { return }
                        let w = size.width / CGFloat(cols), h = size.height / CGFloat(rows)
                        for r in 0..<rows {
                            for c in 0..<cols {
                                let rect = CGRect(x: CGFloat(c) * w, y: CGFloat(r) * h, width: w + 0.5, height: h + 0.5)
                                ctx.fill(Path(rect), with: .color(tint(r * cols + c)))
                            }
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { loc in
                        guard let onTap, rows > 0, cols > 0, geo.size.width > 0, geo.size.height > 0 else { return }
                        let c = min(cols - 1, max(0, Int(loc.x / geo.size.width * CGFloat(cols))))
                        let r = min(rows - 1, max(0, Int(loc.y / geo.size.height * CGFloat(rows))))
                        onTap(r * cols + c)
                    }
                }
            }
    }
}

/// One square's real numbers: all of them (2,048 for Qwen3.5-2B), exactly as the vision encoder made
/// them, beside the patch of photograph they describe.
struct SquareNumbersSheet: View {
    let eye: EyeWorkings
    let square: Int
    let photo: CGImage?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let numbers = Array(eye.numbers(ofSquare: square))
        let row = eye.cols > 0 ? square / eye.cols : 0, col = eye.cols > 0 ? square % eye.cols : 0
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 14) {
                        if let crop = patch(row: row, col: col) {
                            Image(uiImage: UIImage(cgImage: crop)).resizable().interpolation(.none)
                                .scaledToFit().frame(width: 96, height: 96)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Row \(row + 1), column \(col + 1) of \(eye.rows) x \(eye.cols)").font(.headline)
                            if let lo = numbers.min(), let hi = numbers.max() {
                                Text("\(numbers.count.formatted()) numbers, from \(fmt(lo)) to \(fmt(hi))")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("This is how \(eye.model)'s eye holds this part of the photograph, before it has a single word for it: a list of numbers, straight out of its vision encoder. They are shown to 3 decimal places; nothing else is changed.")
                        .font(.footnote).foregroundStyle(.secondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), alignment: .trailing, spacing: 4) {
                        ForEach(numbers.indices, id: \.self) { j in
                            Text(fmt(numbers[j])).font(.caption.monospacedDigit())
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("One square's numbers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func fmt(_ v: Float) -> String { String(format: "%.3f", v) }

    private func patch(row: Int, col: Int) -> CGImage? {
        guard let photo, eye.rows > 0, eye.cols > 0 else { return nil }
        let w = CGFloat(photo.width) / CGFloat(eye.cols), h = CGFloat(photo.height) / CGFloat(eye.rows)
        return photo.cropping(to: CGRect(x: CGFloat(col) * w, y: CGFloat(row) * h, width: w, height: h).integral)
    }
}

/// Lays words out like a paragraph: left to right, wrapping to the next line.
struct WordFlow: SwiftUI.Layout {   // qualified: the app has its own `Layout` (Developing.swift)
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

// ==== LEGO END: 38 The Developer Tray Screen (Watch It Develop) ====
