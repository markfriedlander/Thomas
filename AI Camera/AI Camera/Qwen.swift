//
//  Qwen.swift
//  AI Camera
//
//  The second eye — Qwen3.5-2B, running locally through MLX.
//
//  Where `Eye` (Seeing.swift) is Apple's on-device model, this is the downloadable
//  upgrade: bigger, richer, and **unguarded**. That last word is the point. AFM ships
//  with a filter that stops images at the door before the model ever sees them. This
//  model has no bouncer. It looks at what you point it at and says what it sees.
//
//  Mark's framing (2026-07-14): AFM is the *bridge* — the free floor that lets the app
//  ship at all. This is where it's supposed to go: *"hopefully people will get a more
//  free model to use regularly. Hopefully many of them."*
//
//  ⚠️ Nobody in the family has run a VLM before. Hal links MLXLLM (text only); Posey
//  doesn't do vision at all. This is the first, and the pieces below were verified
//  against mlx-swift-lm 3.31.4 by reading the source, not the docs:
//    - `qwen3_5` IS in MLXVLM's registry: `create(Qwen35Configuration.self, Qwen35.init)`
//      — that closed the open gate in Hal's own vision note.
//    - `ModelConfiguration(directory:)` loads from a local folder, so we never download.
//    - `Memory.cacheLimit = 20MB` is Hal's hard-won iOS setting. Without it MLX's buffer
//      cache balloons and iOS kills the app.
//

import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import MLX
import MLXLMCommon
import MLXVLM
import MLXHuggingFace
import Tokenizers

// ==== LEGO START: 18 The MLX Eye (Load Any VLM) ====

/// A downloadable vision-language model, loaded from the family's shared store and run
/// through MLX. This is the **generic** eye: `repoID` names which model, so one type serves
/// Qwen and any other VLM in the mlx-swift registry that the catalog offers. (Generalized
/// 2026-07-21 from a Qwen-only struct — the engine underneath, `VLMModelFactory`, was always
/// model-agnostic; only this wrapper and the `Seer` enum were hardcoded.)
///
/// Where `Eye` (Seeing.swift) is Apple's built-in, guarded model, an MLX eye is the
/// downloadable upgrade: bigger, richer, and **unguarded**. That last word is the point.
/// AFM ships with a filter that stops images at the door before the model ever sees them.
/// These models have no bouncer. They look at what you point them at and say what they see.
///
/// Note what's missing compared to `Eye`: there is no `guardrails` property and no
/// `lookWithRetry`. **An MLX eye cannot return `.blocked`** — there's no filter to block it.
/// It can still `.refuse` in the ordinary sense of saying so in its own words, but that
/// arrives as *text*, not as an error, because nothing external is policing it. The
/// `Perception` type absorbs that difference without changing shape.
///
/// Same instructions for every eye, deliberately: a fair comparison needs the *only*
/// difference to be the model. If we hand-tune a prompt per model we're measuring our
/// prompt-writing, not the machines — that's the experiment Mark wants: *"run the same
/// harness against multiple models, and see how each one finds truth and what they see."*
/// The one thing that IS per-model is the sampler recipe (`VisionRecipe`), because that's a
/// property of the model's decoder, not an instruction to it.
nonisolated struct MLXVLMEye: Sendable {
    /// The shared-store repo id — which model this eye is.
    let repoID: String
    var systemPrompt: String
    var temperature: Double

    /// The image is already upright — see `uprighted`.
    func look(at image: CGImage) async -> Perception {
        do {
            let container = try await MLXEyeLoader.shared.container(for: repoID)

            let ci = CIImage(cgImage: image)

            let session = ChatSession(
                container,
                // Layer 1 (locked brevity) + Layer 2 (the user's prompt). Same as the Apple
                // eye — every eye gets the same brevity floor. See `PromptLayers`.
                instructions: PromptLayers.compose(userPrompt: systemPrompt),
                generateParameters: VisionRecipe.params(forRepo: repoID, temperature: temperature)
            )
            let text = try await session.respond(to: "Describe what you see.",
                                                 image: .ciImage(ci))
            return .spoke(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                          tokens: nil)
        } catch {
            return .broke(reason: "\(error)")
        }
    }

    /// The eye restating its own words in fewer of them. See `Eye.condense` for the why and
    /// the whole design; this is the same step for the unguarded eye.
    ///
    /// Cheap: the container is already resident (the look just used it, and `Shot` condenses
    /// before the teardown), so this is a text-only generation — no image, no reload. Its own
    /// compression instruction, not the user's Layer 2. Returns nil on failure; the caller
    /// falls back to the full words under the tokenizer's hard cap.
    func condense(_ text: String, toAtMostWords maxWords: Int) async -> String? {
        do {
            let container = try await MLXEyeLoader.shared.container(for: repoID)
            let session = ChatSession(
                container,
                instructions: """
                    You shorten a description while keeping its concrete visual content — the \
                    things named, and their colors, textures, and arrangement. Remove nothing \
                    that could be drawn; drop only what couldn't. Output the shortened \
                    description and nothing else — no preamble.
                    """,
                generateParameters: VisionRecipe.params(forRepo: repoID, temperature: 0.3)
            )
            let out = try await session.respond(to: "Rewrite this in no more than \(maxWords) words:\n\n\(text)")
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            return nil
        }
    }
}

/// Qwen3.5-2B — the reference MLX eye, and the first VLM anyone in the family ran. Kept as a
/// named namespace because its repo id and its published vision recipe are referenced from
/// several places (the catalog, the memory pre-flight, the antenna).
///
/// ⚠️ Nobody in the family had run a VLM before this. Hal links MLXLLM (text only); Posey
/// doesn't do vision at all. The pieces below were verified against mlx-swift-lm 3.31.4 by
/// reading the source, not the docs:
///   - `qwen3_5` IS in MLXVLM's registry: `create(Qwen35Configuration.self, Qwen35.init)`
///     — that closed the open gate in Hal's own vision note.
///   - `ModelConfiguration(directory:)` loads from a local folder, so we never download.
///   - `Memory.cacheLimit = 20MB` is Hal's hard-won iOS setting. Without it MLX's buffer
///     cache balloons and iOS kills the app.
nonisolated enum Qwen {
    /// The repo id, as it sits in the shared container. Hal and Posey already downloaded
    /// this; we adopt it. Zero bytes, zero wait.
    static let repo = "mlx-community/Qwen3.5-2B-MLX-4bit"

    /// ⭐ Qwen's **published vision recipe**, not the library defaults.
    ///
    /// Caught by the Hal CC on 2026-07-14 and handed to us before we chased it ourselves:
    /// *"Qwen3.5-2B's vision path is the same family that loops on us, and its recommended
    /// vision recipe is different from the text one."*
    ///
    /// From the base model card (**the 2B ships NO `generation_config`**, so nothing on
    /// disk will ever correct a wrong default — this must be set in code):
    ///   - thinking-**TEXT**   = temp 1.0 / top_p 0.95 / top_k 20 / min_p 0 / presence 1.5
    ///   - thinking-**VISION** = temp 0.6 / presence 0.0     ← **us**
    ///
    /// Hal's diagnosis of their own bug, which we had faithfully reproduced: *"we run every
    /// curated model outside its recommended sampler (we pass only temperature +
    /// repetitionPenalty; never top_k/top_p/presence_penalty)."* Our first version passed
    /// temperature and nothing else, which left **topK at 0 (filtering OFF) and topP at
    /// 1.0 (filtering OFF)** — the model free to reach for any token in the vocabulary.
    ///
    /// ⚠️ Do NOT copy Hal's *text* recipe here. temp 1.0 / presence 1.5 is a different
    /// mode; Hal measured temp 1.0 looping on deterministic tasks (188s loop → 11s correct
    /// answer at 0.6). Vision gets 0.6 / 0.0. Two recipes, one model.
    ///
    /// (Card note, if descriptions ever start repeating themselves: *"adjust
    /// presence_penalty 0–2 to reduce endless repetitions."*)
    static func visionRecipe(temperature: Double) -> GenerateParameters {
        GenerateParameters(
            temperature: Float(temperature),   // card: 0.6 for vision
            topP: 0.95,
            topK: 20,
            minP: 0,
            presencePenalty: 0.0
        )
    }
}

/// Which sampler recipe an MLX eye uses, chosen by repo id.
///
/// A model's vision recipe is a property of the model, not the library. MLX's defaults leave
/// top_k/top_p filtering OFF, which sets a VLM free to reach for any token in the vocabulary
/// and loop — the bug Hal diagnosed and we reproduced (see `Qwen.visionRecipe`). So a model
/// with a known recipe gets a case here; anything else gets a sane, conservative default
/// until we learn its own. This is the one place a new eye may need a line of its own.
nonisolated enum VisionRecipe {
    static func params(forRepo repoID: String, temperature: Double) -> GenerateParameters {
        switch repoID {
        case Qwen.repo: return Qwen.visionRecipe(temperature: temperature)
        default:        return defaultParams(temperature: temperature)
        }
    }

    /// A conservative default for a model whose own recipe we don't yet encode: the requested
    /// temperature, with top_p/top_k filtering ON so the decoder can't wander the whole
    /// vocabulary. Mirrors Qwen's shape, a reasonable floor for the small VLMs we target.
    static func defaultParams(temperature: Double) -> GenerateParameters {
        GenerateParameters(
            temperature: Float(temperature),
            topP: 0.95,
            topK: 20,
            minP: 0,
            presencePenalty: 0.0
        )
    }
}

/// Holds the one loaded MLX eye.
///
/// Loading is **expensive** (gigabytes off disk and into memory), so we hold exactly one
/// model resident and unload it to switch — the model-ownership rule (the dark room queue
/// owns loading; see `Settings.seer`). Doing a load per shutter press would be absurd. An
/// actor because a load must happen exactly once even if two looks race to be first: the
/// second waits for the first rather than starting a second multi-GB load beside it, which
/// on a phone is how you get killed.
actor MLXEyeLoader {
    static let shared = MLXEyeLoader()

    private var loadedID: String?
    private var loaded: ModelContainer?
    private var loading: (id: String, task: Task<ModelContainer, Error>)?

    /// Whether a given model's weights are on disk right now (they are, if Hal or Posey
    /// fetched them, or the library downloaded them here).
    nonisolated static func isAvailable(_ repoID: String) -> Bool {
        SharedModelStore.isRepoDownloaded(repoID)
    }

    /// True once *some* eye is resident in memory.
    var isLoaded: Bool { loaded != nil }
    /// True when the resident eye is exactly this model.
    func isLoadedRepo(_ repoID: String) -> Bool { loaded != nil && loadedID == repoID }
    /// The repo id of the resident eye, if any.
    var residentRepoID: String? { loaded != nil ? loadedID : nil }

    func container(for repoID: String) async throws -> ModelContainer {
        // Already resident: hand it back.
        if let loaded, loadedID == repoID { return loaded }
        // The same model is mid-load: wait for that load rather than start a second one.
        if let loading, loading.id == repoID { return try await loading.task.value }
        // A *different* eye is resident or mid-load. One eye at a time: let any in-flight load
        // settle, then unload whatever's resident before loading the new one. (Heavy ops are
        // serialized by `ModelLane` upstream, so a concurrent different-id load isn't a path
        // the app actually takes; this is belt-and-braces so switching can never leave two
        // multi-GB models resident at once.)
        if let loading { _ = try? await loading.task.value }
        if loaded != nil { unload() }

        let task = Task<ModelContainer, Error> {
            // Hal's line, and not optional on a phone: cap MLX's buffer cache or it grows
            // until iOS jetsams the app. 20 MB is the documented iOS figure.
            MLX.Memory.cacheLimit = 20 * 1024 * 1024

            let directory = SharedModelStore.mlxModelDir(repoID)
            guard SharedModelStore.isRepoDownloaded(repoID) else {
                throw MLXEyeError.notInstalled(repoID)
            }

            // PRE-FLIGHT REFUSAL. Everything below this line mmaps gigabytes of weights and
            // faults the pages in. If there isn't room, iOS kills the process — no error,
            // no message, the camera just vanishes from the user's hand. So we ask first.
            //
            // The requirement is computed from the weights' ACTUAL size on disk, not a
            // catalog figure (see ProcessMemoryGuard). If iOS hasn't finished reclaiming
            // from a previous unload, wait for it — that's the lazy-VM problem, and the
            // poll is the only honest way to know when it's done rather than sleeping a
            // fixed interval and hoping.
            let requiredMB = requiredMemoryMBForLoad(repo: repoID)
            var availableMB = processAvailableMemoryMB()
            cameraLog("MEMORY: pre-flight for \(repoID) requiredMB=\(formatMB(requiredMB)) availableMB=\(formatMB(availableMB))")

            if availableMB < requiredMB {
                cameraLog("MEMORY: short on headroom — waiting for iOS to reclaim")
                let result = await waitForMemoryHeadroom(requiredMB: requiredMB)
                availableMB = result.finalAvailableMB
                cameraLog("MEMORY: headroom wait \(result.success ? "succeeded" : "TIMED OUT") after \(result.pollsTaken) polls / \(String(format: "%.2f", result.elapsedSeconds))s — availableMB=\(formatMB(availableMB))")
            }

            // A timeout is not itself fatal; the number is. Refuse on the number.
            guard availableMB >= requiredMB else {
                let name = ModelCatalog.model(id: repoID)?.displayName ?? repoID
                let message = memoryRefusalMessage(modelName: name,
                                                   availableMB: availableMB,
                                                   requiredMB: requiredMB)
                cameraLog("MEMORY: REFUSED load — \(message)")
                throw MLXEyeError.notEnoughMemory(message: message)
            }

            // ⭐ CLAIM-ON-ADOPT (the shared-store contract's one rule — NEXT.md). Record our
            // claim BEFORE we rely on any release, INCLUDING for a model we didn't download
            // ourselves. `releaseClaim` returns true for a model with no manifest entry, so an
            // unclaimed-but-present ("adopted") model looks safe to delete to Hal's or Posey's
            // refcount — claiming here is what stops a sibling app deleting weights out from
            // under a shot in progress. Uniform across every eye, which is exactly what the
            // shared-store package needs. See SharedModelStore.
            SharedModelStore.claim(modelID: repoID, repo: repoID,
                                   sizeBytes: SharedModelStore.sizeOnDisk(repoID))
            SharedModelStore.excludeFromBackup(repoID)

            // The directory overload, NOT Hal's `configuration:` + `#hubDownloader()`
            // form. Hal passes a downloader it never uses (its own comment says so) and
            // needs it only to thread `extraEOSTokens` through — a text-model concern we
            // don't have. Taking the directory form means we never name a downloader here.
            // By this point the weights are already on disk either way (the library fetches
            // them through `MLXModelDownloader`); loading is not downloading.
            return try await VLMModelFactory.shared.loadContainer(
                from: directory,
                using: #huggingFaceTokenizerLoader()
            )
        }
        loading = (id: repoID, task: task)
        defer { loading = nil }

        let container = try await task.value
        loaded = container
        loadedID = repoID
        return container
    }

    /// Drop the resident eye from memory — properly.
    ///
    /// This used to be `loaded = nil` and a comment saying it wasn't wired to anything.
    /// Both halves of that were bugs. Rebuilt 2026-07-15 from Hal's `unloadModel()`, which
    /// is what Mark asked for on day one.
    ///
    /// ⚠️ **The GPU drain is not optional and it is not a nicety.** Releasing the container
    /// while Metal command buffers from the last look are still in flight means their
    /// completion handlers fire against memory ARC has already freed; the buffers come back
    /// with `.error` set, MLX's `check_error` throws an uncaught C++ exception, and the app
    /// takes a SIGABRT. Hal has a crash log for exactly this. `loaded = nil` on its own was
    /// a latent crash waiting for someone to call it — which is the only reason it never
    /// crashed: nothing ever did.
    ///
    /// Order matters: drain, then release, then clear MLX's cache. The before/after
    /// snapshot goes to the log because iOS reclaims lazily — `iosAvail` at exit is usually
    /// about what it was at entry, and that is *expected*, not a failure. Whoever loads
    /// next is the one who has to wait for the OS to catch up (`waitForMemoryHeadroom`).
    func unload() {
        guard loaded != nil else {
            cameraLog("MEMORY: unload called with nothing resident — no-op")
            return
        }

        let mb = { (b: Int) -> String in String(format: "%.1f MB", Double(b) / (1024.0 * 1024.0)) }
        let before = MLX.Memory.snapshot()
        let availBefore = processAvailableMemoryMB()
        cameraLog("MEMORY: unload ENTRY active=\(mb(before.activeMemory)) cache=\(mb(before.cacheMemory)) peak=\(mb(before.peakMemory)) iosAvailMB=\(formatMB(availBefore))")

        // GPU SYNC BARRIER — see the warning above. Synchronous; usually milliseconds.
        cameraLog("MEMORY: draining in-flight GPU work before unload…")
        MLX.Stream.gpu.synchronize()
        cameraLog("MEMORY: GPU drain complete; releasing model")

        loaded = nil
        loadedID = nil
        MLX.Memory.clearCache()

        let after = MLX.Memory.snapshot()
        let availAfter = processAvailableMemoryMB()
        cameraLog("MEMORY: unload EXIT  active=\(mb(after.activeMemory)) cache=\(mb(after.cacheMemory)) peak=\(mb(after.peakMemory)) iosAvailMB=\(formatMB(availAfter)) | ΔiosAvailMB=\(formatMB(availAfter - availBefore))")
    }
}

enum MLXEyeError: LocalizedError {
    case notInstalled(String)
    case notEnoughMemory(message: String)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let repo):
            // Was: "Download it in Hal or Posey and it appears here." True on day one, when
            // this app genuinely couldn't fetch a byte. It can now — Preferences → Models →
            // Browse Model Library. Sending a user to two unreleased apps is no longer an
            // answer, and it never should have been the shipping one.
            return "\(repo) isn't downloaded yet. Get it in Preferences → Models → Browse Model Library."
        case .notEnoughMemory(let message):
            return message
        }
    }
}

// ==== LEGO END: 18 The MLX Eye (Load Any VLM) ====
