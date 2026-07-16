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

// ==== LEGO START: 18 Qwen (The Unguarded Eye) ====

/// The Qwen3.5-2B vision-language model, loaded from the family's shared store.
///
/// Note what's missing compared to `Eye`: there is no `guardrails` property and no
/// `lookWithRetry`. **This model cannot return `.blocked`** — there's no filter to block
/// it. It can still `.refuse` in the ordinary sense of saying so in its own words, but
/// that arrives as *text*, not as an error, because nothing external is policing it.
/// The `Perception` type absorbs that difference without changing shape.
nonisolated struct Qwen: Sendable {

    /// The repo id, as it sits in the shared container. Hal and Posey already downloaded
    /// this; we adopt it. Zero bytes, zero wait.
    nonisolated static let repo = "mlx-community/Qwen3.5-2B-MLX-4bit"

    var systemPrompt: String
    var temperature: Double

    /// Same instructions as the Apple eye, deliberately.
    ///
    /// A fair comparison needs the *only* difference to be the model. If we hand-tune a
    /// prompt per model we're measuring our prompt-writing, not the machines. Same words,
    /// same temperature, two different eyes — that's the experiment Mark wants: *"run the
    /// same harness against multiple models, and see how each one finds truth and what
    /// they see."*
    static let plain = Qwen(systemPrompt: Eye.plain.systemPrompt,
                            temperature: Eye.plain.temperature)

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

    /// The image is already upright — see `uprighted`.
    func look(at image: CGImage) async -> Perception {
        do {
            let container = try await QwenLoader.shared.container()

            let ci = CIImage(cgImage: image)

            let session = ChatSession(
                container,
                instructions: systemPrompt,
                generateParameters: Self.visionRecipe(temperature: temperature)
            )
            let text = try await session.respond(to: "Describe what you see.",
                                                 image: .ciImage(ci))
            return .spoke(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                          tokens: nil)
        } catch {
            return .broke(reason: "\(error)")
        }
    }
}

/// Holds the loaded model.
///
/// This exists because loading is **expensive**: 1.75 GB off disk and into memory. Doing
/// that per shutter press would be absurd. An actor because the load must happen exactly
/// once even if two looks race to be first — the second waits for the first rather than
/// starting a second 1.75 GB load beside it, which on a phone is how you get killed.
actor QwenLoader {
    static let shared = QwenLoader()

    private var loaded: ModelContainer?
    private var loading: Task<ModelContainer, Error>?

    /// Whether the weights are on disk right now (they are, if Hal or Posey fetched them).
    nonisolated static var isAvailable: Bool {
        SharedModelStore.isRepoDownloaded(Qwen.repo)
    }

    /// True once the model is resident in memory.
    var isLoaded: Bool { loaded != nil }

    func container() async throws -> ModelContainer {
        if let loaded { return loaded }
        // A load already in flight: wait for it rather than start a second one.
        if let loading { return try await loading.value }

        let task = Task<ModelContainer, Error> {
            // Hal's line, and not optional on a phone: cap MLX's buffer cache or it grows
            // until iOS jetsams the app. 20 MB is the documented iOS figure.
            MLX.Memory.cacheLimit = 20 * 1024 * 1024

            let directory = SharedModelStore.mlxModelDir(Qwen.repo)
            guard SharedModelStore.isRepoDownloaded(Qwen.repo) else {
                throw QwenError.notInstalled(Qwen.repo)
            }

            // PRE-FLIGHT REFUSAL. Everything below this line mmaps 1.75 GB of weights and
            // faults the pages in. If there isn't room, iOS kills the process — no error,
            // no message, the camera just vanishes from the user's hand. So we ask first.
            //
            // The requirement is computed from the weights' ACTUAL size on disk, not a
            // catalog figure (see ProcessMemoryGuard). If iOS hasn't finished reclaiming
            // from a previous unload, wait for it — that's the lazy-VM problem, and the
            // poll is the only honest way to know when it's done rather than sleeping a
            // fixed interval and hoping.
            let requiredMB = requiredMemoryMBForLoad(repo: Qwen.repo)
            var availableMB = processAvailableMemoryMB()
            cameraLog("MEMORY: pre-flight for \(Qwen.repo) requiredMB=\(formatMB(requiredMB)) availableMB=\(formatMB(availableMB))")

            if availableMB < requiredMB {
                cameraLog("MEMORY: short on headroom — waiting for iOS to reclaim")
                let result = await waitForMemoryHeadroom(requiredMB: requiredMB)
                availableMB = result.finalAvailableMB
                cameraLog("MEMORY: headroom wait \(result.success ? "succeeded" : "TIMED OUT") after \(result.pollsTaken) polls / \(String(format: "%.2f", result.elapsedSeconds))s — availableMB=\(formatMB(availableMB))")
            }

            // A timeout is not itself fatal; the number is. Refuse on the number.
            guard availableMB >= requiredMB else {
                let message = memoryRefusalMessage(modelName: "Qwen3.5-2B",
                                                   availableMB: availableMB,
                                                   requiredMB: requiredMB)
                cameraLog("MEMORY: REFUSED load — \(message)")
                throw QwenError.notEnoughMemory(message: message)
            }

            // Adopt it: record our claim so Hal's or Posey's delete can't pull the
            // weights out from under a shot in progress. This is the whole point of the
            // refcount manifest — see SharedModelStore.
            SharedModelStore.claim(modelID: Qwen.repo, repo: Qwen.repo,
                                   sizeBytes: SharedModelStore.sizeOnDisk(Qwen.repo))
            SharedModelStore.excludeFromBackup(Qwen.repo)

            // The directory overload, NOT Hal's `configuration:` + `#hubDownloader()`
            // form. Hal passes a downloader it never uses (its own comment says so) and
            // needs it only to thread `extraEOSTokens` through — a text-model concern we
            // don't have. Taking the directory form means we never even name a
            // downloader, which is honest: this app cannot download, and the code now
            // says that.
            return try await VLMModelFactory.shared.loadContainer(
                from: directory,
                using: #huggingFaceTokenizerLoader()
            )
        }
        loading = task
        defer { loading = nil }

        let container = try await task.value
        loaded = container
        return container
    }

    /// Drop the model from memory — properly.
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
        MLX.Memory.clearCache()

        let after = MLX.Memory.snapshot()
        let availAfter = processAvailableMemoryMB()
        cameraLog("MEMORY: unload EXIT  active=\(mb(after.activeMemory)) cache=\(mb(after.cacheMemory)) peak=\(mb(after.peakMemory)) iosAvailMB=\(formatMB(availAfter)) | ΔiosAvailMB=\(formatMB(availAfter - availBefore))")
    }
}

enum QwenError: LocalizedError {
    case notInstalled(String)
    case notEnoughMemory(message: String)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let repo):
            return "\(repo) isn't in the shared store. Download it in Hal or Posey and it appears here."
        case .notEnoughMemory(let message):
            return message
        }
    }
}

// ==== LEGO END: 18 Qwen (The Unguarded Eye) ====
