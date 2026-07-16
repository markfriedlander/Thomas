// SharedModelStore.swift
// AI Camera
//
// AI Camera's half of the cross-app model-sharing contract, and the third seat at
// a table Mark built for exactly this. A deliberate near-verbatim port of Hal's
// `SharedModelStore.swift` — which is itself a near-verbatim port of Posey's.
//
// ⚠️ THE THREE APPS MUST AGREE. Same App Group id, same on-disk layout, same
// `manifest.json` format. Drift in any one of them and sharing doesn't error — it
// silently stops working, or worse, one app's delete pulls the files out from under
// another. If you change something here, it changes in Hal and Posey too.
//
// The shared container:
//   <AppGroup>/Models/huggingface/models/<repoID>/   <- MLX models
//   <AppGroup>/Models/manifest.json                  <- co-ownership refcount
//
// The `Models/` subfolder is Posey's namespacing and is part of the contract — look
// one folder too high and you see nothing.
//
// Ownership: each app records a claim (its bundle id) on every model it uses. Deleting
// in one app releases only that app's claim; files go only when NO app still claims the
// model. All manifest access is wrapped in NSFileCoordinator so three apps can read and
// write it concurrently without corruption.
//
// NOT ported (yet): Hal's cross-app download lock. It exists so two apps don't fetch the
// same multi-GB repo simultaneously. AI Camera doesn't download anything — it adopts
// what Hal and Posey already fetched. Port it the day this app grows a downloader; until
// then it would be code that does nothing, which is worse than no code.

import Foundation

// ==== LEGO START: 15 Shared Model Store (App-Group Paths) ====

/// The on-device store for downloadable models, in the App Group container shared
/// with Hal and Posey.
enum SharedModelStore {

    /// The shared App Group identifier. Must match Hal's and Posey's exactly.
    nonisolated static let appGroupID = "group.com.MarkFriedlander.aifamily"

    /// This app's stable identity for ownership claims in the manifest.
    nonisolated static var thisAppID: String { Bundle.main.bundleIdentifier ?? "com.MarkFriedlander.AI-Camera" }

    /// Container root for shared models, under a `Models/` subfolder (Posey's
    /// namespacing — part of the contract). **Fallback:** if the container is
    /// unavailable (entitlement missing, a Simulator without the group, a misconfigured
    /// build) we degrade to per-app Caches rather than crash. The camera keeps working;
    /// it just can't see the family's models.
    nonisolated static var root: URL {
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return container.appendingPathComponent("Models", isDirectory: true)
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    /// True when we're actually in the shared container rather than the fallback. The
    /// difference is invisible on disk and very visible in behaviour, so the antenna
    /// reports it rather than letting us guess.
    nonisolated static var isSharing: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) != nil
    }

    /// The HuggingFace-style cache root inside the store. Both `HubApi(downloadBase:)`
    /// and the MLX model dirs (`huggingface/models/<id>`) live under here.
    nonisolated static var huggingFaceRoot: URL {
        root.appendingPathComponent("huggingface", isDirectory: true)
    }

    /// Directory for one MLX model id. Matches the legacy Caches layout
    /// (`huggingface/models/<modelID>`) so detection/load/delete are unchanged apart
    /// from the root.
    nonisolated static func mlxModelDir(_ modelID: String) -> URL {
        huggingFaceRoot
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(modelID, isDirectory: true)
    }

    /// "Is this HuggingFace repo present on disk?" — a non-empty repo directory.
    /// Truth-on-disk, independent of HOW it got there (Hal's downloader, Posey's copy,
    /// or ours). Mid-download a partial dir reads as present, so callers that care also
    /// check the downloader's in-flight state. AI Camera has no downloader, so anything
    /// we see here was put there by a sibling and is finished.
    nonisolated static func isRepoDownloaded(_ repo: String) -> Bool {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: mlxModelDir(repo).path)) ?? []
        return !contents.isEmpty
    }

    /// Every model repo sitting in the shared store, whoever downloaded it.
    /// A repo id is `org/name`, so this walks two levels.
    nonisolated static func installedRepos() -> [String] {
        let base = huggingFaceRoot.appendingPathComponent("models", isDirectory: true)
        let fm = FileManager.default
        guard let orgs = try? fm.contentsOfDirectory(atPath: base.path) else { return [] }
        var found: [String] = []
        for org in orgs where !org.hasPrefix(".") {
            let orgDir = base.appendingPathComponent(org, isDirectory: true)
            guard let names = try? fm.contentsOfDirectory(atPath: orgDir.path) else { continue }
            for name in names where !name.hasPrefix(".") {
                let repo = "\(org)/\(name)"
                if isRepoDownloaded(repo) { found.append(repo) }
            }
        }
        return found.sorted()
    }

    /// Size on disk of one repo, in bytes.
    nonisolated static func sizeOnDisk(_ repo: String) -> Int64 {
        let dir = mlxModelDir(repo)
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// Exclude a model directory from iCloud backup. MANDATORY for App Group containers:
    /// unlike `Library/Caches` (auto-excluded), the shared container IS backed up by
    /// default, so without this every user would burn multiple GB of iCloud quota on
    /// re-downloadable model weights (App Review 2.5.1). Idempotent.
    nonisolated static func excludeFromBackup(_ modelID: String) {
        var dir = mlxModelDir(modelID)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
    }
}

// ==== LEGO END: 15 Shared Model Store (App-Group Paths) ====

// ==== LEGO START: 16 Shared Model Store (Refcount Manifest) ====

extension SharedModelStore {

    /// `manifest.json` at the store root tracks which apps in the family claim each
    /// model, so deleting from one app only removes files when **no** app still claims
    /// them. Format is identical to Hal's and Posey's — all three read/write this file.
    nonisolated private static var manifestURL: URL { root.appendingPathComponent("manifest.json") }

    nonisolated private struct Manifest: Codable {
        var version: Int = 1
        var models: [String: Entry] = [:]
        nonisolated struct Entry: Codable {
            var claimedBy: [String] = []   // bundle ids
            var repo: String?              // hf repo id (recorded for cross-app match)
            var sizeBytes: Int64?
        }
    }

    /// Record that THIS app uses `modelID`.
    ///
    /// For AI Camera this is the **adoption** path specifically: we never download, so
    /// every model we use was fetched by Hal or Posey. Claiming it means their delete
    /// can't pull the weights out from under our camera. Idempotent.
    nonisolated static func claim(modelID: String, repo: String? = nil, sizeBytes: Int64? = nil) {
        mutateManifest { m in
            var e = m.models[modelID] ?? Manifest.Entry()
            if !e.claimedBy.contains(thisAppID) { e.claimedBy.append(thisAppID) }
            if let repo { e.repo = repo }
            if let sizeBytes { e.sizeBytes = sizeBytes }
            m.models[modelID] = e
        }
    }

    /// Release THIS app's claim on `modelID`. Returns `true` iff NO app claims it
    /// anymore — i.e. it is now safe to delete the files. Callers remove files ONLY on
    /// `true`, so releasing a model Hal still uses leaves Hal's copy intact.
    @discardableResult
    nonisolated static func releaseClaim(modelID: String) -> Bool {
        var safeToDelete = false
        mutateManifest { m in
            guard var e = m.models[modelID] else { safeToDelete = true; return }
            e.claimedBy.removeAll { $0 == thisAppID }
            if e.claimedBy.isEmpty {
                m.models.removeValue(forKey: modelID)
                safeToDelete = true
            } else {
                m.models[modelID] = e
            }
        }
        return safeToDelete
    }

    /// Read-only: which apps currently claim `modelID`. Diagnostics only — the antenna
    /// reports the ledger so we can see the family's shared state without mutating it.
    nonisolated static func claimants(modelID: String) -> [String] {
        readManifest(NSFileCoordinator()).models[modelID]?.claimedBy ?? []
    }

    /// Read-only: every model id THIS app currently claims. The inverse of `claimants` —
    /// that answers "who owns this model," this answers "what do I own."
    ///
    /// **The manifest is the authority here, never the disk.** Lifted verbatim in spirit
    /// from Hal, along with the reason, which is subtle enough to be worth restating: a
    /// model can sit in the shared container without this app claiming it (a sibling
    /// downloaded it and we haven't adopted it). Those files are not ours to release or
    /// delete. Enumerating from disk would sweep them up — and because `releaseClaim`
    /// returns `true` for a model with **no manifest entry at all**, an unclaimed model
    /// would come back "safe to delete" and be destroyed. Ask the ledger what we own;
    /// don't infer it from what we can see.
    ///
    /// (History: AI Camera's CC suggested Hal fix `clearHubCache` by iterating
    /// `installedRepos()` — the disk path. Hal's CC caught that it would reintroduce a
    /// quieter version of the same data-loss bug and used the manifest instead. This
    /// function is theirs, and the comment is why it exists rather than the obvious one.)
    nonisolated static func modelsClaimedByThisApp() -> [String] {
        readManifest(NSFileCoordinator()).models
            .filter { $0.value.claimedBy.contains(thisAppID) }
            .map(\.key)
            .sorted()
    }

    /// A human name for a family app's bundle id, for UI that explains co-ownership
    /// ("also used by Posey") or who is mid-download.
    ///
    /// **Derived, not a lookup table — deliberately, and this app is the proof.** Every
    /// app in the family is `com.MarkFriedlander.<AppName>`, so the last component is the
    /// name. Hal still carries an older hardcoded `appDisplayName` that lists only Posey
    /// and Hal; a new tenant falls through it to `return id` and shows the user a raw
    /// bundle identifier. **AI Camera is that new tenant, and would be the first to
    /// display it.** Hal's own CC wrote this derived version today and left the table in
    /// place; filed in Hal's NEXT.md. We take only this one.
    nonisolated static func displayName(forAppID appID: String) -> String {
        guard let last = appID.split(separator: ".").last, !last.isEmpty else {
            return "another app"
        }
        return last.replacingOccurrences(of: "-", with: " ")
    }

    /// Optional-accepting overload.
    ///
    /// Hal's older `appDisplayName(_ bundleID: String?)` took an optional and mapped `nil`
    /// to "another app"; the downloader's lock-holder call sites rely on that, because a
    /// lock can be read as free. Rather than force-unwrap at three call sites to satisfy
    /// the derived version — which would crash on exactly the case Hal handled on purpose —
    /// the nil branch keeps Hal's answer and the rest derives.
    nonisolated static func displayName(forAppID appID: String?) -> String {
        guard let appID else { return "another app" }
        return displayName(forAppID: appID)
    }

    // MARK: coordinated read / write

    nonisolated private static func readManifest(_ coordinator: NSFileCoordinator) -> Manifest {
        var result = Manifest()
        var coordError: NSError?
        coordinator.coordinate(readingItemAt: manifestURL, options: [], error: &coordError) { url in
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode(Manifest.self, from: data) else { return }
            result = decoded
        }
        return result
    }

    nonisolated private static func mutateManifest(_ body: (inout Manifest) -> Void) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let coordinator = NSFileCoordinator()
        // Read-then-write under a single write coordination so two apps can't interleave
        // a lost update.
        var coordError: NSError?
        coordinator.coordinate(writingItemAt: manifestURL, options: [], error: &coordError) { url in
            var manifest = Manifest()
            if let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode(Manifest.self, from: data) {
                manifest = decoded
            }
            body(&manifest)
            if let out = try? JSONEncoder().encode(manifest) {
                try? out.write(to: url, options: .atomic)
            }
        }
    }
}

// ==== LEGO END: 16 Shared Model Store (Refcount Manifest) ====

// ==== LEGO START: 17 Shared Model Store (Cross-App Download Lock) ====

// Lifted from Hal's `SharedModelStore` (block 44) on 2026-07-15. AI Camera never had this
// because AI Camera never downloaded — it adopted whatever Hal and Posey had already
// fetched. That changes with the downloader, and Mark's question is the reason:
// *"what happens if somebody downloads the camera app and doesn't have Hal or Posey."*
//
// Once this app can download, two apps in the family can want the same multi-GB repo at
// the same moment, and without a lock they write into the same directory concurrently.
// Nobody has hit this yet because nobody has been sharing yet — Hal is the only released
// app. That is exactly the window in which to get it right.
//
// ⚠️ Note what this protects and what it doesn't. The lock is **advisory** — it prevents a
// duplicate *download*, not a filesystem race. Hal's framing, kept: the worst case without
// it is one redundant download, never a corrupt file. So the staleness window is generous
// rather than paranoid.
//
// Posey has NO lock at all (filed in Posey's next.md today). Its copy of the store predates
// this section.

extension SharedModelStore {

    /// A lock older than this, with no refresh, is treated as abandoned. Hal's figure: long
    /// enough that a slow-but-live background download isn't stolen, short enough that a
    /// genuine crash frees the slot in a tolerable time.
    nonisolated static let downloadLockStaleSeconds: TimeInterval = 600

    nonisolated private static var downloadLocksURL: URL {
        root.appendingPathComponent("download-locks.json")
    }

    nonisolated private struct DownloadLocks: Codable {
        var version: Int = 1
        var locks: [String: Lock] = [:]
        nonisolated struct Lock: Codable {
            var holder: String   // bundle id of the app currently downloading
            var since: Double    // epoch seconds; refreshed by the live holder
        }
    }

    /// Current lock record for `modelID`, or nil if the slot is free.
    ///
    /// Read-only and **does not consider staleness** — callers needing the take-over
    /// decision use `acquireDownloadLock`, which does. This is for showing a human "Hal is
    /// downloading this."
    nonisolated static func downloadLock(modelID: String) -> (holder: String, since: Double)? {
        guard let l = readDownloadLocks(NSFileCoordinator()).locks[modelID] else { return nil }
        return (l.holder, l.since)
    }

    /// Try to claim the download slot for `modelID`.
    ///
    /// Atomic test-and-set under a **single write coordination** — that's what makes it a
    /// lock rather than a suggestion; a read-then-write in two coordinations would let two
    /// apps both see "free" and both proceed. Granted if the slot is free, already ours, or
    /// stale (holder presumed dead). Returns `false` only when another app holds a fresh
    /// lock, in which case the caller should wait and adopt rather than download a second
    /// copy on top of the first.
    nonisolated static func acquireDownloadLock(modelID: String) -> Bool {
        var granted = false
        mutateDownloadLocks { db in
            if let l = db.locks[modelID],
               l.holder != thisAppID,
               (nowEpoch() - l.since) < downloadLockStaleSeconds {
                granted = false          // someone else holds a fresh lock
                return
            }
            db.locks[modelID] = DownloadLocks.Lock(holder: thisAppID, since: nowEpoch())
            granted = true
        }
        return granted
    }

    /// Bump our lock's timestamp so a live download isn't judged stale and stolen. No-op if
    /// we don't hold it. Called from the progress path.
    nonisolated static func refreshDownloadLock(modelID: String) {
        mutateDownloadLocks { db in
            guard var l = db.locks[modelID], l.holder == thisAppID else { return }
            l.since = nowEpoch()
            db.locks[modelID] = l
        }
    }

    /// Release our lock (no-op if we don't hold it). Called on completion — next to the
    /// claim — and on cancel and failure. Every exit from a download passes through here.
    nonisolated static func releaseDownloadLock(modelID: String) {
        mutateDownloadLocks { db in
            if db.locks[modelID]?.holder == thisAppID {
                db.locks.removeValue(forKey: modelID)
            }
        }
    }

    nonisolated private static func nowEpoch() -> Double { Date().timeIntervalSince1970 }

    // MARK: coordinated read / write (mirrors the manifest's discipline)

    nonisolated private static func readDownloadLocks(_ coordinator: NSFileCoordinator) -> DownloadLocks {
        var result = DownloadLocks()
        var coordError: NSError?
        coordinator.coordinate(readingItemAt: downloadLocksURL, options: [], error: &coordError) { url in
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode(DownloadLocks.self, from: data) else { return }
            result = decoded
        }
        return result
    }

    nonisolated private static func mutateDownloadLocks(_ body: (inout DownloadLocks) -> Void) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        coordinator.coordinate(writingItemAt: downloadLocksURL, options: [], error: &coordError) { url in
            var db = DownloadLocks()
            if let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode(DownloadLocks.self, from: data) {
                db = decoded
            }
            body(&db)
            if let out = try? JSONEncoder().encode(db) {
                try? out.write(to: url, options: .atomic)
            }
        }
    }
}

// ==== LEGO END: 17 Shared Model Store (Cross-App Download Lock) ====
