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
