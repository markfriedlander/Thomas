//
//  DarkRoomQueue.swift
//  Thomas / AI Camera
//
//  The dark room queue — the durable, resumable line where shots wait to be developed.
//  (Not to be confused with `Darkroom`, the frame compositor. Naming per Mark, 2026-07-19:
//  "the dark room queue" = the waiting/developing line; "the darkroom" = the compositor.)
//
//  THE INVARIANT this whole file serves: once the shutter fires, nothing you shot is lost
//  until it is safely in Photos. A shot's only exit is a successful save.
//
//  This file grows in phases (see NEXT.md → "THE DARK ROOM QUEUE"). Phase 1, here first:
//  `ShotConfig`, the frozen render snapshot.
//

// ==== LEGO START: 35 The Dark Room Queue (Durable Developing) ====

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import UIKit   // the worker composites [UIImage] and saves to Photos

// MARK: - Frozen render config

// The queue persists shots to disk, so the render settings must be Codable. These enums are
// already `String`-backed (the app stores them by rawValue in UserDefaults), so Codable is
// synthesized from that same stable rawValue — the on-disk format matches what the app already
// treats as each setting's identity.
extension Seer: Codable {}
extension Layout: Codable {}
extension FrameTwoWords: Codable {}
extension DrawingSize: Codable {}
extension UpscaleMethod: Codable {}
extension DecoderChoice: Codable {}

/// A complete, frozen copy of every setting that affects how a shot develops — taken at the
/// instant the shutter is pressed. This, not the live `Settings`, is what develops the shot,
/// no matter how the user changes settings afterward (Mark's rule, 2026-07-19).
///
/// ⚠️ COMPLETENESS is the whole point (Mark): a setting missing here means a shot develops
/// wrong. The authoritative list is `Settings.resetEverything()` — every setting it resets must
/// appear here. If you add a render setting, add it to BOTH. Cross-checked 2026-07-19: the nine
/// below are exactly what `resetEverything()` sets.
///
/// The eye is captured explicitly (`seer`). The drawer is implicit today — sd-turbo whenever
/// `drawsThirdFrame` is on — because there is only one drawer. When #6 adds a drawer choice, a
/// drawer id joins this struct (and `version` bumps).
nonisolated struct ShotConfig: Codable, Sendable, Equatable {
    /// On-disk schema version, so a future change can migrate old records instead of failing.
    var version: Int = 1

    var seer: Seer                  // the eye
    var layout: Layout
    var drawsThirdFrame: Bool       // whether the drawer (sd-turbo) runs
    var systemPrompt: String
    var temperature: Double
    var frameTwoShows: FrameTwoWords
    var drawingSize: DrawingSize
    var upscaler: UpscaleMethod
    var decoderChoice: DecoderChoice
}

extension ShotConfig {
    /// Freeze the live settings into a config, at shutter-press. Main-actor because it reads the
    /// shared, observable `Settings`.
    @MainActor
    static func capture() -> ShotConfig {
        let s = Settings.shared
        return ShotConfig(
            seer: s.seer,
            layout: s.layout,
            drawsThirdFrame: s.drawsThirdFrame,
            systemPrompt: s.systemPrompt,
            temperature: s.temperature,
            frameTwoShows: s.frameTwoShows,
            drawingSize: s.drawingSize,
            upscaler: s.upscaler,
            decoderChoice: s.decoderChoice
        )
    }
}

// MARK: - The persisted record

/// One shot waiting in the dark room, persisted as JSON beside its photo file. Its mere
/// existence means "not yet safely in Photos" — the record and photo are created together at
/// shutter-press and deleted together, and only, after a successful save. So anything found on
/// disk at launch is a shot still to develop. That single rule is the whole resume story.
nonisolated struct ShotRecord: Codable, Sendable, Identifiable {
    let id: UUID
    let photoFile: String    // filename within the store directory
    let config: ShotConfig
    let capturedAt: Date      // FIFO order = the order shots were taken; also the footer's date
    let place: String?        // where the shot was TAKEN — frozen so a resumed shot stamps true
    var status: ShotStatus
}

/// Coarse status. `done` is never a value — a done shot is deleted, not marked. `blocked` is
/// Phase 2 (the config names a model that isn't installed).
nonisolated enum ShotStatus: String, Codable, Sendable {
    case pending
    case blocked
}

// MARK: - The durable store

/// Where captured photos and their records live until they are safely in Photos. An actor, so all
/// file work serializes.
///
/// Lives in **Application Support** — which iOS does NOT purge, unlike Caches — in a folder
/// **excluded from iCloud backup** (developing state is transient and must not burn the user's
/// backup quota; the same care `SharedModelStore` takes for model weights).
actor DarkRoomStore {
    static let shared = DarkRoomStore()

    private let dir: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("DarkRoom", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        excludeFromBackup(dir)
    }

    /// Persist the photo + record, then return the record. **This is the durability point:** once
    /// this returns, the shot survives a crash. Photo is written first, then the record — so a
    /// record on disk always has its photo.
    func enqueue(photoData: Data, config: ShotConfig, place: String?) throws -> ShotRecord {
        let id = UUID()
        let photoName = "\(id.uuidString).png"
        try photoData.write(to: dir.appendingPathComponent(photoName), options: .atomic)
        let record = ShotRecord(id: id, photoFile: photoName, config: config,
                                capturedAt: Date(), place: place, status: .pending)
        try writeRecord(record)
        return record
    }

    /// Every shot on disk, oldest first (FIFO = the order they were taken). A record that fails to
    /// decode is skipped and logged rather than crashing — its photo is orphaned, a rare edge we
    /// accept over losing the whole queue to one bad file.
    func pending() -> [ShotRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var records: [ShotRecord] = []
        for url in files where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url),
               let record = try? JSONDecoder().decode(ShotRecord.self, from: data) {
                records.append(record)
            } else {
                cameraLog("DARKROOM: skipped unreadable record \(url.lastPathComponent)")
            }
        }
        return records.sorted { $0.capturedAt < $1.capturedAt }
    }

    /// The saved photo bytes for a record, or nil if the file is missing.
    func photoData(for record: ShotRecord) -> Data? {
        try? Data(contentsOf: dir.appendingPathComponent(record.photoFile))
    }

    /// Persist a changed record (e.g. status → blocked).
    func update(_ record: ShotRecord) throws { try writeRecord(record) }

    /// Delete a shot — photo + record together. Called ONLY after a successful Photos save, or on
    /// an explicit purge. This is a shot's only exit.
    func remove(_ record: ShotRecord) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(record.photoFile))
        try? FileManager.default.removeItem(at: recordURL(record.id))
    }

    // MARK: helpers
    private func recordURL(_ id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).json") }
    private func writeRecord(_ record: ShotRecord) throws {
        try JSONEncoder().encode(record).write(to: recordURL(record.id), options: .atomic)
    }
}

/// Exclude a URL from iCloud/iTunes backup (App Review 2.5.1; `SharedModelStore` does the same for
/// model weights). Transient developing state should not consume the user's backup quota.
nonisolated private func excludeFromBackup(_ url: URL) {
    var u = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? u.setResourceValues(values)
}

// MARK: - Photo encode/decode

/// The captured frame ↔ the bytes we store. **PNG — lossless.** This is the safety copy of the
/// reality frame of a *camera*; a lossy temp would degrade the very frame the app is about, and
/// double up with the final save's compression. PNG adds zero loss (it preserves the `CGImage`
/// exactly). The cost is size — a 12 MP frame is tens of MB — but the file is temporary and
/// deleted the instant the shot is safely in Photos, so fidelity wins over transient disk.
///
/// (Even better would be storing the camera's *original* captured bytes verbatim — no re-encode at
/// all — but develop() hands us an already-decoded `CGImage`; whether we can grab the original data
/// is a question for when the shutter is rewired.) `CGImage` is deliberately never passed across an
/// actor boundary — these run wherever the image already is.
nonisolated enum ShotPhoto {
    static func encode(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, nil)   // PNG is lossless — no quality knob
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    static func decode(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}

// MARK: - The worker

/// The single serial task that develops queued shots, in order, and deletes each **only** after
/// it is safely in Photos. This is where the invariant is enforced.
///
/// One loop, app-wide. `kick()` is idempotent — it starts the loop if it isn't already running
/// and does nothing if it is — so it can be fired liberally: after every enqueue (develop now),
/// and on every foreground activation (which is the entire resume-after-crash/background/call
/// story — a shot left on disk gets picked up the next time the app is alive).
///
/// `@Observable` so the sacred capture screen's "Developing N" toast and the Photos-glyph pulse
/// can read the queue's depth and completions without knowing anything about how it works. The
/// heavy pipeline runs through the shared `ModelLane`, so a queued shot and a remote `/press` can
/// never run two heavy ops at once (that was the original jetsam). The thermal hold and the memory
/// settle live inside the lane, so a hot or un-reclaimed phone waits there before a shot begins.
@MainActor
@Observable
final class DarkRoomWorker {
    static let shared = DarkRoomWorker()

    /// How many shots are still in the bath (waiting + the one developing). Drives the toast.
    private(set) var developingCount: Int = 0

    /// Bumps each time a developed shot lands in Photos, so the capture screen can pulse the
    /// Photos glyph. A counter, not a bool, because the pulse triggers on the *change*.
    private(set) var arrivals: Int = 0

    private var running = false
    /// Set by every `kick()`, cleared at the top of each drain pass. It closes a wakeup race:
    /// a shot enqueued during the loop's final (empty) `pending()` read would otherwise find
    /// `running == true`, no-op the kick, and then watch the loop exit — stranding that shot on
    /// disk until the next foreground activation. Because `kick()` always raises this flag and the
    /// loop re-checks it before exiting, a shot that arrives mid-drain is always picked up.
    private var dirty = false

    private init() {}

    /// Begin developing if not already, and mark that there is new work. Idempotent; cheap to
    /// over-call (after every enqueue, on every foreground activation).
    func kick() {
        dirty = true
        guard !running else { return }
        running = true
        Task { await loop() }
    }

    /// Drain the queue: pull pending shots FIFO and develop them until empty, then — because a
    /// shot may have arrived while we were draining — re-drain as long as `dirty` was raised. Stop
    /// (leaving the shot on disk for the next kick) only if a save fails, so we never spin re-
    /// developing an unsaveable shot.
    private func loop() async {
        defer { running = false; developingCount = 0 }
        while dirty {
            dirty = false
            while true {
                let pending = await DarkRoomStore.shared.pending().filter { $0.status == .pending }
                developingCount = pending.count
                guard let shot = pending.first else { break }
                let saved = await develop(shot)
                // A failed save (e.g. Photos permission denied) will fail again immediately; stop
                // rather than burn the battery re-developing the same shot. Nothing is lost — it
                // stays on disk — and the next foreground kick retries.
                guard saved else { return }
            }
        }
    }

    /// Develop one shot end to end. Returns whether it was saved (and thus removed from the queue).
    private func develop(_ shot: ShotRecord) async -> Bool {
        // Decode the saved reality frame. If the photo is gone or unreadable there is nothing to
        // develop and nothing to recover — drop the record so the loop can't spin on it forever.
        guard let data = await DarkRoomStore.shared.photoData(for: shot),
              let photograph = ShotPhoto.decode(data) else {
            cameraLog("DARKROOM: shot \(shot.id) has no readable photo — dropping")
            await DarkRoomStore.shared.remove(shot)
            return true   // "handled" — the queue moves on
        }

        let config = shot.config

        // The heavy pipeline — see, tear the eye down, draw — through the ONE lane shared with the
        // antenna. Only Sendable values cross back; the cheap compositor + save stay out here.
        let result: (perception: Perception, drawn: UIImage?, wordsForHand: String) =
            await ModelLane.shared.run("darkroom") { @MainActor in
                await Shot.seeThenDraw(photograph, config: config)
            }

        // Which words frame 2 shows — the eye's full perception, or the (possibly condensed)
        // version the hand drew from. Same rule as the live shutter.
        let frameTwoWords = config.frameTwoShows == .fullPerception
            ? result.perception.wireText
            : result.wordsForHand

        // The footer testifies to when and where the photo was TAKEN — the frozen `capturedAt`
        // and `place`, not develop-time — so a shot resumed hours after a crash still stamps its
        // true moment and location. That is reality's receipt.
        let frames = Darkroom.develop(photograph: photograph,
                                      words: frameTwoWords,
                                      drawing: result.drawn?.cgImage,
                                      place: shot.place,
                                      layout: config.layout,
                                      date: shot.capturedAt)

        // The invariant's one exit: delete ONLY after Photos confirms the save. Any failure
        // leaves the photo + record on disk to retry.
        guard await Shot.save(frames) else {
            cameraLog("DARKROOM: save failed for shot \(shot.id) — left in queue to retry")
            return false
        }
        await DarkRoomStore.shared.remove(shot)
        arrivals += 1
        return true
    }
}

// ==== LEGO END: 35 The Dark Room Queue (Durable Developing) ====
