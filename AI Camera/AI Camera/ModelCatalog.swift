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

// ==== LEGO START: 27 Model Catalog (What The Camera Can Load) ====

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
    /// **Required for diffusion repos.** See the file header for the measurements. A
    /// diffusion repo is a shelf, not a model — you must name what you're taking off it.
    case files([String])
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

    var isBuiltIn: Bool { delivery == .builtIn }

    /// The exact file list to fetch, or `nil` to fall back to the pattern rule.
    var fileAllowlist: [String]? {
        if case .files(let f) = delivery { return f }
        return nil
    }

    /// Whether the weights are on the phone right now.
    ///
    /// The built-in is always "installed" — it's part of the OS. Everything else is a
    /// question for the shared store, which is the only thing that actually knows.
    var isInstalled: Bool {
        if isBuiltIn { return true }
        return SharedModelStore.isRepoDownloaded(id)
    }

    /// Real bytes on disk, once it's here. 0 if it isn't.
    var bytesOnDisk: Int64 {
        isBuiltIn ? 0 : SharedModelStore.sizeOnDisk(id)
    }

    /// Which apps in the family are holding this model.
    ///
    /// Shown because it is the honest answer to "why didn't deleting this free any space,"
    /// and because Mark's rule for the store is a refcount: *"Deleting a model from an app
    /// does not delete it from the repository. Deleting it from the last remaining app to
    /// have it in use deletes it from the repository."*
    var claimants: [String] {
        isBuiltIn ? [] : SharedModelStore.claimants(modelID: id)
    }
}

/// `nonisolated` because the catalog is plain data and its readers are not on the main
/// actor — `DrawerLoader` and `QwenLoader` are actors that load weights off-main by design,
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
        blurb: "On the phone already — nothing to download. A filter stops some images before the model sees them; when that happens the camera asks again with the filter relaxed, and records both answers.",
        licence: nil
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
        licence: "Apache 2.0"
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
        displayName: "SD-Turbo",
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
        blurb: "Draws the third frame — the machine's re-imagining, made from its own words. Never sees your photograph; it only reads what the eye said about it.",
        licence: "Stability AI Community License — free under $1M revenue"
    )

    static let all: [CameraModel] = [apple, qwen, sdTurbo]

    static func models(for job: ModelJob) -> [CameraModel] {
        all.filter { $0.job == job }
    }

    /// Look a model up by the id the store and downloader key on.
    static func model(id: String) -> CameraModel? {
        all.first { $0.id == id }
    }

    /// The model backing a given eye, so Preferences and the library agree about what is
    /// loaded rather than each keeping its own idea.
    static func model(for seer: Seer) -> CameraModel {
        switch seer {
        case .apple: return apple
        case .qwen:  return qwen
        }
    }
}

// ==== LEGO END: 27 Model Catalog (What The Camera Can Load) ====
