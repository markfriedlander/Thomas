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
// treats as each setting's identity. (`Seer` is the exception: it carries an associated repo
// id, so it has its own hand-written `Codable` next to the type — see CameraView block 22.)
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
    let capturedAt: Date      // the moment the shot was taken; also the footer's date
    let place: String?        // where the shot was TAKEN — frozen so a resumed shot stamps true
    var status: ShotStatus

    /// The develop order the user set by hand in the Dark Room, if any. `nil` = never reordered,
    /// so the shot keeps its natural FIFO place (by `capturedAt`). Optional on purpose: records
    /// written before Phase 2 decode cleanly with no migration (a missing key → `nil`). See
    /// `DarkRoomStore.pending()` for how the two combine into one order.
    var queueOrder: Double? = nil

    /// When `status == .blocked`, the display name of the model this shot needs but that is not
    /// installed (e.g. "Qwen3.5-2B" or "SD-Turbo"), so the row can say exactly what to re-download.
    /// `nil` whenever the shot is not blocked. Also optional for the same no-migration reason.
    var blockedModel: String? = nil
}

/// Coarse status. `done` is never a value — a done shot is deleted, not marked. `blocked` means
/// the frozen config names a model that isn't installed right now (see `blockedModel`); the worker
/// holds the shot and flips it back to `pending` the moment that model is installed again.
nonisolated enum ShotStatus: String, Codable, Sendable {
    case pending
    case blocked
}

/// Where a shot is in the pipeline right now — surfaced by the worker for the one shot it is
/// actively developing, so the Dark Room screen can show "seeing / drawing / saving" on that row.
/// Every other shot's row is derived without this: `waiting` if pending, `blocked` if blocked.
nonisolated enum DevelopStage: String, Sendable {
    case seeing    // the eye is reading the photograph (frame 2)
    case drawing   // the hand is drawing from the words (frame 3)
    case saving    // compositing the frames and writing to Photos
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

    /// Every shot on disk, in develop order. That order is FIFO by `capturedAt` (the order shots
    /// were taken) UNLESS the user hand-reordered in the Dark Room, in which case `queueOrder`
    /// wins — the two fold into one key so a reordered queue and a fresh one sort the same way. A
    /// record that fails to decode is skipped and logged rather than crashing — its photo is
    /// orphaned, a rare edge we accept over losing the whole queue to one bad file.
    ///
    /// Despite the name this returns EVERY record (pending and blocked); callers filter by status.
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
        return records.sorted { sortKey($0) < sortKey($1) }
    }

    /// The one develop-order key: the user's hand-set `queueOrder` if present, else the capture
    /// time. Hand-ordered shots (small explicit values) sort ahead of never-touched ones, so a new
    /// shot taken after a reorder falls in at the back, which is what the user expects.
    private func sortKey(_ r: ShotRecord) -> Double { r.queueOrder ?? r.capturedAt.timeIntervalSince1970 }

    /// The saved photo bytes for a record, or nil if the file is missing.
    func photoData(for record: ShotRecord) -> Data? {
        try? Data(contentsOf: dir.appendingPathComponent(record.photoFile))
    }

    /// A small thumbnail of a shot's reality frame, for the Dark Room list. Downsampled straight
    /// off disk via ImageIO (`kCGImageSourceThumbnail*`), so a 12 MP PNG never fully decodes into
    /// memory just to draw a 60-point row — it reads only enough to produce `maxPixel`.
    func thumbnail(for record: ShotRecord, maxPixel: Int) -> CGImage? {
        let url = dir.appendingPathComponent(record.photoFile)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }

    /// Persist a changed record (e.g. status → blocked, or a new `queueOrder`).
    func update(_ record: ShotRecord) throws { try writeRecord(record) }

    /// Apply a hand-set order: the given ids become positions 0, 1, 2… Any record not in the list
    /// is left as it was. Called from the Dark Room's drag-to-reorder.
    func reorder(_ orderedIDs: [UUID]) {
        for (index, id) in orderedIDs.enumerated() {
            guard var record = record(for: id) else { continue }
            record.queueOrder = Double(index)
            try? writeRecord(record)
        }
    }

    /// One record by id, or nil if it's gone.
    private func record(for id: UUID) -> ShotRecord? {
        guard let data = try? Data(contentsOf: recordURL(id)) else { return nil }
        return try? JSONDecoder().decode(ShotRecord.self, from: data)
    }

    /// Delete a shot — photo + record together. Called ONLY after a successful Photos save, or on
    /// an explicit purge. This is a shot's only exit.
    func remove(_ record: ShotRecord) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(record.photoFile))
        try? FileManager.default.removeItem(at: recordURL(record.id))
    }

    /// Purge a shot by id (the Dark Room's swipe-to-delete). Permanent — the photo and record are
    /// gone. Loads the record only to reuse the same photo+record removal.
    func remove(id: UUID) {
        if let record = record(for: id) { remove(record) }
    }

    /// Purge the entire queue (the Dark Room's "clear all"). Permanent. Removes every photo and
    /// record in the store directory.
    func removeAll() {
        for record in pending() { remove(record) }
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

    /// How many shots are still in the bath (waiting + the one developing). The worker is the
    /// producer of the annunciator's "developing" family: `didSet` mirrors every change into the
    /// shared `StatusFeed`, so the capture screen's status panel renders it without knowing anything
    /// about the queue. Still exposed as a property because the antenna's `/darkroom` reads it too.
    private(set) var developingCount: Int = 0 { didSet { syncStatusFeed() } }

    /// How many shots are blocked, waiting for a model they need to be installed. Drives state 3 of
    /// the one dark-room pill, and like `developingCount` it mirrors into the `StatusFeed` on change.
    private(set) var blockedCount: Int = 0 { didSet { syncStatusFeed() } }

    /// Bumps each time a developed shot lands in Photos, so the capture screen can pulse the
    /// Photos glyph. A counter, not a bool, because the pulse triggers on the *change*. (Not a feed
    /// message: it's a one-shot glyph animation, not a standing status.)
    private(set) var arrivals: Int = 0

    /// True while the worker is holding a shot because the phone is too hot to develop. The worker
    /// is also the producer of the annunciator's "thermal" family: `didSet` mirrors it into the
    /// `StatusFeed` as the "Cooling down…" message, so the user understands the pause (nothing is
    /// lost; it resumes when the phone cools). Distinct from `developingCount`.
    private(set) var isCoolingDown: Bool = false { didSet { syncStatusFeed() } }

    /// The shot the worker is actively developing right now, and how far along it is. The Dark Room
    /// screen reads these to show "seeing / drawing / saving" on that one row; every other row is
    /// derived from its own status (waiting or blocked). `nil` when nothing is developing.
    private(set) var currentShotID: UUID? = nil
    private(set) var currentStage: DevelopStage? = nil

    /// True while the app is backgrounded. The worker stops pulling new shots and, after the
    /// operation already in flight finishes (inside iOS's grace window), abandons that shot WITHOUT
    /// saving anything partial — the shot's durable record is left untouched, so foregrounding
    /// re-develops it whole from the start. This is the background-safety guarantee (Mark,
    /// 2026-07-21): never carry a half-finished develop across a background transition, so a heavy
    /// GPU op can never be suspended mid-flight and take the app down.
    private var suspended = false

    /// True while the user has paused the queue from the Dark Room screen. Like `suspended`, it
    /// stops the worker pulling new shots, but it is a deliberate user hold (not a lifecycle event)
    /// and persists across foregrounds until the user resumes. Mirrors into the pill (state 4).
    private(set) var isPaused = false { didSet { syncStatusFeed() } }

    /// The current drain task, held so `suspendForBackground()` can await it reaching a safe stop
    /// (the in-flight op finished, nothing saved) before the app unloads models.
    private var loopTask: Task<Void, Never>? = nil

    private var running = false
    /// Set by every `kick()`, cleared at the top of each drain pass. It closes a wakeup race:
    /// a shot enqueued during the loop's final (empty) `pending()` read would otherwise find
    /// `running == true`, no-op the kick, and then watch the loop exit — stranding that shot on
    /// disk until the next foreground activation. Because `kick()` always raises this flag and the
    /// loop re-checks it before exiting, a shot that arrives mid-drain is always picked up.
    private var dirty = false

    private init() {}

    /// Mirror the worker's live state into the shared `StatusFeed` (the annunciator). The worker
    /// owns the developing + thermal families; a producer publishes when its condition holds and
    /// clears when it ends. Called from the `didSet`s above, so there is one code path and it can't
    /// drift from the real state. `publish` is a no-op when the message is unchanged, so the extra
    /// calls from same-value assignments cost nothing.
    private func syncStatusFeed() {
        // One pill, five states, by precedence (Mark, 2026-07-21):
        //   1. cooling down — this is WHY nothing is progressing, so it speaks over the rest
        //   2. paused (with shots waiting) — the user stopped it on purpose; why they aren't moving
        //   3. developing N — shots actively in the bath
        //   4. N blocked — shown only when nothing is developing (blocked shots are the whole story)
        //   5. nothing to report → clear, so the pill disappears
        if isCoolingDown {
            StatusFeed.shared.publish(.cooling)
        } else if isPaused && (developingCount > 0 || blockedCount > 0) {
            StatusFeed.shared.publish(.paused)
        } else if developingCount > 0 {
            StatusFeed.shared.publish(.developing(count: developingCount))
        } else if blockedCount > 0 {
            StatusFeed.shared.publish(.blocked(count: blockedCount))
        } else {
            StatusFeed.shared.clear(.darkRoom)
        }
    }

    /// Begin developing if not already, and mark that there is new work. Idempotent; cheap to
    /// over-call (after every enqueue, on every foreground activation, and when a model download
    /// finishes so blocked shots get another look).
    func kick() {
        suspended = false            // a foreground kick clears any background suspend
        refreshCounts()              // keep the counts honest even if we don't start below
        guard !isPaused else { return }
        dirty = true
        guard !running else { return }
        running = true
        loopTask = Task { await loop() }
    }

    /// Freeze the current settings around this photograph, put it in the durable queue, and wake
    /// the worker. **The one intake path:** the live shutter (`CameraView`) and the Dark Room's
    /// "load a picture" both call this, so a fed-in library image develops exactly like a pressed
    /// shot — same frozen config, same durability, same pipeline.
    /// - Parameter place: where the shot was taken. The live shutter passes the current GPS; a
    ///   picture imported from the library has no capture location, so it passes nil.
    func enqueue(_ photograph: CGImage, place: String?) async {
        let config = ShotConfig.capture()
        guard let photoData = ShotPhoto.encode(photograph) else {
            cameraLog("INTAKE: could not encode the frame — shot dropped")
            return
        }
        do {
            _ = try await DarkRoomStore.shared.enqueue(photoData: photoData, config: config, place: place)
        } catch {
            cameraLog("INTAKE: could not enqueue the shot — \(error.localizedDescription)")
            return
        }
        kick()
    }

    /// Stop pulling new shots (user paused the queue from the Dark Room). The shot already
    /// developing finishes; nothing new starts until `resume()`.
    func pause() { isPaused = true }

    /// Resume after a user pause, and immediately look for work.
    func resume() { isPaused = false; kick() }

    /// Prepare for the app going to the background: stop pulling new shots and wait for the shot in
    /// flight to reach a safe stop — its current operation finishes (inside iOS's grace window),
    /// then it abandons WITHOUT saving anything partial, leaving its durable record untouched. Only
    /// after this returns is it safe for the app to unload models, because no operation is using
    /// them any more. Foregrounding calls `kick()`, which clears the suspend and re-develops the
    /// abandoned shot whole from the start.
    func suspendForBackground() async {
        suspended = true
        await loopTask?.value
    }

    /// Recompute both counts from the store — reconciling blocked/pending against what's installed
    /// first — so the pill and the Dark Room stay honest even when the worker isn't running (the
    /// whole queue blocked, or the user just deleted a model), and so a shot enqueued mid-develop
    /// shows immediately rather than only when the current shot finishes. The store is the single
    /// source of truth.
    private func refreshCounts() {
        Task {
            let all = await DarkRoomStore.shared.pending()
            await reconcileBlocked(all)
            let after = await DarkRoomStore.shared.pending()
            developingCount = after.filter { $0.status == .pending }.count
            blockedCount = after.filter { $0.status == .blocked }.count
        }
    }

    /// Drain the queue: pull pending shots FIFO and develop them until empty, then — because a
    /// shot may have arrived while we were draining — re-drain as long as `dirty` was raised. Stop
    /// (leaving the shot on disk for the next kick) only if a save fails, so we never spin re-
    /// developing an unsaveable shot.
    private func loop() async {
        // Note: the counts are NOT reset here. The loop's last pass sets them to the true store
        // depth (0 developing when drained, but blockedCount stays > 0 if shots are held), so the
        // "N blocked" pill survives the loop exiting. Only the transient develop state is cleared.
        defer { running = false; isCoolingDown = false; currentShotID = nil; currentStage = nil }
        while dirty && !suspended && !isPaused {
            dirty = false
            while !suspended && !isPaused {
                // Reconcile against what's installed right now: block shots whose model is gone,
                // unblock ones whose model is back. Then develop the first that's ready.
                let all = await DarkRoomStore.shared.pending()
                await reconcileBlocked(all)
                let after = await DarkRoomStore.shared.pending()
                let ready = after.filter { $0.status == .pending }
                developingCount = ready.count
                blockedCount = after.filter { $0.status == .blocked }.count
                guard let shot = ready.first else { break }
                let saved = await develop(shot)
                // A failed save (e.g. Photos permission denied) will fail again immediately; stop
                // rather than burn the battery re-developing the same shot. Nothing is lost — it
                // stays on disk — and the next foreground kick retries. `develop` also returns false
                // when suspended mid-flight, which stops the loop cleanly for the same reason.
                guard saved else { return }
            }
        }
    }

    /// Re-evaluate every record against what's installed right now: a pending shot whose model is
    /// gone becomes `blocked` (carrying the name to re-download), and a blocked shot whose model is
    /// back becomes `pending`. Runs each drain pass and on every kick, so installing or deleting a
    /// model takes effect the next time the worker looks.
    private func reconcileBlocked(_ records: [ShotRecord]) async {
        for record in records {
            if let needs = Self.missingModel(for: record.config) {
                if record.status != .blocked || record.blockedModel != needs {
                    var r = record; r.status = .blocked; r.blockedModel = needs
                    try? await DarkRoomStore.shared.update(r)
                    cameraLog("DARKROOM: shot \(record.id) blocked — needs \(needs)")
                }
            } else if record.status == .blocked {
                var r = record; r.status = .pending; r.blockedModel = nil
                try? await DarkRoomStore.shared.update(r)
                cameraLog("DARKROOM: shot \(record.id) unblocked — model installed")
            }
        }
    }

    /// The display name of a model this shot needs but that isn't installed, or nil if everything
    /// it needs is present. The eye is always required; the drawer only when the shot draws frame 3.
    nonisolated static func missingModel(for config: ShotConfig) -> String? {
        let eye = ModelCatalog.model(for: config.seer)
        if !eye.isInstalled { return eye.displayName }
        if config.drawsThirdFrame, !ModelCatalog.sdTurbo.isInstalled { return ModelCatalog.sdTurbo.displayName }
        return nil
    }

    /// Develop one shot end to end. Returns whether it was saved (and thus removed from the queue),
    /// OR false to stop the loop — a genuine save failure, or a background suspend that abandons the
    /// shot mid-flight (record left untouched, redone whole on foreground).
    private func develop(_ shot: ShotRecord) async -> Bool {
        // Bail before touching anything heavy if the app has been backgrounded. The shot stays
        // pending on disk and re-develops whole on the next foreground kick.
        if suspended { return false }

        // Decode the saved reality frame. If the photo is gone or unreadable there is nothing to
        // develop and nothing to recover — drop the record so the loop can't spin on it forever.
        guard let data = await DarkRoomStore.shared.photoData(for: shot),
              let photograph = ShotPhoto.decode(data) else {
            cameraLog("DARKROOM: shot \(shot.id) has no readable photo — dropping")
            await DarkRoomStore.shared.remove(shot)
            return true   // "handled" — the queue moves on
        }

        let config = shot.config
        currentShotID = shot.id
        currentStage = nil

        // Observable cool-gate: hold here while the phone is too hot, so the toast can say "Cooling
        // down…" and the user knows the pause is deliberate (their shots are safe on disk). The
        // threshold is `ThermalGovernor`'s — one definition of "hot." `ModelLane.pace()` below is the
        // hard backstop; by the time this returns, the phone is cool and pace() is a no-op. A
        // background transition during the hold breaks out and abandons cleanly.
        // (`await` can't sit to the right of `&&`, so the suspend check is the while condition and
        // the thermal check is the first thing inside.)
        var announcedHold = false
        while !suspended {
            let hot = await ThermalGovernor.shared.isHotNow()
            if !hot { break }
            if !announcedHold {
                cameraLog("DARKROOM: holding shot \(shot.id) — phone too hot, cooling down")
                announcedHold = true
            }
            isCoolingDown = true
            try? await Task.sleep(nanoseconds: 2_000_000_000)   // re-check every 2 s
        }
        if announcedHold { cameraLog("DARKROOM: phone cooled — resuming develop") }
        isCoolingDown = false
        if suspended { currentShotID = nil; currentStage = nil; return false }

        // The heavy pipeline — see, tear the eye down, draw — through the ONE lane shared with the
        // antenna. Only Sendable values cross back; the cheap compositor + save stay out here. The
        // stage callback flips the row from "seeing" to "drawing" as the pipeline crosses frames.
        currentStage = .seeing
        let result: (perception: Perception, drawn: UIImage?, wordsForHand: String) =
            await ModelLane.shared.run("darkroom") { @MainActor in
                await Shot.seeThenDraw(photograph, config: config,
                                       onStage: { stage in self.currentStage = stage })
            }

        // Interrupted by a background transition while the heavy op ran? Abandon WITHOUT saving —
        // the record is untouched and still pending, so foregrounding redoes the whole shot. This
        // is why a suspended app never saves a half-finished develop.
        if suspended { currentShotID = nil; currentStage = nil; return false }

        // Which words frame 2 shows — the eye's full perception, or the (possibly condensed)
        // version the hand drew from. Same rule as the live shutter.
        currentStage = .saving
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
            currentShotID = nil; currentStage = nil
            return false
        }
        await DarkRoomStore.shared.remove(shot)
        arrivals += 1
        currentShotID = nil; currentStage = nil
        return true
    }
}

// ==== LEGO END: 35 The Dark Room Queue (Durable Developing) ====
