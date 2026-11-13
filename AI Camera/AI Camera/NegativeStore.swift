//
//  NegativeStore.swift
//  Thomas
//
//  The negatives: what a developed shot leaves behind in the Dark Room, so the Developer Tray
//  can open it again later. Prints go to Photos; negatives stay here for a while.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// ==== LEGO START: 40 The Negatives (Recent Shots, Kept For The Tray) ====

/// One kept shot's description. The heavy parts (the numbers, the gaze, the steps, the pictures)
/// live in files beside it; this is what the Dark Room list and the tray need to know first.
nonisolated struct NegativeMeta: Codable, Sendable, Identifiable {
    struct Piece: Codable, Sendable { let text: String; let imageShare: Float }
    struct Eye: Codable, Sendable {
        let model: String
        let width: Int, rows: Int, cols: Int
        let layers: Int, heads: Int
        let recorderMS: Double
        let pieces: [Piece]
        /// The prompt as tokens, and where its image squares sit: what each word's whole attention
        /// (context.f32) is measured over. Absent in negatives kept before 2026-11-12.
        var promptPieces: [String]? = nil
        var promptImagePositions: [Int]? = nil
    }

    var formatVersion = 1
    let id: UUID
    let capturedAt: Date
    let place: String?
    let eyeName: String?
    let eyeWords: String?
    let wordsFromEye: Bool
    let prompt: String
    let steps: Int
    let isGuess: Bool
    let channelsLast: Bool
    let hand: String
    let shape: [Int]
    let latentCount: Int
    let hasDrawing: Bool
    let eye: Eye?

    /// The start of what the eye said, for the Dark Room row.
    var firstWords: String {
        let w = (eyeWords ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return w.isEmpty ? "No words" : w
    }
}

/// The Dark Room's negatives: for each of the most recent shots, what the Photos app has no place
/// for (Mark, 2026-11-05: "negatives in the Dark Room, 20 by default but allow people to keep more").
///
/// **Prints go to Photos; this is not a second photo library.** The photograph, the words and the
/// drawing are saved to Photos exactly as before. What is kept here is the machine's workings, the
/// material the Developer Tray is made of: the eye's numbers and where it looked for each word, the
/// drawing's in-between steps, plus a reduced copy of the photograph and the finished drawing so the
/// tray has something to draw them on. About 2-3 MB a shot. Only the last `limit` shots are kept
/// (Settings `negativesToKeep`); older negatives are deleted as new ones arrive. Their prints stay
/// safe in Photos.
///
/// Folder per shot under Application Support/Negatives, excluded from device backup (an optional
/// encrypted iCloud copy, Hal 4's pattern, is a possible later addition: NEXT.md item D).
///
/// Formats: the numbers and the gaze are stored as 32-bit floats, exactly as recorded, because the
/// tray shows the numbers to the user as real values. The drawing's steps are stored as 16-bit
/// floats: they are only ever decoded into quick previews, where the difference cannot be seen,
/// and it halves the largest file.
actor NegativeStore {
    static let shared = NegativeStore()

    private let root: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = base.appendingPathComponent("Negatives", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var u = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
    }

    // MARK: Keeping

    /// File a developed shot's negative, then prune to `limit`. `trace` must be this shot's.
    func keep(_ trace: DevelopTrace.Snapshot, id: UUID, capturedAt: Date, place: String?, limit: Int) {
        let started = Date()
        let dir = folder(id)
        try? FileManager.default.removeItem(at: dir)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let eye = trace.eye.flatMap { e -> NegativeMeta.Eye? in
                guard e.squares > 0 else { return nil }
                let keepsContext = Self.contextIsWhole(e)
                return NegativeMeta.Eye(model: e.model, width: e.width, rows: e.rows, cols: e.cols,
                                        layers: e.layers, heads: e.heads, recorderMS: e.recorderMS,
                                        pieces: e.pieces.map { .init(text: $0.text, imageShare: $0.imageShare) },
                                        promptPieces: keepsContext ? e.promptPieces : nil,
                                        promptImagePositions: keepsContext ? e.promptImagePositions : nil)
            }
            let meta = NegativeMeta(id: id, capturedAt: capturedAt, place: place, eyeName: trace.eyeName,
                                    eyeWords: trace.eyeWords, wordsFromEye: trace.wordsFromEye,
                                    prompt: trace.prompt, steps: trace.steps, isGuess: trace.isGuess,
                                    channelsLast: trace.channelsLast, hand: trace.hand, shape: trace.shape,
                                    latentCount: trace.latents.count, hasDrawing: trace.final != nil, eye: eye)
            if let photo = trace.photo, let reduced = Self.reduced(photo, maxPixel: 1600) {
                try Self.write(reduced, type: .jpeg, quality: 0.85, to: dir.appendingPathComponent("photo.jpg"))
            }
            if let drawing = trace.final {
                try Self.write(drawing, type: .png, quality: 1, to: dir.appendingPathComponent("drawing.png"))
            }
            if !trace.latents.isEmpty {
                let half = trace.latents.flatMap { $0.map(Float16.init) }
                try Self.data(half).write(to: dir.appendingPathComponent("steps.f16"))
            }
            if let e = trace.eye, e.squares > 0 {
                try Self.data(e.features).write(to: dir.appendingPathComponent("numbers.f32"))
                try Self.data(e.pieces.flatMap(\.gaze)).write(to: dir.appendingPathComponent("gaze.f32"))
                // Each word's whole attention (picture, instructions, earlier words), exactly as
                // recorded: word i's row is (prompt length + i) long, so the rows are simply laid end
                // to end and cut apart again on load.
                if Self.contextIsWhole(e) {
                    try Self.data(e.pieces.flatMap(\.context)).write(to: dir.appendingPathComponent("context.f32"))
                }
            }
            // The description goes last: a folder without it is unfinished and is never listed.
            try JSONEncoder().encode(meta).write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
            cameraLog("NEGATIVES: kept \(id.uuidString.prefix(8)) (\(Self.formatBytes(Self.size(of: dir)))) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        } catch {
            try? FileManager.default.removeItem(at: dir)
            cameraLog("NEGATIVES: could not keep \(id.uuidString.prefix(8)) - \(error.localizedDescription)")
        }
        prune(to: limit)
    }

    /// Keep only the newest `limit` negatives (and clear away any unfinished folder).
    func prune(to limit: Int) {
        let all = list()
        for old in all.dropFirst(max(0, limit)) { try? FileManager.default.removeItem(at: folder(old.id)) }
        let listed = Set(all.prefix(max(0, limit)).map(\.id))
        for dir in subfolders() where UUID(uuidString: dir.lastPathComponent).map({ !listed.contains($0) }) ?? true {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: Reading

    /// True when every word piece carries its whole attention row (prompt length + its position).
    private static func contextIsWhole(_ e: EyeWorkings) -> Bool {
        let p = e.promptPieces.count
        return p > 0 && !e.pieces.isEmpty && e.pieces.indices.allSatisfy { e.pieces[$0].context.count == p + $0 }
    }

    /// Every kept negative, newest first.
    func list() -> [NegativeMeta] {
        subfolders().compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")) else { return nil }
            return try? JSONDecoder().decode(NegativeMeta.self, from: data)
        }
        .sorted { $0.capturedAt > $1.capturedAt }
    }

    func contains(_ id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: folder(id).appendingPathComponent("meta.json").path)
    }

    /// A kept shot, rebuilt as the same snapshot the tray reads while a shot develops live.
    func load(_ id: UUID) -> DevelopTrace.Snapshot? {
        let dir = folder(id)
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
              let m = try? JSONDecoder().decode(NegativeMeta.self, from: data) else { return nil }
        let photo = Self.image(at: dir.appendingPathComponent("photo.jpg"))
        let drawing = Self.image(at: dir.appendingPathComponent("drawing.png"))
        var latents: [[Float]] = []
        let per = m.shape.reduce(1, *)
        if m.latentCount > 0, per > 0, let d = try? Data(contentsOf: dir.appendingPathComponent("steps.f16")) {
            let half: [Float16] = Self.values(d)
            if half.count == per * m.latentCount {
                latents = (0..<m.latentCount).map { k in half[(k * per)..<((k + 1) * per)].map(Float.init) }
            }
        }
        var eye: EyeWorkings?
        if let e = m.eye {
            var w = EyeWorkings(model: e.model)
            w.width = e.width; w.rows = e.rows; w.cols = e.cols
            w.layers = e.layers; w.heads = e.heads; w.recorderMS = e.recorderMS; w.done = true
            if let d = try? Data(contentsOf: dir.appendingPathComponent("numbers.f32")) { w.features = Self.values(d) }
            let squares = e.rows * e.cols
            if let d = try? Data(contentsOf: dir.appendingPathComponent("gaze.f32")) {
                let g: [Float] = Self.values(d)
                if squares > 0, g.count == squares * e.pieces.count {
                    w.pieces = e.pieces.enumerated().map { i, p in
                        .init(text: p.text, gaze: Array(g[(i * squares)..<((i + 1) * squares)]), imageShare: p.imageShare)
                    }
                }
            }
            if let prompt = e.promptPieces, let positions = e.promptImagePositions, w.pieces.count == e.pieces.count,
               let d = try? Data(contentsOf: dir.appendingPathComponent("context.f32")) {
                let all: [Float] = Self.values(d)
                let p = prompt.count, n = w.pieces.count
                if all.count == n * p + n * (n - 1) / 2 {
                    var at = 0
                    for i in 0..<n { w.pieces[i].context = Array(all[at..<(at + p + i)]); at += p + i }
                    w.promptPieces = prompt; w.promptImagePositions = positions
                }
            }
            eye = w
        }
        return DevelopTrace.Snapshot(version: 0, shotID: m.id, photo: photo, eyeWords: m.eyeWords,
                                     wordsFromEye: m.wordsFromEye, prompt: m.prompt, steps: m.steps,
                                     isGuess: m.isGuess, channelsLast: m.channelsLast, hand: m.hand,
                                     shape: m.shape, latents: latents, final: drawing,
                                     eye: eye, eyeName: m.eyeName)
    }

    /// A small picture of the kept photograph, for the Dark Room row.
    func thumbnail(_ id: UUID, maxPixel: Int) -> CGImage? {
        let url = folder(id).appendingPathComponent("photo.jpg")
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }

    /// Total bytes the negatives take up.
    func totalBytes() -> Int { Self.size(of: root) }

    // MARK: Removing (only ever the negative; the prints are in Photos)

    func remove(_ id: UUID) { try? FileManager.default.removeItem(at: folder(id)) }

    func removeAll() { for dir in subfolders() { try? FileManager.default.removeItem(at: dir) } }

    // MARK: Helpers

    private func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }

    private func subfolders() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.hasDirectoryPath }
    }

    private static func data<T>(_ values: [T]) -> Data { values.withUnsafeBytes { Data($0) } }

    private static func values<T>(_ data: Data) -> [T] {
        data.withUnsafeBytes { Array($0.bindMemory(to: T.self)) }
    }

    private static func image(at url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    private static func reduced(_ image: CGImage, maxPixel: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > maxPixel else { return image }
        let scale = Double(maxPixel) / Double(longest)
        let w = Int((Double(image.width) * scale).rounded()), h = Int((Double(image.height) * scale).rounded())
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    private static func write(_ image: CGImage, type: UTType, quality: Double, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    nonisolated static func size(of url: URL) -> Int {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let f as URL in e { total += (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        return total
    }

    nonisolated static func formatBytes(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }
}

// ==== LEGO END: 40 The Negatives (Recent Shots, Kept For The Tray) ====
