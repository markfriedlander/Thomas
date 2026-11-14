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

    func noteEyePrompt(_ pieces: [String], imagePositions: [Int]) {
        lock.withLock { eye?.promptPieces = pieces; eye?.promptImagePositions = imagePositions; version += 1 }
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

    /// The words the hand will receive, as soon as they are decided (before the hand loads, so the tray's
    /// "Mixing the developer" moment can show them).
    func noteHandWords(_ words: String) {
        lock.withLock { prompt = words; version += 1 }
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

    /// What fills the canvas: the photograph (lens and eye), the words (the eye's words, then the words
    /// handed to the hand), or the drawing. The flow photograph -> words -> drawing is Mark's
    /// (2026-11-13): the words replace the picture, then dissolve into the hand's first noise.
    var phase: TrayPhase {
        switch self {
        case .reality, .numbers, .gaze: return .picture
        case .words, .mixing: return .words
        case .step, .finished: return .drawing
        }
    }

    /// Which of the shot's three chapters this moment belongs to.
    var chapter: TrayChapter {
        switch self {
        case .reality: return .lens
        case .numbers, .gaze, .words: return .eye
        case .mixing, .step, .finished: return .hand
        }
    }
}

nonisolated enum TrayPhase: Sendable { case picture, words, drawing }

/// Every shot's three chapters, the tray's top pill (Mark, 2026-11-12 design pass): what the lens saw,
/// what the eye made of it, what the hand drew from the eye's words.
nonisolated enum TrayChapter: String, CaseIterable, Sendable {
    case lens, eye, hand
    var label: String { rawValue.uppercased() }
}

/// Where a chapter sits on the timeline, for the scrubber's marks.
nonisolated struct TrayChapterSpan: Identifiable, Sendable {
    let chapter: TrayChapter
    let first: Int
    let last: Int
    var id: TrayChapter { chapter }
}

/// One word as the tray shows it, built from the eye's word pieces ("bl" + "inding" + "ly"). Its
/// gaze is the average of its letter pieces' gaze; punctuation rides along in the text but adds
/// nothing to where the word looked. A dash between words ("object\u{2014}the sun\u{2014}is") ends a
/// word even without a space.
nonisolated struct TrayWord: Identifiable, Sendable {
    let id: Int
    let text: String
    let gaze: [Float]
    let imageShare: Float
    /// Every word piece in this word (punctuation included), and the ones whose looks make it up.
    let pieces: [Int]
    let letterPieces: [Int]

    /// The word without its punctuation, for the moment pill.
    var bare: String {
        let t = text.trimmingCharacters(in: .punctuationCharacters)
        return t.isEmpty ? text : t
    }

    static func words(from pieces: [EyeWorkings.Piece]) -> [TrayWord] {
        var texts: [String] = []
        var all: [[Int]] = []
        var letters: [[Int]] = []
        for (i, p) in pieces.enumerated() {
            let trimmed = p.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let hasLetters = trimmed.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
            let startsWord = p.text.first?.isWhitespace ?? false
            let afterDash = texts.last?.hasSuffix("\u{2014}") ?? false
            if texts.isEmpty || (hasLetters && (startsWord || afterDash || trimmed.hasPrefix("\u{2014}"))) {
                texts.append(trimmed); all.append([]); letters.append([])
            } else {
                texts[texts.count - 1] += trimmed
            }
            all[all.count - 1].append(i)
            if hasLetters { letters[letters.count - 1].append(i) }
        }
        var out: [TrayWord] = []
        for k in texts.indices {
            guard let first = letters[k].first else { continue }   // punctuation alone is not a word
            let n = pieces[first].gaze.count
            var sum = [Float](repeating: 0, count: n)
            var share: Float = 0
            var counted: Float = 0
            for j in letters[k] where pieces[j].gaze.count == n {
                for s in 0..<n { sum[s] += pieces[j].gaze[s] }
                share += pieces[j].imageShare
                counted += 1
            }
            guard counted > 0 else { continue }
            out.append(TrayWord(id: out.count, text: texts[k], gaze: sum.map { $0 / counted },
                                imageShare: share / counted, pieces: all[k], letterPieces: letters[k]))
        }
        return out
    }
}

/// Where ALL of one word's attention went (Mark, 2026-11-12: "We need to think about a way to show
/// the other 68%"): to the picture, to its instructions, and to what it had already said, plus how
/// much landed on each earlier word. Read from the word's whole attention rows
/// (`EyeWorkings.Piece.context`), averaged over its letter pieces exactly as its gaze is. Nil when the
/// shot recorded only the picture's part (shots kept before 2026-11-12).
nonisolated struct TrayLook: Sendable {
    let picture: Float
    let instructions: Float
    let said: Float
    /// Of the instructions' share, the part that landed on the invisible markers between their parts
    /// (role markers such as <|im_start|>, and line breaks) rather than on their words.
    let markers: Float
    /// Attention on each earlier word, by word index.
    let onWords: [Float]

    init?(word: TrayWord, words: [TrayWord], eye: EyeWorkings) {
        let p = eye.promptPieces.count
        guard p > 0, !word.letterPieces.isEmpty,
              word.letterPieces.allSatisfy({ $0 < eye.pieces.count && eye.pieces[$0].context.count == p + $0 })
        else { return nil }
        let image = eye.promptImagePositions.filter { $0 < p }
        let imageSet = Set(image)
        let markerPositions = (0..<p).filter { i in
            guard !imageSet.contains(i) else { return false }
            let t = eye.promptPieces[i]
            return (t.hasPrefix("<") && t.hasSuffix(">")) || t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        var pic: Float = 0, ins: Float = 0, said: Float = 0, mk: Float = 0
        var on = [Float](repeating: 0, count: word.id)
        for j in word.letterPieces {
            let row = eye.pieces[j].context
            let img = image.reduce(Float(0)) { $0 + row[$1] }
            let prompt = row[0..<p].reduce(Float(0), +)
            pic += img
            ins += prompt - img
            said += row[p...].reduce(Float(0), +)
            mk += markerPositions.reduce(Float(0)) { $0 + row[$1] }
            for v in 0..<word.id {
                for q in words[v].pieces where p + q < row.count { on[v] += row[p + q] }
            }
        }
        let n = Float(word.letterPieces.count)
        picture = pic / n
        instructions = ins / n
        self.said = said / n
        markers = ins > 0 ? mk / ins : 0
        onWords = on.map { $0 / n }
    }
}

/// How a word in the sentence is lit.
nonisolated enum TrayWordState: Equatable, Sendable {
    case current            // the word being chosen
    case lit(Float)         // 0...1 on the shot's one scale of light
    case future             // not said yet at this moment
}

/// Turns recorded steps into pictures for the screen, one at a time, only while the tray is open.
/// An actor so its TAESD model is touched by one thread. While the Core ML hand is drawing (on the
/// Neural Engine) the GPU is otherwise idle, so it decodes directly; at every other time it waits its
/// turn in `ModelLane` like any other model work (the one-at-a-time rule).
actor TrayPreviewDecoder {
    private var taesd: TAESDDecoder?

    struct Picture: @unchecked Sendable { let image: CGImage }

    func decode(_ values: [Float], shape: [Int], channelsLast: Bool) -> Picture? {
        // MLX cannot create its GPU device in the Simulator and aborts the app (found 2026-11-13 testing
        // the tray's iPad layout there). The Simulator only checks layouts, so it shows no previews.
        #if targetEnvironment(simulator)
        return nil
        #endif
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
        #if !targetEnvironment(simulator)
        MLX.Memory.clearCache()
        #endif
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
    /// True: the screen jumps to each new moment as it happens. Stepping, scrubbing or tapping a
    /// square turns it off; Live turns it back on.
    var following = true
    private(set) var previews: [Int: UIImage] = [:]   // step (1-based) -> quick preview
    private var requested: Set<Int> = []
    /// Live mode keeps at most one preview decoding at a time. A preview takes about as long as the
    /// engine takes per step (~0.65 s measured 2026-11-05), so queueing every step made the screen trail
    /// by 2-3 steps; with one in flight it grabs the newest step each time and trails by about one.
    private var liveInFlight = false
    private var lastVersion = -1
    private var pollTask: Task<Void, Never>?
    /// Set once the tray has looked for this shot's kept negative (a shot that is no longer the one
    /// developing live is opened from the Dark Room's negatives).
    private var negativeRequested = false
    private let decoder = TrayPreviewDecoder()

    // The eye's workings (EyeWorkings.swift), when this shot's eye could show them.
    private(set) var eyeWords: [TrayWord] = []
    private var piecesSeen = -1
    private(set) var likeness: EyeLikeness?
    private var likenessRequested = false
    /// One unit of light for the whole shot: the strongest attention any word piece paid to any single
    /// square or earlier word piece. Picture and words are lit on this same scale, so a word that barely
    /// looked at the picture leaves it dim (design pass 2026-11-12; before, each word was scaled to its
    /// own brightest square, which made a 32% look as bright as a 60% one).
    private(set) var lightScale: Float = 0
    /// While the shot is still developing: whether it is, and roughly how many moments are still to
    /// come, for the slider's faint track (Mark, 2026-11-13: mid-development the slider looked finished).
    private(set) var developing = false
    private(set) var upcoming = 0
    /// Where the hand will begin on that faint track, before it has begun.
    private(set) var upcomingHandStart: Int?

    /// The square the eye looked at most over the whole description: where the numbers moment opens.
    private(set) var mostLookedSquare: Int?
    @ObservationIgnored private var lookCache: [Int: TrayLook?] = [:]
    @ObservationIgnored private var alikeCache: (square: Int, values: [Float])?

    /// The square the person tapped: every square then lights by how alike its numbers are, and the
    /// words by how much they looked there. Cleared when the moment changes.
    var selectedSquare: Int?
    /// The square whose raw numbers are open in a sheet.
    var openSquare: Int?
    /// Whether the pills are showing (tap the backdrop to toggle), and whether "?" is open.
    var chromeVisible = true
    var helpOpen = false

    #if DEBUG
    /// The open tray, so the antenna can read and drive it (human parity).
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
        pollTask?.cancel()
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
                lookCache = [:]
                lightScale = Self.lightScale(e)
                mostLookedSquare = Self.mostLooked(eyeWords, squares: e.squares)
            }
            // The comparison needs only the numbers, which exist before the first word.
            if likeness == nil, !likenessRequested, e.squares > 0, e.features.count == e.squares * e.width {
                likenessRequested = true
                Task {
                    let started = Date()
                    let made = await Task.detached(priority: .userInitiated) { EyeLikeness(e) }.value
                    self.likeness = made
                    cameraLog("TRAY: likeness ready in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
                }
            }
        }
        rebuild(t, mixingNow: mixingNow)
        self.developing = developing
        updateUpcoming(t)
        if following { index = frames.count - 1 }
        requestPreview(for: current)
        if t.final != nil { prefetchAll() }   // done: decode the rest so stepping and scrubbing are smooth
    }

    /// Counts only what can be known: the words moment, the mixing, the hand's passes (set when the
    /// drawing starts; before that, the Core ML hand's usual 21) and the finished drawing. The eye's
    /// remaining words can't be known ahead, so they are not counted.
    private func updateUpcoming(_ t: DevelopTrace.Snapshot?) {
        guard developing else { upcoming = 0; upcomingHandStart = nil; return }
        var n = frames.contains(.words) ? 0 : 1
        var handStart: Int?
        if Settings.shared.drawsThirdFrame {
            if !has(.hand) { handStart = frames.count + n }
            if !frames.contains(.mixing) { n += 1 }
            let passes = (t?.steps ?? 0) > 0 ? (t?.steps ?? 0) : 21
            n += max(0, passes - (t?.latents.count ?? 0))
            if t?.final == nil { n += 1 }
        }
        if upcoming != n { upcoming = n }
        if upcomingHandStart != handStart { upcomingHandStart = handStart }
    }

    private static func lightScale(_ e: EyeWorkings) -> Float {
        let p = e.promptPieces.count
        var top: Float = 0
        for piece in e.pieces {
            top = max(top, piece.gaze.max() ?? 0)
            if p > 0, piece.context.count > p { top = max(top, piece.context[p...].max() ?? 0) }
        }
        return top
    }

    private static func mostLooked(_ words: [TrayWord], squares: Int) -> Int? {
        guard squares > 0, !words.isEmpty else { return nil }
        var sum = [Float](repeating: 0, count: squares)
        for w in words where w.gaze.count == squares { for s in 0..<squares { sum[s] += w.gaze[s] } }
        return sum.indices.max { sum[$0] < sum[$1] }
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
        // gaps are filled once the drawing is done (`prefetchAll`), for stepping and scrubbing.
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

    // MARK: Moving through the moments

    /// Go to moment `i` (the scrubber). A new moment starts fresh, with no square picked.
    func scrub(to i: Int) {
        following = false
        let n = min(max(i, 0), frames.count - 1)
        if n != index { selectedSquare = nil }
        index = n
        requestPreview(for: current)
    }

    /// The ‹ › buttons and a swipe on the picture: one moment back or forward.
    @discardableResult
    func step(_ delta: Int) -> Bool {
        let before = index
        scrub(to: index + delta)
        return index != before
    }

    func goLive() {
        following = true
        selectedSquare = nil
        index = frames.count - 1
    }

    /// Tap a chapter in the top pill: its first moment.
    func jump(to chapter: TrayChapter) {
        if let i = frames.firstIndex(where: { $0.chapter == chapter }) { scrub(to: i) }
    }

    /// Tap a word: jump to the moment the eye chose it.
    func jump(toWord i: Int) {
        if let at = frames.firstIndex(of: .gaze(i)) { scrub(to: at) }
    }

    /// Tap a square: compare from it. Tap the lit square itself to open its numbers (Mark, 2026-11-13:
    /// the square carries its number, and the numbers are found inside it, not behind a button).
    func tapSquare(_ s: Int) {
        following = false
        if s == comparedSquare { openSquare = s } else { selectedSquare = s }
    }

    func has(_ chapter: TrayChapter) -> Bool { frames.contains { $0.chapter == chapter } }

    var chapterSpans: [TrayChapterSpan] {
        TrayChapter.allCases.compactMap { c in
            guard let first = frames.firstIndex(where: { $0.chapter == c }),
                  let last = frames.lastIndex(where: { $0.chapter == c }) else { return nil }
            return TrayChapterSpan(chapter: c, first: first, last: last)
        }
    }

    // MARK: Reading the eye

    /// The word on screen, on a gaze moment.
    var currentWord: TrayWord? {
        if case .gaze(let i) = current, eyeWords.indices.contains(i) { return eyeWords[i] }
        return nil
    }

    /// The square everything is being compared with: the one tapped, or on the numbers moment the
    /// one the eye looked at most (so the numbers never open on a blank invitation; Mark found
    /// "tap a square" confusing with no square to see).
    var comparedSquare: Int? {
        if let s = selectedSquare { return s }
        if current == .numbers { return mostLookedSquare }
        return nil
    }

    /// Every square's likeness to square `s`, -1...1 (nil until the comparison is ready).
    func alike(to s: Int) -> [Float]? {
        if let c = alikeCache, c.square == s { return c.values }
        guard let likeness else { return nil }
        let v = likeness.alike(to: s)
        alikeCache = (s, v)
        return v
    }

    /// Word `i`'s whole look, when the shot recorded it.
    func look(_ i: Int) -> TrayLook? {
        if let cached = lookCache[i] { return cached }
        guard let e = trace?.eye, eyeWords.indices.contains(i) else { return nil }
        let made = TrayLook(word: eyeWords[i], words: eyeWords, eye: e)
        lookCache[i] = made
        return made
    }

    var currentLook: TrayLook? { currentWord.flatMap { look($0.id) } }

    /// Attention as light, 0...1, on the shot's one scale. The square root is only a display curve, so
    /// small amounts stay visible; the order of bright and dim is never changed.
    func brightness(_ v: Float) -> Float {
        lightScale > 0 ? min(1, max(0, v / lightScale)).squareRoot() : 0
    }

    /// The light on each square right now: likeness when a square is being compared, the word's
    /// attention on a gaze moment, otherwise none.
    var squareLight: [Float]? {
        if let c = comparedSquare { return alike(to: c)?.map { pow(max(0, $0), 0.8) } }
        if let w = currentWord { return w.gaze.map(brightness) }
        return nil
    }

    func wordState(_ v: Int) -> TrayWordState {
        let currentIndex = currentWord?.id
        if v == currentIndex { return .current }
        if let c = comparedSquare {
            guard eyeWords.indices.contains(v), c < eyeWords[v].gaze.count else { return .lit(0) }
            return .lit(brightness(eyeWords[v].gaze[c]))
        }
        guard let i = currentIndex else { return .lit(0) }
        if v > i { return .future }
        guard let look = look(i), v < look.onWords.count else { return .lit(0) }
        return .lit(brightness(look.onWords[v]))
    }

    /// Step `k`'s picture, or the newest decoded step before it (so the screen never sits on a spinner
    /// while a preview is on its way).
    func shownStep(for k: Int) -> Int? {
        if previews[k] != nil { return k }
        return previews.keys.filter { $0 < k }.max()
    }

    // MARK: Words for the screen

    /// The moment pill: what this moment is, in a few words.
    var title: String {
        switch current {
        case .reality: return "Your photograph"
        case .numbers:
            return comparedSquare.map { "The numbers \u{00B7} square \($0 + 1)" } ?? "The numbers"
        case .gaze(let i):
            guard eyeWords.indices.contains(i) else { return "Where it looked" }
            return "\u{201C}\(eyeWords[i].bare)\u{201D} \u{00B7} word \(i + 1) of \(eyeWords.count)"
        case .words: return (trace?.wordsFromEye ?? true) ? "What the eye said" : "Your instruction"
        case .mixing: return "Mixing the developer"
        case .step(let k): return "Step \(k) of \(max(trace?.latents.count ?? 0, trace?.steps ?? 0))"
        case .finished: return "What Thomas saw"
        }
    }

    /// The words the hand received: the eye's own, or the eye's own shortened to fit (`Shot`,
    /// `PromptBudget`).
    var handWords: String {
        let p = trace?.prompt ?? ""
        return p.isEmpty ? (trace?.eyeWords ?? "") : p
    }

    /// True when the eye said more than the hand can read and restated it in fewer words.
    var wasShortened: Bool {
        guard let t = trace, t.wordsFromEye, let w = t.eyeWords, !t.prompt.isEmpty else { return false }
        return t.prompt != w
    }

    private var shorteningHelp: String {
        let said = PromptBudget.wordCount(trace?.eyeWords ?? ""), kept = PromptBudget.wordCount(handWords)
        return "The hand can only read about 50 words. The eye said \(said), so Thomas asked the same eye to say it again in fewer, keeping everything that could be drawn: the things, their colors, textures, and where they are. It worked from its own words; it didn't look at your photograph again. The hand received \(kept) words."
    }

    /// The moment's name when the full one doesn't fit (large text, a phone held sideways): the slider
    /// already shows where the moment sits, so the counts can go.
    var shortTitle: String {
        switch current {
        case .numbers: return comparedSquare.map { "Square \($0 + 1)" } ?? "The numbers"
        case .gaze(let i): return eyeWords.indices.contains(i) ? "\u{201C}\(eyeWords[i].bare)\u{201D}" : "Where it looked"
        case .step(let k): return "Step \(k)"
        default: return title
        }
    }

    /// One short line of fact for moments that need one; the rest lives behind "?".
    var fact: String? {
        switch current {
        case .gaze(let i):
            guard currentLook == nil, eyeWords.indices.contains(i) else { return nil }
            return "\(Self.percent(eyeWords[i].imageShare)) of its attention on the picture"
        case .words:
            guard trace?.eye == nil, let name = trace?.eyeName, trace?.wordsFromEye ?? true else { return nil }
            return name == Seer.apple.name ? "Apple's eye doesn't show its workings" : "\(name) doesn't show its workings here yet"
        case .step(let k):
            // After the drawing, missing previews go through the model lane, which holds work while the
            // phone is hot (ThermalGovernor). Say that, rather than implying it is merely slow.
            let hot = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
            let waiting = (drawingDone && hot) ? "waits for the phone to cool" : "is on its way"
            // Only when there is no picture at all: then the wait needs a reason. When an earlier step
            // is showing, no note (Mark, 2026-11-13: the pill already says which step this is).
            return shownStep(for: k) == nil ? "This preview \(waiting)" : nil
        default:
            return nil
        }
    }

    /// Behind "?": a title and a focused explanation of THIS moment (Mark, 2026-11-12: "?" should be
    /// specific to the stage). The general notes belong in the user guide.
    var helpTitle: String {
        if let s = selectedSquare { return "Square \(s + 1)" }
        switch current {
        case .gaze(let i): return eyeWords.indices.contains(i) ? "\u{201C}\(eyeWords[i].bare)\u{201D}" : "Where it looked"
        default: return title
        }
    }

    var helpBody: String {
        guard let e = trace?.eye, e.squares > 0 else { return plainHelp }
        if let s = comparedSquare {
            var parts: [String] = []
            if current == .numbers {
                parts.append("Before it has a single word, the eye turns your photograph into a grid of \(e.squares) squares, \(e.rows) by \(e.cols), and describes each square with \(e.width.formatted()) numbers. That grid is its whole understanding of the picture.")
                if selectedSquare == nil { parts.append("It opens on square \(s + 1), the one the eye looked at most while it spoke.") }
            }
            parts.append("The lit squares are the ones whose \(e.width.formatted()) numbers are most like square \(s + 1)'s: brighter means more alike; dark means unlike, or opposite. Every number counts in the comparison; nothing is summarized. What all the squares have in common is set aside first, so the comparison shows how they differ.")
            if !eyeWords.isEmpty { parts.append("The words glow by how much attention each one paid to square \(s + 1) as the eye chose it.") }
            parts.append("Tap square \(s + 1) itself to read its actual numbers. Tap another square to compare from there.")
            return parts.joined(separator: "\n\n")
        }
        if let w = currentWord {
            var parts = ["As it chose \u{201C}\(w.bare)\u{201D}, the eye looked at everything in front of it at once: the picture, its instructions, and every word it had already said."]
            if let look = currentLook {
                parts.append("\(Self.percent(look.picture)) went to the picture, \(Self.percent(look.instructions)) to its instructions, and \(Self.percent(look.said)) to what it had already said. The picture glows where its attention landed; the earlier words glow by how much each one got.")
                if look.instructions >= 0.02 {
                    parts.append("Of the share on its instructions, \(Self.percent(look.markers)) landed on the invisible markers that separate their parts, not on their words.")
                }
            } else {
                parts.append("\(Self.percent(w.imageShare)) of its attention went to the picture. This shot didn't record where the rest went.")
            }
            parts.append("Light is on one scale for the whole description, so a word that barely looked at the picture leaves it dim.")
            let how = e.layers > 0 && e.heads > 0 ? "Measured in \(e.layers) attention layers, averaged over \(e.heads) heads. " : ""
            parts.append(how + "Tap a square to light the squares whose numbers are like it, and the words that looked there.")
            return parts.joined(separator: "\n\n")
        }
        return plainHelp
    }

    private var plainHelp: String {
        switch current {
        case .reality:
            return "What the lens saw, exactly as you shot it. Everything after this is the machine's: the eye reads the photograph, then the hand draws from the eye's words alone."
        case .numbers:
            return "Before it has a single word, the eye turns your photograph into a grid of squares, each described by a long list of numbers. Tap any square to light the squares whose numbers are like it."
        case .gaze:
            return "Where the eye's attention went as it chose this word."
        case .words:
            var s = (trace?.wordsFromEye ?? true)
                ? "The eye's words, exactly as it said them. They are all the hand receives: it never sees your photograph."
                : "In the silent loop the eye says nothing; the hand draws from your instruction."
            if wasShortened { s += "\n\nThey were too long for the hand, so the next moment shows the shorter version it received." }
            if trace?.eye == nil, let name = trace?.eyeName, trace?.wordsFromEye ?? true {
                s += name == Seer.apple.name
                    ? "\n\nApple's eye doesn't show its workings. Choose Qwen as the eye in Preferences to see its numbers and where it looked."
                    : "\n\n\(name) doesn't show its workings here yet."
            }
            return s
        case .mixing:
            let handed = wasShortened ? shorteningHelp : "These are the eye's words exactly as the hand received them, every one."
            return handed + "\n\nMeanwhile, the drawing model is loading\((trace?.channelsLast ?? false) ? "" : " onto the Neural Engine"). The first time after installing or updating takes a couple of minutes; after that, a second or two."
        case .step(let k):
            let of = max(trace?.latents.count ?? 0, trace?.steps ?? 0)
            let kind = (trace?.isGuess ?? false)
                ? "These previews show the engine's best guess at the finished picture after each step."
                : "These previews show the engine's working image after each step."
            let extra = (trace?.channelsLast ?? true) ? "" : " (Its method takes one extra pass at the start, so \(of - 1) steps make \(of) passes.)"
            return "The hand never sees your photograph. It starts from random noise and, over \(of) passes, refines it toward the eye's words.\(extra) This is a quick preview of the drawing engine's actual state after step \(k), made by a small preview decoder; it is not the finished drawing.\n\n" + kind
        case .finished:
            return "Thomas's hand never saw your photograph. It drew from the eye's words, filling in the rest from what it knows. This is what Thomas saw, as far as it could carry it in words.\n\nThis is the finished drawing itself, not a preview; it's saved to Photos."
        }
    }

    static func percent(_ v: Float) -> String { "\(Int((v * 100).rounded()))%" }
}

/// The Developer Tray: watch one shot develop, live, and step back through every real moment.
///
/// Full screen, like the viewfinder (Mark, 2026-11-05; touchstone Underworld's "Everything, Everything"
/// cover): the picture is the canvas and the controls are small translucent pills. The picture is never
/// cropped, because hiding part of it would hide data the eye really looked at; the space it does not
/// fill is a blurred, darkened copy of itself. Tap that backdrop to hide or show the pills.
///
/// Laid out from the 2026-11-12 design pass (mockups in screenshots-draft/design-pass-2026-11-12):
/// the top pill names the chapter (LENS / EYE / HAND); the pill above the slider names the moment; ‹ ›,
/// a swipe on the picture, or the slider move through the moments (no Play: too fast to read the data).
/// Upright, the picture sits just under the top pills, in the same place on every moment, with the
/// sentence and its facts in the calm space below; sideways, the picture fills the screen as before.
/// The eye's moments show the WHOLE look: the picture lit where attention landed and the earlier words
/// lit by how much attention they got, on one scale. Tap a square to compare every square's numbers
/// with it (the raw numbers one tap further).
struct DeveloperTrayView: View {
    @State private var model: TrayModel
    @State private var worker = DarkRoomWorker.shared
    @Environment(\.dismiss) private var dismiss
    @Namespace private var canvas
    @Environment(\.horizontalSizeClass) private var widthClass
    /// A regular-width window (iPad, the Duo's inner screen) gets larger type.
    private var roomy: Bool { widthClass == .regular }
    @Environment(\.verticalSizeClass) private var heightClass
    /// A short window: a phone held sideways, about 430 points tall (Mark, 2026-11-13: "too crushed").
    /// The pills and controls are packed tighter so the words get the height.
    private var short: Bool { heightClass == .compact }

    init(shotID: UUID) { _model = State(initialValue: TrayModel(shotID: shotID)) }

    var body: some View {
        GeometryReader { geo in
            // Side by side whenever the window is wider than tall and roomy enough for a picture plus a
            // column of words. Decided by the window's own shape, never by device or orientation: an
            // iPad window can be any size, and the Duo's inner screen ignores orientation (Apple,
            // "Prepare your app for iPhone Duo", 2026). Safe areas are respected per edge by SwiftUI.
            let wide = geo.size.width > geo.size.height && geo.size.width >= 640
            ZStack {
                backdrop
                if wide { sideLayout(geo.size) } else { tallLayout(geo.size) }
                if model.helpOpen { helpCard(wide: wide).transition(.opacity) }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .animation(.easeInOut(duration: 0.2), value: model.chromeVisible)
        .animation(.easeInOut(duration: 0.2), value: model.helpOpen)
        .statusBarHidden(!model.chromeVisible)
        .persistentSystemOverlays(model.chromeVisible ? .automatic : .hidden)
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
            if v < 0 { model.goLive() } else { model.scrub(to: v) }
            AntennaUIBridge.shared.trayScrubTo = nil
        }
        .onChange(of: AntennaUIBridge.shared.trayTap) { _, tap in
            guard let tap else { return }
            let parts = tap.split(separator: ":").map(String.init)
            let arg = parts.count > 1 ? parts[1] : ""
            switch parts.first ?? "" {
            case "word": if let i = Int(arg) { model.jump(toWord: i) }
            case "square": if let n = Int(arg) { model.tapSquare(n) }
            case "numbers": model.openSquare = model.comparedSquare
            case "close": model.openSquare = nil
            case "step": if let d = Int(arg) { model.step(d) }
            case "chapter": if let c = TrayChapter(rawValue: arg) { model.jump(to: c) }
            case "picture": model.chromeVisible.toggle()
            case "help": model.helpOpen.toggle()
            case "dismiss": dismiss()
            default: break
            }
            AntennaUIBridge.shared.trayTap = nil
        }
        #endif
    }

    private var isDeveloping: Bool { worker.currentShotID == model.shotID }

    // MARK: Layouts

    /// Upright: the pills and the picture are pinned at the top on every moment (the picture never
    /// jumps). Under them, the moment's words when it has some; the controls follow, gliding down to make
    /// room when words arrive and back up when they go (Mark loved this glide when it happened by accident,
    /// 2026-11-13; now it is on purpose). On the words moments the eye's words take the picture's place:
    /// the sentence rises to cover it and grows into the space below.
    private func tallLayout(_ size: CGSize) -> some View {
        let aspect = currentPicture.map { CGFloat($0.width) / CGFloat(max(1, $0.height)) } ?? 16.0 / 9.0
        let stageHeight = min(size.width / max(aspect, 0.1), size.height * 0.5)
        let phase = model.current.phase
        let open = phase == .words || (phase == .picture && model.current != .reality)
        return VStack(spacing: 12) {
            topBar
                .opacity(model.chromeVisible ? 1 : 0)
                .allowsHitTesting(model.chromeVisible)
            ZStack(alignment: .top) {
                if phase == .words {
                    wordsPanel(centered: false)
                        .matchedGeometryEffect(id: "words", in: canvas)
                        .padding(.horizontal, 16)
                        .transition(.opacity)
                } else {
                    VStack(spacing: 12) {
                        stage.frame(width: size.width, height: stageHeight)
                        if model.chromeVisible && open {
                            momentContent(wide: false)
                                .padding(.horizontal, 16)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                                .transition(.opacity)
                        }
                    }
                    .transition(.opacity)
                }
            }
            .frame(maxHeight: open ? .infinity : nil, alignment: .top)
            .layoutPriority(1)
            if model.chromeVisible { bottomBar.transition(.opacity) }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
        .animation(.smooth(duration: 0.55), value: phase)
        .animation(.smooth(duration: 0.55), value: open)
    }

    /// Side by side (2026-11-13 design pass, mockup screenshots-draft/design-pass-2026-11-13): the picture
    /// on the left at full height, and a column on the right with the pills, the moment's words and the
    /// controls, so nothing ever covers the squares that light up. On the words moments the words take the
    /// picture's place; on the hand's moments the column keeps the words the drawing is made from, beside it.
    private func sideLayout(_ size: CGSize) -> some View {
        let column = min(max(size.width * 0.36, 300), 440)
        let phase = model.current.phase
        return HStack(spacing: 16) {
            ZStack {
                if phase == .words {
                    wordsPanel(centered: true)
                        .matchedGeometryEffect(id: "words", in: canvas)
                        .padding(.horizontal, 12)
                        .transition(.opacity)
                } else {
                    stage.transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: 12) {
                topBar.opacity(model.chromeVisible ? 1 : 0).allowsHitTesting(model.chromeVisible)
                // The middle always takes the space, even when this moment has nothing to put there, so
                // the pills stay at the top and the controls at the bottom (iPad simulator, 2026-11-13).
                ZStack(alignment: .topLeading) {
                    Color.clear
                    if model.chromeVisible {
                        columnContent
                            .padding(.horizontal, short ? 8 : 16)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                bottomBar.opacity(model.chromeVisible ? 1 : 0).allowsHitTesting(model.chromeVisible)
            }
            .frame(width: column)
            .padding(.vertical, 6)
        }
        .animation(.smooth(duration: 0.55), value: phase)
    }

    /// The column's words for the moment on screen.
    @ViewBuilder
    private var columnContent: some View {
        switch model.current.phase {
        case .picture:
            if model.current != .reality {
                VStack(alignment: .leading, spacing: 14) {
                    if !model.eyeWords.isEmpty {
                        sentence(wide: false).matchedGeometryEffect(id: "words", in: canvas)
                    }
                    eyeFacts
                }
                .environment(\.colorScheme, .dark)
            }
        case .words:
            EmptyView()
        case .drawing:
            if !model.handWords.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text((model.trace?.wordsFromEye ?? true)
                         ? (model.wasShortened ? "Drawing from these words (shortened)" : "Drawing from these words")
                         : "Drawing from your instruction")
                        .font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                    ScrollView {
                        Text(model.handWords).font(roomy ? .title3 : .callout)
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
            }
        }
    }

    // MARK: The canvas

    /// The picture on screen right now (also what the blurred backdrop is made of).
    private var currentPicture: CGImage? {
        switch model.current {
        case .step(let k):
            if let shown = model.shownStep(for: k), let img = model.previews[shown]?.cgImage { return img }
            return model.trace?.photo
        case .finished: return model.trace?.final ?? model.trace?.photo
        default: return model.trace?.photo
        }
    }

    /// The leftover space: a blurred, darkened copy of the picture itself, edge to edge.
    /// Drawn as an overlay on plain black so a fill-scaled image can never widen the layout (first device
    /// test, 2026-11-05: as a ZStack child it did, and pushed the picture and pills off the right edge).
    private var backdrop: some View {
        Color.black
            .overlay {
                if let pic = currentPicture {
                    Image(uiImage: UIImage(cgImage: pic)).resizable().scaledToFill()
                        .blur(radius: 34)
                        .brightness(-0.35)
                        .saturation(1.2)
                }
            }
            .clipped()
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { model.chromeVisible.toggle() }
    }

    private var stage: some View {
        Group {
            switch model.current {
            case .reality, .words, .mixing:
                if let photo = model.trace?.photo {
                    picture(photo)
                } else {
                    ProgressView().tint(.white)
                }
            case .numbers, .gaze:
                if let photo = model.trace?.photo, let e = model.trace?.eye, e.squares > 0 {
                    let compared = model.comparedSquare
                    EyeLightPhoto(photo: photo, rows: e.rows, cols: e.cols,
                                  light: model.squareLight,
                                  soft: compared == nil,
                                  floor: compared == nil ? 0.2 : 0.12,
                                  outlined: compared,
                                  gridLines: model.current == .numbers || compared != nil,
                                  key: compared.map { "square\($0)" } ?? "moment\(model.index)",
                                  onTapSquare: { model.tapSquare($0) })
                }
            case .step(let k):
                Group {
                    if let shown = model.shownStep(for: k), let img = model.previews[shown]?.cgImage {
                        picture(img)
                    } else {
                        ProgressView().tint(.white)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottom) {
                    if let note = model.fact { pill { Text(note).font(.caption.weight(.medium)) }.padding(10) }
                }
            case .finished:
                if let f = model.trace?.final { picture(f) }
            }
        }
        // Swipe the picture to step through the moments.
        .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { v in
            let dx = v.translation.width
            guard abs(dx) > 50, abs(dx) > abs(v.translation.height) else { return }
            model.step(dx < 0 ? 1 : -1)
        })
    }

    private func picture(_ image: CGImage) -> some View {
        Image(uiImage: UIImage(cgImage: image)).resizable().scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { model.chromeVisible.toggle() }
    }

    // MARK: The moment's words

    /// Under the picture on the lens and eye moments: the sentence and what it means.
    @ViewBuilder
    private func momentContent(wide: Bool) -> some View {
        switch model.current {
        case .numbers, .gaze:
            VStack(alignment: .leading, spacing: 14) {
                if !model.eyeWords.isEmpty {
                    sentence(wide: wide).matchedGeometryEffect(id: "words", in: canvas)
                }
                eyeFacts
            }
            .padding(wide ? 12 : 0)
            .background {
                if wide { RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial.opacity(0.9)) }
            }
            .environment(\.colorScheme, .dark)
        default:
            EmptyView()
        }
    }

    /// The eye's sentence. The word being chosen is underlined, words not yet said are faint, and the
    /// earlier words glow by how much attention the word on screen paid them. With a square picked,
    /// every word glows by how much it looked at that square. Every word is a button.
    private func sentence(wide: Bool) -> some View {
        // Only as tall as the words need, so what follows sits right under them; it scrolls only when
        // the description is too long for the space (iPad simulator, 2026-11-13: a greedy scroll view
        // left a big empty gap between the sentence and its split bar on a tall screen).
        ViewThatFits(in: .vertical) {
            sentenceFlow
            ScrollViewReader { proxy in
                ScrollView { sentenceFlow }
                    .scrollBounceBehavior(.basedOnSize)
                    .onChange(of: model.currentWord?.id) { _, id in
                        if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                    }
                    .onAppear { if let id = model.currentWord?.id { proxy.scrollTo(id, anchor: .center) } }
            }
        }
        .frame(maxHeight: wide ? 84 : nil, alignment: .top)
    }

    private var sentenceFlow: some View {
        WordFlow(spacing: 3) {
            ForEach(model.eyeWords) { w in
                Button { model.jump(toWord: w.id) } label: {
                    TrayWordLabel(text: w.text, state: model.wordState(w.id), large: roomy)
                }
                .buttonStyle(.plain)
                .id(w.id)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    /// Under the sentence: where the whole look went, or what the lit squares mean.
    @ViewBuilder
    private var eyeFacts: some View {
        if let s = model.comparedSquare {
            VStack(alignment: .leading, spacing: 10) {
                Text(short
                     ? (model.eyeWords.isEmpty
                        ? "Lit: squares like \(s + 1). Tap \(s + 1) for its numbers."
                        : "Lit: squares like \(s + 1), and words that looked there. Tap \(s + 1) for its numbers.")
                     : (model.eyeWords.isEmpty
                        ? "Lit: squares whose numbers are like square \(s + 1)'s. Tap square \(s + 1) to see its numbers."
                        : "Lit: squares whose numbers are like square \(s + 1)'s, and the words that looked there. Tap square \(s + 1) to see its numbers."))
                    .fixedSize(horizontal: false, vertical: true)
                    .font(short ? .caption : .footnote).foregroundStyle(.white.opacity(0.75))
                if model.selectedSquare != nil, let w = model.currentWord {
                    Button { model.selectedSquare = nil } label: {
                        pill { Text("Back to \u{201C}\(w.bare)\u{201D}").font(.caption.weight(.semibold)) }
                    }
                    .buttonStyle(.plain)
                }
            }
        } else if let look = model.currentLook {
            TraySplitBar(look: look, oneLine: short)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)   // a gauge, like the controls; see topBar
        } else if let fact = model.fact {
            Text(fact).font(.footnote).foregroundStyle(.white.opacity(0.75))
        } else if model.current == .numbers, let e = model.trace?.eye {
            Text("Tap any square to compare its \(e.width.formatted()) numbers with every other square's.")
                .font(.footnote).foregroundStyle(.white.opacity(0.75))
        }
    }

    /// The words moments: the eye's words where the picture was, then the words the hand received
    /// (the same, or shortened to fit). The text the hand gets is what the drawing grows from, so the
    /// first step's noise fades in as these fade out.
    private func wordsPanel(centered: Bool) -> some View {
        let handing = model.current == .mixing
        let text = handing ? model.handWords : (model.trace?.eyeWords ?? "")
        let label: String? = {
            guard handing else { return nil }
            guard model.wasShortened else { return "Handed to the hand, word for word" }
            let kept = PromptBudget.wordCount(model.handWords), said = PromptBudget.wordCount(model.trace?.eyeWords ?? "")
            return "Shortened for the hand \u{00B7} \(kept) of \(said) words"
        }()
        let words = VStack(alignment: .leading, spacing: 12) {
            if let label {
                Text(label).font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
            }
            Text(text)
                .font((roomy ? Font.title : (short ? Font.body : Font.title3)).weight(.medium))
                .id(text)
                .transition(.opacity)
            if let fact = model.fact { Text(fact).font(.footnote).foregroundStyle(.white.opacity(0.7)) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(4)
        .animation(.easeInOut(duration: 0.45), value: text)
        // Upright the words sit where the picture was, from the top; side by side they sit centered in the
        // picture's place, as the pictures do. They scroll only when they don't fit.
        return ViewThatFits(in: .vertical) {
            words
            ScrollView { words }.scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxHeight: .infinity, alignment: centered ? .center : .top)
        .environment(\.colorScheme, .dark)
    }

    // MARK: The pills

    /// Top: close, the chapters, and "?".
    private var topBar: some View {
        HStack {
            roundPill("xmark") { dismiss() }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                ForEach(TrayChapter.allCases, id: \.self) { c in
                    let on = model.current.chapter == c
                    let has = model.has(c)
                    Button { model.jump(to: c) } label: {
                        // One line always; if a screen is ever too narrow, the label shrinks a little
                        // rather than breaking ("LE/NS") or spilling out of its pill (Mark, 2026-11-13).
                        Text(c.label).font(.caption.weight(.bold)).tracking(short ? 0.2 : 0.6)
                            .lineLimit(1).minimumScaleFactor(0.7)
                            .foregroundStyle(on ? Color.black : Color.white.opacity(has ? 0.8 : 0.3))
                            .padding(.horizontal, short ? 9 : 14).padding(.vertical, 7)
                            .background(on ? Color.white : Color.clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!has)
                    .accessibilityShowsLargeContentViewer {
                        Text(c.label)
                    }
                }
            }
            .padding(3)
            .background(.ultraThinMaterial.opacity(0.85), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            .environment(\.colorScheme, .dark)
            .layoutPriority(1)   // the gaps around it give way first
            Spacer(minLength: 8)
            roundPill("questionmark") { model.helpOpen.toggle() }
        }
        .padding(.horizontal, short ? 8 : 16)
        // The controls grow with the person's text size up to the largest standard size, which fits
        // every supported screen; past that (Accessibility sizes) they stop growing and a long press
        // shows the label large instead (the Large Content Viewer, as Apple's own bars do). The reading
        // content, the sentence, the words and "?", keeps growing all the way. (Mark, 2026-11-13: he uses
        // larger text himself: "I wanna make sure it works for everybody.")
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    /// Bottom: the moment, then ‹ the slider › (and Live while the shot is still developing).
    private var bottomBar: some View {
        VStack(spacing: 8) {
            // One name for the moment. While developing, a red dot marks that it is the newest moment.
            if !short { pill { momentName(.subheadline) } }
            HStack(spacing: 6) {
                TrayStepButton(symbol: "chevron.left", label: "Back", enabled: model.index > 0) { model.step(-1) }
                VStack(spacing: 0) {
                    // Short windows: the name rides just above the slider, no pill, to give the words the height.
                    if short { momentName(.caption).padding(.bottom, -2) }
                    TrayScrubber(count: model.frames.count, index: model.index, spans: model.chapterSpans,
                                 upcoming: model.upcoming, upcomingHandStart: model.upcomingHandStart) {
                        model.scrub(to: $0)
                    }
                }
                TrayStepButton(symbol: "chevron.right", label: "Forward", enabled: model.index < model.frames.count - 1) { model.step(1) }
                if isDeveloping {
                    Button { model.goLive() } label: {
                        pill { Text("Live").font(.caption.weight(.bold)).foregroundStyle(model.following ? .red : .white) }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, short ? 8 : 16)
        .padding(.bottom, 4)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)   // see topBar
    }

    @ViewBuilder
    private func momentName(_ font: Font) -> some View {
        // The full name if it fits; otherwise the short one (large text, Mark 2026-11-13: "make sure it
        // works for everybody"), shrinking a little before it would ever be cut off.
        ViewThatFits(in: .horizontal) {
            momentLabel(model.title)
            momentLabel(model.shortTitle)
        }
        .font(font.weight(.semibold))
        .minimumScaleFactor(0.8)
    }

    @ViewBuilder
    private func momentLabel(_ text: String) -> some View {
        if isDeveloping && model.following {
            Label(text, systemImage: "circle.fill").labelStyle(LiveDot()).lineLimit(1)
        } else {
            Text(text).lineLimit(1)
        }
    }

    /// Behind "?": this moment, explained.
    private func helpCard(wide: Bool) -> some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture { model.helpOpen = false }
            VStack(alignment: .leading, spacing: 12) {
                Text(model.helpTitle).font(.headline)
                ScrollView {
                    Text(model.helpBody).font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: wide ? 220 : 460)
                .fixedSize(horizontal: false, vertical: true)
                Button("Done") { model.helpOpen = false }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(18)
            .frame(maxWidth: wide ? 560 : .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
            .environment(\.colorScheme, .dark)
            .padding(20)
        }
    }

    private func pill<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 13).padding(.vertical, 8)
            .background(.ultraThinMaterial.opacity(0.85), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            .environment(\.colorScheme, .dark)
    }

    private func roundPill(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial.opacity(0.85), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                .environment(\.colorScheme, .dark)
        }
        .buttonStyle(.plain)
    }

    private struct SquareRef: Identifiable { let id: Int }
}

/// A small red dot before the text, for the "still developing" pill.
private struct LiveDot: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.foregroundStyle(.red).font(.system(size: 7))
            configuration.title
        }
    }
}

/// One word of the eye's sentence, lit as `TrayWordState` says.
struct TrayWordLabel: View {
    let text: String
    let state: TrayWordState
    var large = false

    var body: some View {
        let level: Double = { if case .lit(let l) = state { return Double(l) } else { return 0 } }()
        let isCurrent = state == .current
        Text(text)
            .font((large ? Font.title3 : Font.callout).weight(isCurrent ? .bold : .regular))
            .foregroundStyle(color(level))
            .padding(.horizontal, 2).padding(.vertical, 1)
            .background {
                if level > 0.12 {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(red: 1, green: 0.62, blue: 0.2).opacity(0.75 * level))
                        .blur(radius: 4)
                }
            }
            .overlay(alignment: .bottom) {
                if isCurrent { Capsule().fill(.white).frame(height: 2).offset(y: 2) }
            }
    }

    private func color(_ level: Double) -> Color {
        switch state {
        case .current: return .white
        case .future: return .white.opacity(0.32)
        case .lit: return level > 0.12 ? Color(red: 1, green: 0.9, blue: 0.75).opacity(0.62 + 0.38 * level) : .white.opacity(0.62)
        }
    }
}

/// Where one word's whole attention went: the picture, its instructions, what it had already said.
struct TraySplitBar: View {
    let look: TrayLook
    /// Short windows: the three labels on one line under the bar.
    var oneLine = false

    private var parts: [(String, Float, Color)] {
        [("picture", look.picture, Color(red: 1, green: 0.84, blue: 0.55)),
         ("its instructions", look.instructions, Color(white: 0.62)),
         ("what it had said", look.said, Color(red: 1, green: 0.59, blue: 0.24))]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                let total = max(0.0001, parts.reduce(Float(0)) { $0 + $1.1 })
                HStack(spacing: 2) {
                    ForEach(parts.indices, id: \.self) { i in
                        Capsule().fill(parts[i].2)
                            .frame(width: max(2, (geo.size.width - 4) * CGFloat(parts[i].1 / total)))
                    }
                }
            }
            .frame(height: oneLine ? 6 : 8)
            if oneLine {
                // Labeled if it fits; otherwise just the three percentages in the bar's colors (large text).
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        ForEach(parts.indices, id: \.self) { i in
                            (Text(TrayModel.percent(parts[i].1)).font(.caption.weight(.bold)).foregroundColor(parts[i].2)
                             + Text(" " + ["picture", "instructions", "already said"][i]).font(.caption).foregroundColor(.white.opacity(0.7)))
                                .lineLimit(1).fixedSize()
                        }
                    }
                    HStack(spacing: 14) {
                        ForEach(parts.indices, id: \.self) { i in
                            Text(TrayModel.percent(parts[i].1)).font(.caption.weight(.bold)).foregroundColor(parts[i].2)
                                .lineLimit(1).minimumScaleFactor(0.75)
                        }
                    }
                }
            } else {
            HStack(alignment: .top, spacing: 0) {
                ForEach(parts.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(TrayModel.percent(parts[i].1)).font(.callout.weight(.bold)).foregroundStyle(parts[i].2)
                        Text(parts[i].0).font(.caption).foregroundStyle(.white.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            }
        }
    }
}

/// The timeline slider, with a mark where each chapter begins and the chapter names under it. While
/// the shot is still developing, the moments still to come are a faint dotted track that breathes, so
/// a pause reads as "working", never as "done" or "stuck" (Mark, 2026-11-13).
struct TrayScrubber: View {
    let count: Int
    let index: Int
    let spans: [TrayChapterSpan]
    var upcoming = 0
    var upcomingHandStart: Int?
    let onScrub: (Int) -> Void

    var body: some View {
        GeometryReader { geo in
            let inset: CGFloat = 11
            let w = max(1, geo.size.width - inset * 2)
            let total = count + upcoming
            let x: (Double) -> CGFloat = { i in inset + (total > 1 ? CGFloat(i / Double(total - 1)) : 0) * w }
            let edge = x(Double(max(0, count - 1)))
            ZStack(alignment: .topLeading) {
                Capsule().fill(.white.opacity(0.25)).frame(width: max(0, edge - inset), height: 4).offset(x: inset, y: 13)
                if upcoming > 0 {
                    TimelineView(.animation) { tl in
                        let breath = 0.3 + 0.25 * sin(tl.date.timeIntervalSinceReferenceDate * 2.4)
                        Path { p in
                            p.move(to: CGPoint(x: edge, y: 15))
                            p.addLine(to: CGPoint(x: inset + w, y: 15))
                        }
                        .stroke(.white.opacity(breath), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [1, 6]))
                    }
                }
                Capsule().fill(.white).frame(width: max(4, x(Double(index)) - inset), height: 4).offset(x: inset, y: 13)
                ForEach(spans.dropFirst()) { s in
                    Capsule().fill(.white.opacity(0.75)).frame(width: 2, height: 14)
                        .offset(x: x(Double(s.first) - 0.5) - 1, y: 8)
                }
                if let h = upcomingHandStart {
                    Capsule().fill(.white.opacity(0.35)).frame(width: 2, height: 14)
                        .offset(x: x(Double(h) - 0.5) - 1, y: 8)
                    if x(Double(total - 1)) - x(Double(h)) >= 30 {
                        Text(TrayChapter.hand.rawValue).font(.caption2.weight(.medium)).foregroundStyle(.white.opacity(0.35))
                            .fixedSize()
                            .position(x: (x(Double(h)) + x(Double(total - 1))) / 2, y: 38)
                    }
                }
                Circle().fill(.white).frame(width: 22, height: 22).shadow(radius: 2)
                    .offset(x: x(Double(index)) - 11, y: 4)
                ForEach(spans) { s in
                    if x(Double(s.last)) - x(Double(s.first)) >= 30 {
                        Text(s.chapter.rawValue).font(.caption2.weight(.medium)).foregroundStyle(.white.opacity(0.55))
                            .fixedSize()
                            .position(x: (x(Double(s.first)) + x(Double(s.last))) / 2, y: 38)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                guard count > 1, total > 1 else { return }
                let f = (v.location.x - inset) / w
                onScrub(min(count - 1, max(0, Int((f * CGFloat(total - 1)).rounded()))))
            })
        }
        .frame(height: 46)
        .animation(.smooth(duration: 0.4), value: count + upcoming)
    }
}

/// The ‹ › buttons. A tap moves one moment; holding moves on at a readable pace until released (the
/// iPhone convention, like holding delete). The finger target is 52 points, past Apple's 44-point
/// minimum (Mark found the 38-point buttons hard to hit, 2026-11-13).
struct TrayStepButton: View {
    let symbol: String
    let label: String
    let enabled: Bool
    /// Move one moment; false when there is nowhere further to go.
    let step: () -> Bool
    @State private var pressed = false
    @State private var repeated = false
    @State private var holdTask: Task<Void, Never>?

    var body: some View {
        Image(systemName: symbol).font(.system(size: 16, weight: .semibold))
            .frame(width: 42, height: 42)
            .background(.ultraThinMaterial.opacity(0.85), in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(pressed ? 0.55 : 0.18), lineWidth: pressed ? 1 : 0.5))
            .scaleEffect(pressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: pressed)
            .environment(\.colorScheme, .dark)
            .frame(width: 52, height: 52)
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.4)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard enabled, !pressed else { return }
                    pressed = true
                    repeated = false
                    holdTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 450_000_000)
                        while !Task.isCancelled {
                            repeated = true
                            guard step() else { break }
                            try? await Task.sleep(nanoseconds: 330_000_000)
                        }
                    }
                }
                .onEnded { _ in
                    holdTask?.cancel()
                    holdTask = nil
                    if pressed, !repeated, enabled { _ = step() }
                    pressed = false
                })
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityShowsLargeContentViewer {
                Image(systemName: symbol)
                Text(label)
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { _ = step() }
    }
}

/// The photograph, lit square by square: full brightness where the light is 1, down to `floor` where
/// it is 0. Soft (a smooth glow between square centers) for attention; crisp squares for likeness,
/// where each square is its own comparison. Tapping reports which square was touched.
struct EyeLightPhoto: View {
    let photo: CGImage
    let rows: Int
    let cols: Int
    let light: [Float]?
    var soft = true
    var floor: Double = 0.2
    var outlined: Int?
    var gridLines = false
    var key: String = ""
    var onTapSquare: ((Int) -> Void)?

    var body: some View {
        Image(uiImage: UIImage(cgImage: photo)).resizable().scaledToFit()
            .overlay {
                ZStack {
                    if let light, let shade = Self.shade(light, rows: rows, cols: cols) {
                        Color.black.opacity(1 - floor)
                            .mask(Image(decorative: shade, scale: 1).resizable().interpolation(soft ? .high : .none))
                            .id(key)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: key)
            }
            .overlay {
                GeometryReader { geo in
                    Canvas { ctx, size in
                        guard rows > 0, cols > 0 else { return }
                        let w = size.width / CGFloat(cols), h = size.height / CGFloat(rows)
                        if gridLines {
                            var lines = Path()
                            for c in 1..<cols { lines.move(to: CGPoint(x: CGFloat(c) * w, y: 0)); lines.addLine(to: CGPoint(x: CGFloat(c) * w, y: size.height)) }
                            for r in 1..<rows { lines.move(to: CGPoint(x: 0, y: CGFloat(r) * h)); lines.addLine(to: CGPoint(x: size.width, y: CGFloat(r) * h)) }
                            ctx.stroke(lines, with: .color(.white.opacity(0.12)), lineWidth: 0.5)
                        }
                        if let o = outlined, o >= 0, o < rows * cols {
                            let rect = CGRect(x: CGFloat(o % cols) * w, y: CGFloat(o / cols) * h, width: w, height: h)
                            ctx.fill(Path(rect), with: .color(.black.opacity(0.35)))
                            ctx.stroke(Path(rect.insetBy(dx: 1, dy: 1)), with: .color(.white), lineWidth: 2)
                            // The square carries its number; tapping it opens the numbers inside it.
                            let size = min(13, max(8, min(w, h) * 0.42))
                            ctx.draw(Text("\(o + 1)").font(.system(size: size, weight: .bold)).foregroundStyle(.white),
                                     at: CGPoint(x: rect.midX, y: rect.midY))
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { loc in
                        guard let onTapSquare, rows > 0, cols > 0, geo.size.width > 0, geo.size.height > 0 else { return }
                        let c = min(cols - 1, max(0, Int(loc.x / geo.size.width * CGFloat(cols))))
                        let r = min(rows - 1, max(0, Int(loc.y / geo.size.height * CGFloat(rows))))
                        onTapSquare(r * cols + c)
                    }
                }
            }
    }

    /// One pixel per square: black, as opaque as the square is dark (1 - light).
    static func shade(_ light: [Float], rows: Int, cols: Int) -> CGImage? {
        guard rows > 0, cols > 0, light.count == rows * cols else { return nil }
        var px = [UInt8](repeating: 0, count: rows * cols * 4)
        for i in 0..<(rows * cols) {
            px[i * 4 + 3] = UInt8(clamping: Int(((1 - max(0, min(1, light[i]))) * 255).rounded()))
        }
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: cols, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: cols * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// One square's real numbers: all of them (2,048 for Qwen3.5-2B), exactly as the vision encoder made
/// them. In the tray's look (Mark, 2026-11-13: not a stark list after a colorful screen): the square's
/// own patch of photograph, blurred, is the background, its number is the title, and each number is
/// tinted by its value. The explanation is behind "?", as everywhere in the tray.
struct SquareNumbersSheet: View {
    let eye: EyeWorkings
    let square: Int
    let photo: CGImage?
    @Environment(\.dismiss) private var dismiss
    @State private var helpOpen = false

    var body: some View {
        let numbers = Array(eye.numbers(ofSquare: square))
        let row = eye.cols > 0 ? square / eye.cols : 0, col = eye.cols > 0 ? square % eye.cols : 0
        let peak = max(abs(numbers.min() ?? 0), abs(numbers.max() ?? 0), .leastNonzeroMagnitude)
        let crop = patch(row: row, col: col)
        ZStack {
            Color.black
                .overlay {
                    if let crop {
                        Image(uiImage: UIImage(cgImage: crop)).resizable().scaledToFill()
                            .blur(radius: 40).brightness(-0.32).saturation(1.3)
                    }
                }
                .clipped()
                .ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    round("xmark") { dismiss() }
                    Spacer()
                    round("questionmark") { helpOpen.toggle() }
                }
                .padding(16)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 16) {
                            if let crop {
                                Image(uiImage: UIImage(cgImage: crop)).resizable().interpolation(.none)
                                    .scaledToFit().frame(width: 84, height: 84)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white, lineWidth: 2))
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Square \(square + 1)").font(.largeTitle.weight(.bold))
                                Text("Row \(row + 1), column \(col + 1) \u{00B7} \(numbers.count.formatted()) numbers")
                                    .font(.subheadline).foregroundStyle(.white.opacity(0.75))
                            }
                        }
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), alignment: .trailing, spacing: 5) {
                            ForEach(numbers.indices, id: \.self) { j in
                                Text(fmt(numbers[j])).font(.callout.monospacedDigit())
                                    .foregroundStyle(tint(numbers[j], peak: peak))
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 30)
                }
            }
            if helpOpen {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea().onTapGesture { helpOpen = false }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Square \(square + 1)'s numbers").font(.headline)
                        Text(help(numbers)).font(.subheadline)
                        Button("Done") { helpOpen = false }
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .padding(18)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
                    .padding(20)
                }
                .transition(.opacity)
            }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .animation(.easeInOut(duration: 0.2), value: helpOpen)
        .presentationBackground(.black)
        .presentationDragIndicator(.visible)
    }

    private func help(_ numbers: [Float]) -> String {
        let lo = numbers.min().map(fmt) ?? "", hi = numbers.max().map(fmt) ?? ""
        return "This is how \(eye.model)'s eye holds square \(square + 1) of your photograph, before it has a single word for it: \(numbers.count.formatted()) numbers straight out of its vision encoder, shown to 3 decimal places. Here they run from \(lo) to \(hi).\n\nEach number is tinted by its value: warm above zero, cool below, brighter the further from zero.\n\nA single number doesn't mean anything nameable on its own; the meaning is spread across all of them together. That's why the tray compares squares using all \(numbers.count.formatted()) at once."
    }

    private func tint(_ v: Float, peak: Float) -> Color {
        let strength = Double(min(1, abs(v) / peak)).squareRoot()
        let base = v >= 0 ? Color(red: 1, green: 0.78, blue: 0.5) : Color(red: 0.55, green: 0.78, blue: 1)
        return base.opacity(0.4 + 0.6 * strength)
    }

    private func round(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial.opacity(0.85), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
