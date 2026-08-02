//
//  ModelCatalog.swift
//  AI Camera
//
//  What the camera can load, and what it costs to load it.
//
//  ── Why this file exists ──
//
//  AI Camera had no catalog. Hal has one (`ModelCatalogService`, 1,662 lines) that fetches
//  a live list from HuggingFace and curates it; Posey has the same shape. AI Camera knows
//  about three models and will never know about many more — a camera has a lens fitted, not
//  a lens store — so this is a list, not a service. Small on purpose.
//
//  But its absence was not cosmetic. Hal hands its catalog's `sizeGB` to the downloader,
//  and the downloader's pre-flight **refuses outright when `sizeGB` is nil**:
//
//      "this model's size couldn't be determined from its repository"
//
//  The 2026-07-15 port dropped Hal's catalog line and replaced it with a display name and
//  nothing else. So nothing in AI Camera ever supplied a size, so the downloader would have
//  refused every call it was ever given. It compiled. Nobody saw it, because nothing called
//  it either: 1,968 lines of downloader were wired to a table-of-contents comment and a
//  background wake-up handler that could never fire, because no download could ever start.
//  Mark found it in ten seconds by opening Settings, which is the only check that was ever
//  going to find it.
//
//  ── The allowlist, which is the part that matters ──
//
//  `Delivery` is not decoration. The downloader takes **every** `.safetensors` in a repo —
//  correct for an LLM repo, which holds one model, and ruinous for a diffusion repo, which
//  holds the same weights at several precisions in parallel folders. Measured through
//  `GET /repo` on 2026-07-15:
//
//      stabilityai/sd-turbo    a 2.4 GB model whose .safetensors total  12.07 GB
//      SD 1.5                  a 2.0 GB model whose .safetensors total  22.01 GB
//
//  It downloads the model two or three times over — the fp32 UNet *and* its fp16 twin *and*
//  a single-file checkpoint the pipeline never opens. On a phone with 2.9 GB genuinely free
//  that is not a rounding error, it is the difference between working and not. So a
//  diffusion model names its files exactly. The pattern rule stays for LLM repos, where it
//  is right.
//

import Foundation
import Observation
import SharedModelStoreKit

// ==== LEGO START: 24 Model Catalog (What The Camera Can Load) ====

/// Which frame a model serves.
///
/// Mark's design, verbatim: *"there are three separate steps and each one should be
/// completely separate and offload models in between... frame one which is the capture,
/// there's frame two which is reading the image and writing the text, and frame three,
/// which is reading the text and drawing an image."* Frame 1 is the sensor and needs no
/// machine. These are the other two.
nonisolated enum ModelJob: String, Hashable, Sendable {
    case seeing   // frame 2 — a photograph in, words out
    case drawing  // frame 3 — words in, a photograph out

    var title: String {
        switch self {
        case .seeing:  return "The eye"
        case .drawing: return "The hand"
        }
    }
}

/// How a model gets onto the phone.
nonisolated enum ModelDelivery: Hashable, Sendable {
    /// Ships with iOS. Nothing to fetch, nothing to delete.
    case builtIn

    /// Every MLX-shaped file in the repo (`.safetensors`, `.json`, `.jinja`).
    /// Right for an LLM repo, which holds exactly one model.
    case wholeRepo

    /// Exactly these paths and nothing else.
    ///
    /// **Required for MLX diffusion repos.** See the file header for the measurements. A
    /// diffusion repo is a shelf, not a model — you must name what you're taking off it.
    case files([String])

    /// Every file under one repo subfolder (`prefix`), whatever its extension.
    ///
    /// **Required for a CoreML drawer.** Apple's CoreML diffusion repos carry the SAME model
    /// compiled several ways in parallel folders (`original/`, `split_einsum_v2/`), and each build
    /// is a tree of `.mlmodelc` bundles whose files are `.bin`/`.mil`/`weight`, not the
    /// `.safetensors` the MLX pattern rule matches and too many to name one by one the way `.files`
    /// does. So we take exactly one subtree — the Neural-Engine build — and all of it.
    case folder(String)
}

/// Which runtime draws a hand's frame 3.
///
/// Two engines, by design (Mark, 2026-07-26): the MLX stack the app shipped with, and CoreML on
/// the Neural Engine — measured on device at about a third of MLX's memory and cooler
/// (HISTORY 2026-07-26). An eye carries `.mlx` and never reads it; only a drawing model's engine
/// is consulted (`Shot.seeThenDraw` forks on it).
nonisolated enum DrawEngine: String, Hashable, Sendable {
    case mlx     // the vendored StableDiffusion-on-MLX path (sd-turbo)
    case coreML  // Apple's ml-stable-diffusion package, run on the Neural Engine
}

/// A drawer's step knob — the range the user's slider spans, and where it starts.
///
/// Per-drawer because the right number is a property of the model: a distilled turbo draws in a
/// handful of steps, a base SD model wants more. `nil` for an eye, which has no steps.
nonisolated struct DrawStepSpec: Hashable, Sendable {
    let range: ClosedRange<Int>
    let `default`: Int
}

/// One thing the camera can load.
nonisolated struct CameraModel: Identifiable, Hashable, Sendable {
    /// The HuggingFace repo id, and the id the store and downloader key on.
    /// `"apple"` for the built-in, which has no repo.
    let id: String
    let displayName: String
    let job: ModelJob
    let delivery: ModelDelivery

    /// What the download actually weighs — **the files we take, not the repo**. Measured
    /// from HuggingFace, not estimated. `nil` for the built-in.
    let sizeGB: Double?

    /// Said plainly, with the real trade-offs and no verdict. Which model is better is not
    /// ours to say (Principle 3).
    let blurb: String

    /// The licence, named. Principle 2 — real names for real things, and the user is
    /// entitled to know what they're being handed before they spend 2 GB on it.
    let licence: String?

    /// The model's **Layer 1** — the locked, non-user-editable framing line prepended to the
    /// user's Layer 2 (`Settings.systemPrompt`) every time this eye looks. Per-model so a
    /// chatty model can be told to be brief without weakening a well-behaved one (Hal's
    /// pattern; see `ModelConfiguration.layerOnePrompt`). It is never editable and can only be
    /// prepended, so an eye can't talk its way out of it. `nil` for a drawing model, which
    /// takes the eye's words and has no system prompt of its own. See `PromptLayers`.
    let layerOnePrompt: String?

    /// For a drawing model, which runtime draws it — the fork point in `Shot.seeThenDraw`.
    /// `.mlx` for an eye, where it is never read (an eye doesn't draw).
    let engine: DrawEngine

    /// For a drawing model, the step knob's range and default (see `DrawStepSpec`). `nil` for an
    /// eye. Read by the Preferences step slider and frozen per-shot in `ShotConfig.drawSteps`.
    let drawSteps: DrawStepSpec?

    /// Whether the weights are on the phone — the DISPLAY copy of the download state, refreshed
    /// centrally by `ModelCatalogService.refreshDownloadStates()` (Hal's pattern: the catalog holds
    /// each model's downloaded flag and every screen reads that one array, so a delete or download
    /// updates every dot at once instead of each view keeping its own idea and drifting). The
    /// built-in is always present. Seeds start `false` and are reconciled against disk at launch and
    /// on every store change. For a point-in-time check off the UI (a loader, the develop-time block
    /// reason), read `isInstalled`, which queries the store live by id. Copied from Hal's
    /// `ModelConfiguration.isDownloaded`.
    var isDownloaded: Bool = false

    /// The on-disk location once present, or `nil`. Set alongside `isDownloaded` by the service's
    /// refresh. Mirrors Hal's `ModelConfiguration.localPath`.
    var localPath: URL? = nil

    var isBuiltIn: Bool { delivery == .builtIn }

    /// The exact file list to fetch, or `nil` to fall back to the pattern rule.
    var fileAllowlist: [String]? {
        if case .files(let f) = delivery { return f }
        return nil
    }

    /// The subtree to take wholesale, for a `.folder` delivery (a CoreML drawer). `nil` otherwise.
    /// The download preserves repo-relative paths, so the model lands under this prefix inside its
    /// shared-store folder; `CoreMLDrawer` loads from `<modelDir>/<folderPrefix>`.
    var folderPrefix: String? {
        if case .folder(let p) = delivery { return p }
        return nil
    }

    /// The concrete file list to hand the downloader, resolving a `.folder` delivery against the
    /// live repo tree. `.files` returns its named paths; `.wholeRepo`/`.builtIn` return `nil` (the
    /// downloader's MLX pattern rule is right for those). A `.folder` model fetches the repo tree at
    /// its pinned revision and takes every file under the prefix — the many `.mlmodelc` internal
    /// files (`.bin`/`.mil`/`weight`) the pattern rule would drop.
    ///
    /// Resolved HERE, at the call site, on purpose: `MLXModelDownloader` is a verbatim copy of Hal's
    /// and copies flow one way (Hal → here), so it gets no new `.folder` parameter to drift on — it
    /// just receives a concrete `files:` list, the shape it already handles. Throws if the tree can't
    /// be read, so a folder download fails loudly here rather than silently fetching nothing.
    func downloadFileList() async throws -> [String]? {
        switch delivery {
        case .builtIn, .wholeRepo:
            return nil
        case .files(let f):
            return f
        case .folder(let prefix):
            let revision = SharedModelStore.revision(forRepoID: id)
            let all = try await HFTree.fileList(repoID: id, revision: revision)
            let matched = all.filter { $0.hasPrefix(prefix) }
            guard !matched.isEmpty else {
                throw NSError(domain: "ModelCatalog", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "\(id) has no files under \(prefix) — the repository layout may have changed."
                ])
            }
            return matched
        }
    }

    /// Whether the weights are on the phone right now.
    ///
    /// The built-in is always "installed" — it's part of the OS. Everything else is a
    /// question for the shared store, which is the only thing that actually knows.
    var isInstalled: Bool {
        if isBuiltIn { return true }
        return SharedModelStore.isRepoDownloaded(sharedStoreKey(forRepoID: id))
    }

    /// Real bytes on disk, once it's here. 0 if it isn't.
    var bytesOnDisk: Int64 {
        isBuiltIn ? 0 : SharedModelStore.sizeOnDisk(sharedStoreKey(forRepoID: id))
    }

    /// Which apps in the family are holding this model.
    ///
    /// Shown because it is the honest answer to "why didn't deleting this free any space,"
    /// and because Mark's rule for the store is a refcount: *"Deleting a model from an app
    /// does not delete it from the repository. Deleting it from the last remaining app to
    /// have it in use deletes it from the repository."*
    var claimants: [String] {
        isBuiltIn ? [] : SharedModelStore.claimants(modelID: sharedStoreKey(forRepoID: id))
    }
}

/// The shared-store key for a model: the version-stamped identity (`repo@<sha>`) for a stamped
/// model, or the plain repo id for a `plainFolderRepos` model (sd-turbo, the embedders) that a
/// library loads by plain name. The stamped-vs-plain decision now lives in the PACKAGE
/// (`SharedModelStore.plainFolderRepos`, honored by `requiredIdentity`), so this just forwards to
/// it, keeping every shared-store call in the app routed through one consistent key with no local
/// special-casing. See ADOPTION_SPEC.md.
nonisolated func sharedStoreKey(forRepoID repoID: String) -> String {
    SharedModelStore.requiredIdentity(forRepoID: repoID)
}

/// Launch-time sweep of superseded PLAIN copies (version-safety, no-orphans).
///
/// Before model identity carried a version, a curated model lived in its plain `repo`
/// folder. Now each curated (pinned, non-`plainFolderRepos`) model lives under its
/// version-stamped identity `repo@<sha>`, and the plain copy is never trusted. The
/// per-download / per-adopt reap removes a plain copy the moment its stamped replacement
/// lands — but a model the user never re-triggers would keep its stale plain copy forever.
/// This closes that gap: for every pinned non-plain repo with a plain copy still on disk,
/// drop THIS app's claim on the bare id and, once no app in the family still claims it,
/// delete the folder.
///
/// Why this must run in EVERY app, not just Hal: the store deletes a shared copy only when
/// the LAST claimant releases it. On a device with more than one of the family apps
/// installed, an old shared plain copy survives until each app that still claims it has
/// swept — so the no-orphans guarantee is only real when all three sweep. Idempotent (a
/// swept model leaves nothing to find next launch); a true no-op on a device that never had
/// a pre-version copy. `plainFolderRepos` (sd-turbo, the embedders) are skipped: their
/// required identity IS the bare id, so their plain folder is the real copy.
nonisolated func sweepSupersededPlainCopies() {
    let fm = FileManager.default
    for repoID in SharedModelStore.pinnedRevisions.keys {
        // Only stamped repos have a superseded plain form; this guard skips plainFolderRepos.
        guard SharedModelStore.requiredIdentity(forRepoID: repoID) != repoID else { continue }
        guard SharedModelStore.isRepoDownloaded(repoID) else { continue }
        // Drop our claim on the bare id; the store deletes files only when no app in the
        // family still claims it. Re-check presence before removing (a concurrent reap on
        // the same launch may have taken it already).
        let safeToDelete = SharedModelStore.releaseClaim(modelID: repoID)
        guard safeToDelete, SharedModelStore.isRepoDownloaded(repoID) else {
            cameraLog("HALDEBUG-SWEEP: kept plain copy of \(repoID) — another app still claims it")
            continue
        }
        do {
            try fm.removeItem(at: SharedModelStore.mlxModelDir(repoID))
            cameraLog("HALDEBUG-SWEEP: reaped superseded plain copy of \(repoID) (now version-stamped)")
        } catch {
            cameraLog("HALDEBUG-SWEEP: failed to reap plain \(repoID): \(error.localizedDescription)")
        }
    }
}

/// `nonisolated` because the catalog is plain data and its readers are not on the main
/// actor — `DrawerLoader` and `MLXEyeLoader` are actors that load weights off-main by design,
/// and the project's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` would otherwise strand a
/// list of constants on the main thread.
nonisolated enum ModelCatalog {

    /// The kit lens. Free, onboard, guarded, zero download.
    static let apple = CameraModel(
        id: "apple",
        displayName: "Apple Intelligence",
        job: .seeing,
        delivery: .builtIn,
        sizeGB: nil,
        blurb: "On the phone already - nothing to download. A filter stops some images before the model sees them; when that happens the camera asks again with the filter relaxed, and records both answers.",
        licence: nil,
        // The shared gentle brevity line — the one it uses today. Behaves well within it.
        layerOnePrompt: PromptLayers.brevity,
        engine: .mlx,        // unused for an eye
        drawSteps: nil
    )

    /// The fast prime. Downloaded, richer, unguarded.
    static let qwen = CameraModel(
        id: Qwen.repo,
        displayName: "Qwen3.5-2B",
        job: .seeing,
        // An LLM repo: one model, so every MLX file in it IS the model.
        delivery: .wholeRepo,
        sizeGB: 1.63,
        blurb: "Sees differently from Apple's model, and largely ignores instructions about how to speak. First look after launch takes about 9 seconds while it loads; after that about 3.",
        licence: "Apache 2.0",
        // The same shared gentle line Apple uses — Qwen keeps to it well enough. Explicit here
        // (not a hidden fallback) so every eye's record states its own Layer 1 plainly.
        layerOnePrompt: PromptLayers.brevity,
        engine: .mlx,        // unused for an eye
        drawSteps: nil
    )

    /// The small eye. A second downloadable eye, and the proof that the eye loader really is
    /// generic: it was added as this one entry, nothing else (the `MLXEyeLoader`, the `Seer`
    /// enum, the library, the download, the licence gate, and the privacy lock were already
    /// model-agnostic after the 2026-07-21 generalization).
    ///
    /// Verified before it was added, in the source and at the exact pinned commit, not from
    /// memory: `smolvlm` is in MLXVLM's registry (mlx-swift-lm 3.31.4:
    /// `create(SmolVLM2Configuration.self, SmolVLM2.init)`); the repo below is the one the
    /// shared package pins (`SmolVLM2-500M-Video-Instruct-mlx` @ `fa57db46…`); and its
    /// `config.json` at that commit is `model_type: smolvlm`, so it loads on that path. It's an
    /// LLM/VLM-shaped repo — one model — so every MLX file in it IS the model (`.wholeRepo`).
    /// 1.02 GB measured from HuggingFace (the `.safetensors` + tokenizer), not estimated.
    ///
    /// No `VisionRecipe` case: it falls through to the conservative default (top_p/top_k
    /// filtering ON) on purpose, until we've watched it on the device and learned its own.
    static let smolVLM2 = CameraModel(
        id: "mlx-community/SmolVLM2-500M-Video-Instruct-mlx",
        displayName: "SmolVLM2-500M",
        job: .seeing,
        // A VLM repo: one model, so every MLX file in it IS the model.
        delivery: .wholeRepo,
        sizeGB: 1.02,
        blurb: "The smallest eye, roughly 500 million parameters against Qwen's two billion. A different lineage of model, and like Qwen it has no content filter, so it says what it sees whatever you point it at. Being small, it takes up the least room and the least memory.",
        licence: "Apache 2.0",
        // Smol's OWN, stricter Layer 1 — it ignores the gentle line and writes essays (an
        // "### Analysis" section, hundreds of words), which overran the frame. This forbids the
        // exact behaviors it reached for. No bluff, no truncation threat, no assumption it knows
        // it feeds a drawing — just a firm, honest instruction. Tuned on device 2026-07-26.
        layerOnePrompt: "Describe what you see in no more than two or three sentences. Do not explain, analyze, list, or add commentary. Give only the description, then stop.",
        engine: .mlx,        // unused for an eye
        drawSteps: nil
    )

    /// The hand — frame 3.
    ///
    /// **Why sd-turbo and not the model NEXT.md names.** NEXT.md's test design is built on
    /// Stable Diffusion 2.1 base, on the grounds that it is the one model that runs on both
    /// engines. **That repo no longer exists.** `stabilityai/stable-diffusion-2-1-base`
    /// returns 401 — verified 2026-07-15 from two machines on two networks, and confirmed
    /// as withdrawal rather than gating three ways: a known-*gated* repo
    /// (`black-forest-labs/FLUX.1-dev`) answers 200 with `"private": false`; the
    /// `stabilityai` org listing has no `stable-diffusion-2-*` repos left at all; and the
    /// same 401 comes back from the phone. Stability withdrew the 2.x line. The MLX
    /// library's `presetStableDiffusion21Base` is now a preset pointing at a dead repo.
    ///
    /// sd-turbo is the closest live thing, and closer than a substitute usually gets: it is
    /// distilled **from** SD 2.1, so it has 2.1's architecture and lands on the library's
    /// existing `StableDiffusionBase` path rather than asking SD 1.5's text encoder to fit
    /// a shape it doesn't have. It draws in 1–4 steps instead of 50.
    ///
    /// The file list is the fp16 twins, named exactly. 2.40 GB measured, against 12.07 GB
    /// if the pattern rule were let anywhere near this repo.
    static let sdTurbo = CameraModel(
        id: "stabilityai/sd-turbo",
        displayName: "SD-Turbo (MLX)",
        job: .drawing,
        delivery: .files([
            "unet/config.json",
            "unet/diffusion_pytorch_model.fp16.safetensors",
            "text_encoder/config.json",
            "text_encoder/model.fp16.safetensors",
            "vae/config.json",
            "vae/diffusion_pytorch_model.fp16.safetensors",
            "scheduler/scheduler_config.json",
            "tokenizer/vocab.json",
            "tokenizer/merges.txt",
        ]),
        sizeGB: 2.40,
        blurb: "Draws the third frame - the machine's re-imagining, made from its own words. Never sees your photograph; it only reads what the eye said about it.",
        licence: "Stability AI Community License - free under $1M revenue",
        // A drawing model has no Layer 1: it takes the eye's words, not a system prompt.
        layerOnePrompt: nil,
        engine: .mlx,
        // Distilled to draw in very few steps and stays coherent to about 6; default 4 (its
        // trained sweet spot). The knob lets a user trade a touch more time for a touch more detail
        // without leaving turbo's comfortable range.
        drawSteps: DrawStepSpec(range: 1...6, default: 4)
    )

    /// The second hand — CoreML on the Neural Engine.
    ///
    /// Proven on device 2026-07-26 (HISTORY, the CoreML spike): SD-2.1-base **palettized**,
    /// `split_einsum_v2` (Neural-Engine) build, run through Apple's `ml-stable-diffusion` package
    /// with `.cpuAndNeuralEngine`. Peak ~800 MB against the MLX hand's ~2,700 (about a third), ~11 s
    /// a shot once warm, with a one-time ~190 s Neural-Engine compile on first use. Clean images.
    ///
    /// Delivery is `.folder`, not `.files`: the repo carries the model compiled several ways in
    /// parallel folders and each build is a tree of `.mlmodelc` bundles — too many internal files to
    /// name — so we take exactly the Neural-Engine subtree and all of it. 1.14 GB (22 files) measured
    /// from HuggingFace 2026-07-26, not estimated.
    ///
    /// **Licence: CreativeML OpenRAIL++-M** — Apple's re-publish of Stability's SD-2.1 (`openrail++`
    /// on the model card, verified 2026-07-26). A use-based licence, NOT the sd-turbo Community
    /// Licence; it gets its own line in About. Pinned to `dca5f2f…` and registered at launch by THIS
    /// app alone (`AI_CameraApp.init` → `SharedModelStore.registerPinnedRevisions`), because only the
    /// camera uses this drawer. Not a `plainFolderRepos` model: we control the load path, so it uses
    /// the normal version-stamped identity like Qwen (`repo@<sha>`), which is the version-safe default.
    static let coreMLSD21 = CameraModel(
        id: "apple/coreml-stable-diffusion-2-1-base-palettized",
        displayName: "SD-2.1 (Core ML)",
        job: .drawing,
        delivery: .folder("split_einsum_v2/compiled/"),
        sizeGB: 1.14,
        blurb: "Draws the third frame on the Neural Engine - Apple's chip for machine-learning work. Uses about a third of the memory the other hand does and runs cooler, at the cost of a one-time warm-up the first time you use it after installing.",
        licence: "CreativeML OpenRAIL++-M",
        // A drawing model has no Layer 1: it takes the eye's words, not a system prompt.
        layerOnePrompt: nil,
        engine: .coreML,
        // A base (non-turbo) SD model needs real denoising steps; 20 is a good default, 15–30 the
        // useful range. Fewer is faster and rougher, more is slower and cleaner.
        drawSteps: DrawStepSpec(range: 15...30, default: 20)
    )

    static let all: [CameraModel] = [apple, qwen, smolVLM2, sdTurbo, coreMLSD21]

    static func models(for job: ModelJob) -> [CameraModel] {
        all.filter { $0.job == job }
    }

    /// Look a model up by the id the store and downloader key on.
    static func model(id: String) -> CameraModel? {
        all.first { $0.id == id }
    }

    /// The model backing a given eye, so Preferences and the library agree about what is
    /// loaded rather than each keeping its own idea. An `.mlx` eye whose repo isn't in the
    /// catalog falls back to the built-in for display — it can't be selected without a
    /// catalog entry anyway.
    static func model(for seer: Seer) -> CameraModel {
        switch seer {
        case .apple:       return apple
        case .mlx(let id): return model(id: id) ?? apple
        }
    }
}

/// The catalog's own tiny reader for a HuggingFace repo file tree — used by a `.folder` model to
/// resolve its subtree to concrete paths (`CameraModel.downloadFileList`).
///
/// Deliberately separate from `BackgroundDownloadCoordinator.fetchRepoFileList`, which is private
/// and part of the verbatim Hal copy: duplicating fifteen lines here is the price of NOT adding a
/// parameter to a file that must stay a clean copy. Reads at the same pinned revision the download
/// will fetch, so the list matches the bytes.
nonisolated enum HFTree {
    static func fileList(repoID: String, revision: String) async throws -> [String] {
        guard let url = URL(string: "https://huggingface.co/api/models/\(repoID)/tree/\(revision)?recursive=1") else {
            throw NSError(domain: "HFTree", code: 2, userInfo: [NSLocalizedDescriptionKey: "Bad repo id: \(repoID)"])
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "HFTree", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "HF tree API returned \(status) for \(repoID)"])
        }
        struct Entry: Decodable { let type: String; let path: String }
        return try JSONDecoder().decode([Entry].self, from: data)
            .filter { $0.type == "file" }.map { $0.path }
    }
}

/// The live model catalog — Hal's `ModelCatalogService`, brought into Thomas so both apps share the
/// same battle-tested shape instead of each keeping its own. This is the fix for the stale "active"
/// dot: Preferences and the Library now read ONE centrally-refreshed source, so a delete or a
/// download updates every dot at once and none can lie. Hal's dots have never gone stale because of
/// exactly this.
///
/// Hal keeps `@Published availableModels: [ModelConfiguration]` and calls `refreshDownloadStates()`
/// after any download / delete / switch; every view observes that one array. Thomas's version is the
/// same shape, in the Observation-framework idiom Thomas already uses (`@Observable`), carrying
/// Thomas's richer `CameraModel` (which has eye/hand roles Hal's text-only `ModelConfiguration` does
/// not) instead of porting Hal's LLM-only fields (context window, KV-cache, reasoning tokens).
///
/// Increment 1 (2026-08-01, branch `hal-model-system`): the curated catalog + honest, centrally
/// refreshed download state. The live HuggingFace "download any model" browser is increment 2 —
/// Hal's `fetchMLXCommunityModels`, made role-aware (eyes are VLMs, hands are diffusion models).
@MainActor
@Observable
final class ModelCatalogService {
    static let shared = ModelCatalogService()

    /// The one array every screen reads. Seeded from the curated `ModelCatalog.all` so the Library
    /// shows something at launch with no network; each model's `isDownloaded`/`localPath` is then
    /// reconciled against the shared store by `refreshDownloadStates()`. Increment 2 appends the
    /// live-fetched community models here.
    private(set) var availableModels: [CameraModel] = ModelCatalog.all

    private init() {
        // Reconcile the seed against disk before anyone reads `availableModels` — without this the
        // catalog would report every downloadable model as absent until the first manual refresh,
        // exactly the launch-time lie Hal's own init comment calls out.
        refreshDownloadStates()
        // A finished background download lands weights on disk and posts `.mlxModelDidDownload`;
        // refresh so whichever screen is showing updates, not only the one that started the download.
        // Delete and clear post no notification — their call sites call `refresh()` directly. This is
        // Hal's app-level model-state observer, the reason Hal's dots stay honest across screens.
        NotificationCenter.default.addObserver(
            forName: .mlxModelDidDownload, object: nil, queue: nil
        ) { _ in
            Task { @MainActor in
                ModelCatalogService.shared.refreshDownloadStates()
                // A just-landed model may unblock queued shots that were waiting for it, so nudge the
                // dark room here too. This is APP-LEVEL, so it fires no matter which screen is showing.
                // Before, the only worker kick on a completed download lived in `ModelLibraryView`
                // (onReceive/onDisappear) plus the app `.active` foreground, so a download that finished
                // while the user was on the capture screen left blocked shots blocked until the next
                // foreground (device-found 2026-08-01: an antenna download from the capture screen did
                // not auto-unblock). `kick()` is idempotent, so the library's own kick still standing is
                // harmless.
                DarkRoomWorker.shared.kick()
            }
        }
        cameraLog("CATALOG: ModelCatalogService initialized with \(availableModels.count) models; refreshed download states from disk.")
    }

    /// Recompute every model's on-disk state from the shared store, in ONE place. This is the whole
    /// point: display state is derived here and nowhere else, so it cannot drift between screens.
    /// Copied from Hal's `refreshDownloadStates()`; reads Thomas's `SharedModelStore` (same package
    /// Hal's downloader reads).
    func refreshDownloadStates() {
        availableModels = availableModels.map { model in
            var m = model
            if model.isBuiltIn {
                m.isDownloaded = true
                m.localPath = nil            // system-provided; no on-disk path to show
                return m
            }
            let key = sharedStoreKey(forRepoID: model.id)
            m.isDownloaded = SharedModelStore.isRepoDownloaded(key)
            m.localPath = m.isDownloaded ? SharedModelStore.mlxModelDir(key) : nil
            return m
        }
    }

    /// Call right after any delete or clear the app itself performs. (A download completion arrives
    /// via the notification above; a delete/clear posts nothing, so its call site pokes this.) Same
    /// body as `refreshDownloadStates`; named for the call site's intent, mirroring how Hal calls
    /// `refreshDownloadStates()` straight after `deleteModel`.
    func refresh() { refreshDownloadStates() }

    /// The refreshed models for one role — what the Library's eye/hand sections and Preferences read,
    /// so their dots reflect the one source of truth.
    func models(for job: ModelJob) -> [CameraModel] {
        availableModels.filter { $0.job == job }
    }

    /// A refreshed model by the id the store and downloader key on. Prefer this over
    /// `ModelCatalog.model(id:)` anywhere the download state is shown: the static catalog carries
    /// definitions, this carries live, observed state.
    func model(id: String) -> CameraModel? {
        availableModels.first { $0.id == id }
    }

    /// The refreshed model backing a given eye — state-aware twin of `ModelCatalog.model(for:)`.
    func model(for seer: Seer) -> CameraModel {
        switch seer {
        case .apple:       return model(id: ModelCatalog.apple.id) ?? ModelCatalog.apple
        case .mlx(let id): return model(id: id) ?? ModelCatalog.apple
        }
    }
}

// ==== LEGO END: 24 Model Catalog (What The Camera Can Load) ====
