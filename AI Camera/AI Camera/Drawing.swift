//
//  Drawing.swift
//  AI Camera
//
//  Frame 3. The hand.
//
//  Mark, three days and three sessions in, after every one of them found a principled reason
//  to defer this: *"I'm here to build this app which has three frames. Two of them exist why
//  are we still not building the third? It cannot exist until you build it."*
//
//  ── What this is ──
//
//  The machine re-imagining the scene from its own words. It **never sees the photograph** —
//  it only reads what the eye said about it. That is the whole architecture of the app in one
//  sentence: reality → machine perception (text) → machine re-imagining (image). The text is
//  a bottleneck on purpose, and the gap it opens is the art.
//
//  ── Why sd-turbo ──
//
//  See `ModelCatalog.sdTurbo`. Short version: NEXT.md's plan named Stable Diffusion 2.1 base,
//  and that repo no longer exists — Stability withdrew the 2.x line, verified three ways on
//  2026-07-15. sd-turbo is distilled *from* SD 2.1, so it fits the same code path, and it
//  draws in 1–4 steps rather than 50.
//
//  ── What's unknown, stated plainly ──
//
//  **Nobody has ever published a measurement of MLX drawing on an iPhone.** Not Apple, not the
//  research fleet, not either failed session, nobody. Everything anyone in this project knows
//  about MLX diffusion came from *reading the library's source*, which tells you what it asks
//  for and nothing about whether it runs. So this file is a question before it is a feature,
//  and Mark set the bar: **"Alive first. Speed later if we so choose."**
//
//  ── Memory ──
//
//  Under Mark's design the frames are discrete — *"at no point should the app maintain
//  overhead from one frame into another"* — so the eye is torn down before the hand loads and
//  they never coexist. The bar is "does the biggest single model fit alone," not "do both
//  fit." Measured 2026-07-15 on the iPhone 16 Plus: **6,129 MB available**, and Qwen gives
//  back 1,664 MB in 79 ms when dropped. A 2.4 GB model has room.
//
//  ⚠️ `ProcessMemoryGuard`'s 0.75 dirty-memory ratio is Hal's, calibrated for **4-bit
//  quantized safetensors via mmap**. These are fp16 diffusion weights — a different shape and
//  a different residency pattern. **The estimate below is not to be trusted until measured**;
//  it is a starting guess, labelled as one, and `GET /memory` is how it gets checked. Do not
//  inherit a number across a change of subject. That is how the Core AI day happened.
//

import CoreGraphics
import Foundation
import Hub
import MLX
import SharedModelStoreKit

// ==== LEGO START: 26 The Hand (Frame 3 — Drawing From Words) ====

nonisolated struct Drawing: Sendable {
    /// Which drawer this is — the shared-store repo id. Every render-affecting knob below is a
    /// property of this specific drawer; a different drawer is a different `Drawing` (see
    /// `spec(for:)`). Generalized 2026-07-21 from a single hardcoded sd-turbo recipe: the vendored
    /// pipeline was always model-agnostic — only this recipe and the loader named one model.
    /// sd-turbo is the only drawer implemented today; its numbers below are unchanged.
    let repoID: String

    /// How many denoising steps. sd-turbo is *distilled* to need very few — it was trained
    /// for single-step generation and stays coherent to about 4.
    ///
    /// ⚠️ **Do not read the stock demo app's step handling as guidance.** It drops to a single
    /// step whenever `Memory.memoryLimit < 8 GB`, and on iOS that is the *task* limit, so
    /// every iPhone trips it. For SDXL-Turbo that's fine — one step is what Turbo is. NEXT.md
    /// warns that inheriting that behaviour with a non-turbo model gives you noise and the
    /// conclusion "MLX can't draw." We're on a turbo model, so the trap doesn't bite, but the
    /// number here is chosen, not inherited.
    var steps: Int

    /// Classifier-free guidance. **Zero for sd-turbo, and that is not a placeholder.** Turbo
    /// models are distilled without CFG; giving them a guidance weight doesn't sharpen the image,
    /// it doubles the work (CFG evaluates the UNet twice per step) and degrades the result. The
    /// library's own SDXL-Turbo preset uses `cfgWeight: 0` for the same reason. A non-turbo drawer
    /// would set this above zero.
    var cfgWeight: Float

    /// 64 latent units → a 512×512 image. sd-turbo's native resolution; asking for more
    /// doesn't add detail, it adds artefacts and memory.
    var latentSize: [Int]

    var seed: UInt64?

    /// Whether to 8-bit-quantize the weights on load. Off for sd-turbo (its fp16 weights fit); a
    /// bigger drawer like SSD-1B would set this true. Threaded into `LoadConfiguration`.
    var quantize: Bool

    /// Tiled VAE-decode geometry — see `Autoencoder.decodeTiled`. The monolithic decode of a
    /// 64×64 latent to 512×512 peaked ~4.5 GB and jetsammed the process every time (measured
    /// 2026-07-15); decoding in overlapping tiles caps the peak at roughly the tile's share of the
    /// area. 40-unit tiles overlapping by 16 tile the 64×64 latent **2×2** (four 320×320-pixel
    /// tiles, a ~0.39× area ceiling) with a wide feather to hide the seam. This is a device-tuning
    /// knob: drop the tile size for a 3×3 grid if a device still cannot afford 2×2.
    ///
    /// **Fidelity-preserving:** this is sd-turbo's own VAE, just run in pieces — the re-imagining
    /// is exactly what the full decode would have produced, only under a memory ceiling. (These
    /// are sd-turbo's 512² geometry; a drawer with a different native resolution would need its
    /// own, so this becomes per-drawer when a second drawer with a different size lands.)
    static let decodeTileLatent = 40
    static let decodeOverlapLatent = 16

    /// Peak memory of the *tiled* full-VAE decode, in MB — the bar the auto-fallback checks before
    /// it commits a Detailed shot to the full VAE. ✅ **MEASURED 2026-07-17 on an iPhone 16 Plus:**
    /// the monolithic decode peaked ~4,559 MB; 2×2 tiling brings it to **~3,480 MB** (a ~1,080 MB
    /// drop, comfortably under the ~6,122 MB ceiling). Rounded up slightly for safety. With the 500
    /// margin, Detailed runs when ~4 GB is free after the UNet is released, else falls back to TAESD.
    static let tiledDecodePeakMB: Double = 3500
    /// Headroom kept free above that estimate, so Detailed commits to the full VAE only with margin
    /// to spare — and drops to TAESD (a few hundred MB, effectively always affordable) otherwise.
    static let decodeHeadroomMarginMB: Double = 500

    /// The reference drawer: sd-turbo. Also the drawer a shot frozen before drawers were selectable
    /// falls back to — its config named no drawer because sd-turbo was the only one there was.
    static let sdTurbo = Drawing(
        repoID: ModelCatalog.sdTurbo.id,
        steps: 4,
        cfgWeight: 0,
        latentSize: [64, 64],
        seed: nil,
        quantize: false
    )

    /// Resolve a drawer repo id to its recipe. `nil` for an id with no spec — the loader refuses
    /// rather than guess a pipeline for a drawer it doesn't know. A new drawer adds a case here and
    /// one in `pipelineConfiguration(for:)`; the loader itself never changes.
    static func spec(for repoID: String) -> Drawing? {
        switch repoID {
        case ModelCatalog.sdTurbo.id: return sdTurbo
        default: return nil
        }
    }

    /// The words the eye produced, handed to the hand unedited.
    ///
    /// **Principle 3, and this is the load-bearing decision in the file.** It is tempting to
    /// "help" — to strip the eye's hedges, append "highly detailed, 4k, masterpiece", or
    /// rewrite the perception into something a diffusion model finds easier to draw. Every
    /// one of those closes the gap this app exists to show. The hand draws what the eye said.
    /// If the eye said something strange, the strangeness is the point, and the triptych is
    /// self-auditing — panel 1 is right there and the viewer judges.
    func parameters(prompt: String) -> EvaluateParameters {
        EvaluateParameters(
            cfgWeight: cfgWeight,
            steps: steps,
            imageCount: 1,
            decodingBatchSize: 1,
            latentSize: latentSize,
            seed: seed,
            prompt: prompt,
            negativePrompt: ""
        )
    }

    /// The pipeline configuration (files + factory) for a drawer, by repo id. `nil` for an unknown
    /// drawer — paired with `spec(for:)` at the loader, which refuses rather than guess.
    ///
    /// This configuration is the entire reason the library is vendored rather than added as a
    /// package. `StableDiffusionConfiguration`'s `files` and `factory` are `internal`, and a
    /// struct with internal members has an internal memberwise init — so from *outside* the
    /// module this could not be written at all. Inside our own target, it can.
    ///
    /// Two things it fixes that the shipped presets get wrong for a phone:
    ///   1. **The repo is alive.** `presetStableDiffusion21Base` points at a 401.
    ///   2. **The fp16 twins.** The presets hardcode fp32 filenames and convert to float16
    ///      after loading — paying the heavy download to use the light weights while the fp16
    ///      files sit unused in the same repo. Measured: 4.81 GB as the preset asks vs
    ///      **2.40 GB** for these. Same weights.
    static func pipelineConfiguration(for repoID: String) -> StableDiffusionConfiguration? {
        switch repoID {
        case ModelCatalog.sdTurbo.id:
            return StableDiffusionConfiguration(
                id: repoID,
                files: [
                    .unetConfig: "unet/config.json",
                    .unetWeights: "unet/diffusion_pytorch_model.fp16.safetensors",
                    .textEncoderConfig: "text_encoder/config.json",
                    .textEncoderWeights: "text_encoder/model.fp16.safetensors",
                    .vaeConfig: "vae/config.json",
                    .vaeWeights: "vae/diffusion_pytorch_model.fp16.safetensors",
                    .diffusionConfig: "scheduler/scheduler_config.json",
                    .tokenizerVocabulary: "tokenizer/vocab.json",
                    .tokenizerMerges: "tokenizer/merges.txt",
                ],
                defaultParameters: { EvaluateParameters(cfgWeight: 0, steps: 4) },
                factory: { hub, sdConfiguration, loadConfiguration in
                    // StableDiffusionBase — the SD 2.1 path, one text encoder. sd-turbo IS 2.1's
                    // architecture; that is why it was chosen over SD 1.5, whose text encoder is
                    // a different shape. (SSD-1B would use StableDiffusionXL here.)
                    try StableDiffusionBase(
                        hub: hub, configuration: sdConfiguration, dType: loadConfiguration.dType)
                }
            )
        default:
            return nil
        }
    }

    /// Point the library at the family's shared store instead of its own cache.
    ///
    /// The two layouts already agree: `HubApi.localRepoLocation` resolves to
    /// `downloadBase/models/<repo-id>`, and `SharedModelStore.mlxModelDir` is
    /// `huggingface/models/<repo-id>`. So handing it `huggingFaceRoot` makes it find exactly
    /// what `MLXModelDownloader` put there — no download, no second copy, and Hal or Posey
    /// would find the same bytes. The same for every drawer, so it stays a single static.
    static var hub: HubApi {
        HubApi(downloadBase: SharedModelStore.huggingFaceRoot)
    }
}

/// Holds the drawing model, and lets go of it.
///
/// Deliberately the same shape as `MLXEyeLoader` — one resident model, a coalesced in-flight
/// load, a pre-flight refusal, and an `unload()` that drains the GPU before releasing. Not
/// symmetry for its own sake: the eye loader's `unload()` shipped as `loaded = nil`, which was a latent
/// SIGABRT (releasing the container while Metal command buffers are still in flight fires
/// their completion handlers against freed memory). The only reason it never crashed is that
/// nothing ever called it. That lesson costs nothing to apply here and everything to relearn.
actor DrawerLoader {
    static let shared = DrawerLoader()

    private var loadedID: String?
    private var loaded: TextToImageGenerator?
    private var loading: (id: String, task: Task<TextToImageGenerator, Error>)?

    /// Whether a given drawer's weights are on disk right now.
    nonisolated static func isAvailable(_ repoID: String) -> Bool {
        SharedModelStore.isRepoDownloaded(repoID)
    }

    var isLoaded: Bool { loaded != nil }
    /// True when the resident drawer is exactly this one.
    func isLoadedRepo(_ repoID: String) -> Bool { loaded != nil && loadedID == repoID }

    func generator(for repoID: String) async throws -> TextToImageGenerator {
        // Already resident: hand it back.
        if let loaded, loadedID == repoID { return loaded }
        // The same drawer is mid-load: wait for that load rather than start a second one.
        if let loading, loading.id == repoID { return try await loading.task.value }
        // A *different* drawer is resident or mid-load. One drawer at a time (the memory bar is
        // "does the biggest single model fit alone"), so let any in-flight load settle, then
        // unload whatever's resident before loading the new one.
        if let loading { _ = try? await loading.task.value }
        if loaded != nil { await unload() }

        // Refuse a drawer we have no pipeline for, rather than guess its files or architecture.
        // (Paired lookups: the recipe and the file/factory config, both keyed by the same id.)
        guard let spec = Drawing.spec(for: repoID),
              let configuration = Drawing.pipelineConfiguration(for: repoID) else {
            throw DrawingError.unknownDrawer(repoID)
        }

        let task = Task<TextToImageGenerator, Error> {
            // Hal's line, and not optional on a phone: cap MLX's buffer cache or it grows
            // until iOS jetsams the app.
            MLX.Memory.cacheLimit = 20 * 1024 * 1024

            guard SharedModelStore.isRepoDownloaded(repoID) else {
                throw DrawingError.notInstalled(repoID)
            }

            // PRE-FLIGHT. Same reasoning as the eye's: everything past this line maps the
            // weights and faults them in, and if there isn't room iOS kills the process
            // with no error and no message.
            //
            // The requirement uses the fp16 diffusion ratio (`fp16DirtyMemoryRatio`, 1.0), NOT
            // the eyes' 0.75 — fp16 weights fault in essentially whole. Calibrated from the
            // 2026-07-16 measurement (0.75 under-estimated this load by ~28%); still one device,
            // so watch GET /memory to re-verify across the lineup. (A bigger drawer may want its
            // own ratio; the spec is where that would go.)
            let requiredMB = requiredMemoryMBForLoad(repo: repoID, dirtyRatio: fp16DirtyMemoryRatio)
            var availableMB = processAvailableMemoryMB()
            cameraLog("DRAW: pre-flight for \(repoID) requiredMB=\(formatMB(requiredMB)) (fp16 ratio, one-device calibration) availableMB=\(formatMB(availableMB)) thermal=\(thermalStateLabel())")

            if availableMB < requiredMB {
                cameraLog("DRAW: short on headroom — waiting for iOS to reclaim")
                let result = await waitForMemoryHeadroom(requiredMB: requiredMB)
                availableMB = result.finalAvailableMB
                cameraLog("DRAW: headroom wait \(result.success ? "succeeded" : "TIMED OUT") after \(result.pollsTaken) polls / \(String(format: "%.2f", result.elapsedSeconds))s — availableMB=\(formatMB(availableMB))")
            }

            guard availableMB >= requiredMB else {
                let name = ModelCatalog.model(id: repoID)?.displayName ?? repoID
                let message = memoryRefusalMessage(modelName: name,
                                                   availableMB: availableMB,
                                                   requiredMB: requiredMB)
                cameraLog("DRAW: REFUSED load — \(message)")
                throw DrawingError.notEnoughMemory(message: message)
            }

            // ⭐ CLAIM-ON-ADOPT (the shared-store contract's one rule). Record our claim BEFORE
            // relying on any release, INCLUDING for a drawer we didn't download — an
            // unclaimed-but-present model looks safe to delete to Hal's or Posey's refcount, so
            // claiming is what stops a sibling app deleting the weights out from under a shot in
            // progress. Uniform with the eye loader. See SharedModelStore.
            SharedModelStore.claim(modelID: repoID, repo: repoID,
                                   sizeBytes: SharedModelStore.sizeOnDisk(repoID))
            SharedModelStore.excludeFromBackup(repoID)

            let before = processAvailableMemoryMB()
            let started = Date()
            guard let generator = try configuration.textToImageGenerator(
                hub: Drawing.hub,
                configuration: LoadConfiguration(float16: true, quantize: spec.quantize)
            ) else {
                throw DrawingError.wrongKind
            }
            // Force the weights in now rather than on first use, so the number below is the
            // real cost of loading and not half of it.
            generator.ensureLoaded()
            MLX.Stream.gpu.synchronize()

            let after = processAvailableMemoryMB()
            let snapshot = MLX.Memory.snapshot()
            cameraLog("DRAW: loaded \(repoID) in \(String(format: "%.2f", Date().timeIntervalSince(started)))s | iosAvailMB \(formatMB(before)) → \(formatMB(after)) (Δ\(formatMB(before - after))) | mlxActive=\(String(format: "%.1f", Double(snapshot.activeMemory) / 1_048_576)) MB peak=\(String(format: "%.1f", Double(snapshot.peakMemory) / 1_048_576)) MB")
            return generator
        }
        loading = (id: repoID, task: task)
        defer { loading = nil }
        let generator = try await task.value
        loaded = generator
        loadedID = repoID
        return generator
    }

    /// Drop the model. Drain first — see the note on the type.
    func unload() async {
        guard loaded != nil else { return }
        let snapshot = MLX.Memory.snapshot()
        let before = processAvailableMemoryMB()
        cameraLog("DRAW: unload ENTRY active=\(String(format: "%.1f", Double(snapshot.activeMemory) / 1_048_576)) MB peak=\(String(format: "%.1f", Double(snapshot.peakMemory) / 1_048_576)) MB iosAvailMB=\(formatMB(before))")

        // Drain in-flight GPU work BEFORE releasing. Metal command buffers from the last
        // draw hold references into these arrays; releasing underneath them fires their
        // completion handlers against ARC-freed memory and MLX's check_error throws an
        // uncaught C++ exception → SIGABRT. Hal has a crash log for exactly this.
        MLX.Stream.gpu.synchronize()
        loaded = nil
        loadedID = nil
        MLX.Memory.clearCache()

        let after = processAvailableMemoryMB()
        cameraLog("DRAW: unload EXIT  iosAvailMB=\(formatMB(after)) | ΔiosAvailMB=\(formatMB(after - before))")
    }

    /// Draw. Words in, a picture out.
    ///
    /// ── The two-stage shape, which is not a style choice — it is what makes this run ──
    ///
    /// **Measured 2026-07-15, the first time MLX diffusion was ever run on an iPhone:** the
    /// model loads (4.3 s, 2,702 MB), all four denoise steps complete (3.55 s), and then the
    /// process is **jetsammed at the VAE decode**. Denoising works at 64×64 latents; decoding
    /// inflates those to 512×512 through the autoencoder, and its intermediate activations
    /// need more room than is left with the UNet still resident.
    ///
    /// The library is built for exactly this and says so: `detachedDecoder()` is documented
    /// *"useful if trying to conserve memory"*, and `SDModelContainer.performTwoStage`
    /// discards the model between the two blocks. The trick is that the detached decoder
    /// captures **only the autoencoder** — so the UNet and text encoder (the ~1.6 GB that
    /// just finished their work and are never needed again this shot) can be released before
    /// the decode allocates anything.
    ///
    /// **And this is Mark's architecture, not a workaround for it:** *"at no point should the
    /// app maintain overhead from one frame into another. They should be built discreetly."*
    /// The UNet's job ends when the last latent lands. Holding it through the decode was the
    /// bug; letting it go is the design.
    ///
    /// Costs 4.3 s to reload on the next shot. That is the right trade here — *the latency is
    /// the film developing* — and a shot that finishes slowly beats a process that dies.
    func draw(_ drawing: Drawing, prompt: String, decoderPreference: DecoderChoice,
              onStep: (@Sendable (Int, Int) -> Void)? = nil) async throws -> CGImage {
        // ⭐ Mark's rule, 2026-07-16: *"building and tearing down the drawer each time... one
        // operation has its own world and all its resources from scratch."* This `defer`
        // makes teardown unconditional — however `draw` exits, throw or return, the drawer
        // does not survive it. On the happy path the body below has already released
        // everything and this is a no-op; on a throw mid-generation it is the teardown that
        // would otherwise be skipped, leaving 2.7 GB resident to crash the next op. All three
        // calls are synchronous, so they are legal in a `defer`.
        defer {
            MLX.Stream.gpu.synchronize()
            loaded = nil
            loadedID = nil
            MLX.Memory.clearCache()
        }

        // ⚠️ **Optionals, and every one of them is load-bearing.** The demo app's only comment
        // on this reads "Note: The optionals are used to discard parts of the model as it
        // runs" — which is easy to skim past and is in fact the entire mechanism.
        //
        // Measured: the first attempt at this used `let generator` and set `loaded = nil`
        // before decoding. The log said **"freed 0"** and the process died anyway. Dropping
        // the actor's reference does nothing while a local `let` in this very function still
        // holds the model. ARC frees on the *last* reference, not the first. So every handle
        // on the UNet has to be nilled, by hand, in order.
        var generator: TextToImageGenerator? = try await self.generator(for: drawing.repoID)
        let parameters = drawing.parameters(prompt: prompt)

        let started = Date()
        cameraLog("DRAW: begin steps=\(parameters.steps) cfg=\(parameters.cfgWeight) size=\(parameters.latentSize) seed=\(parameters.seed) prompt=\"\(prompt.prefix(120))\"")

        // Take the full-VAE decoder BEFORE anything is released. It closes over the autoencoder
        // alone — that is what makes it safe to throw the rest away. Tiled, because the monolithic
        // decode peaked ~4.5 GB and jetsammed the process here every time; tiling caps the peak at
        // one tile's share of the image (see `Drawing.decodeTileLatent`). Held as a `var` so it can
        // be dropped unused if we develop with TAESD instead — see the decode routing below.
        var vaeDecoder: ImageDecoder? = generator!.detachedTiledDecoder(
            tileLatent: Drawing.decodeTileLatent, overlapLatent: Drawing.decodeOverlapLatent)

        var latent: MLXArray?
        var step = 0
        var iterator: DenoiseIterator? = generator!.generateLatents(parameters: parameters)
        while let xt = iterator?.next() {
            latent = xt
            // MLX is lazy: the iterator hands back an unevaluated graph. Without this the
            // whole diffusion collapses into the final eval and every per-step number is a
            // fiction.
            eval(xt)
            step += 1
            onStep?(step, parameters.steps)
            cameraLog("DRAW: step \(step)/\(parameters.steps) at \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
        }

        guard let final = latent else { throw DrawingError.producedNothing }
        let denoiseSeconds = Date().timeIntervalSince(started)

        // Drop the UNet and the text encoder. Drain first — Metal command buffers from the
        // last step still reference these arrays, and releasing underneath them fires their
        // completion handlers against freed memory (SIGABRT). Same reason `unload()` drains.
        //
        // All three references, or none of it frees: the iterator (it holds the model to
        // step it), this function's handle, and the actor's cache.
        let beforeRelease = processAvailableMemoryMB()
        MLX.Stream.gpu.synchronize()
        iterator = nil
        generator = nil
        loaded = nil
        loadedID = nil
        MLX.Memory.clearCache()
        let afterRelease = processAvailableMemoryMB()
        // ⭐ Peak AT RELEASE, so the decode's contribution is isolatable. If mlxPeak here is
        // already the final peak, the spike was load/denoise (quantization helps). If it
        // climbs during the decode below, the spike is the VAE (only tiled decode helps).
        let atRelease = MLX.Memory.snapshot()
        cameraLog("DRAW: released the generator before decoding — iosAvailMB \(formatMB(beforeRelease)) → \(formatMB(afterRelease)) (freed \(formatMB(afterRelease - beforeRelease))) | mlxActive=\(String(format: "%.0f", Double(atRelease.activeMemory) / 1_048_576)) peakSoFar=\(String(format: "%.0f", Double(atRelease.peakMemory) / 1_048_576)) MB")

        // ── Choose the developer. ──
        //
        // Two user choices (`decoderPreference`), plus one non-negotiable: the decode never
        // crashes. Detailed develops with sd-turbo's own VAE, tiled to fit; Fast develops with the
        // tiny bundled TAESD. And whatever was chosen, if the device is too tight *this shot* to
        // afford even the tiled VAE decode, we fall back to TAESD rather than die — the promise the
        // Preferences footer makes plain. The VAE peak here is a device-tuning estimate
        // (`tiledDecodePeakMB`); TAESD's peak is a few hundred MB and effectively always fits.
        let availableMB = afterRelease
        let neededForVAE = Drawing.tiledDecodePeakMB + Drawing.decodeHeadroomMarginMB
        let useVAE = decoderPreference == .detailed && availableMB >= neededForVAE

        let decodeStarted = Date()
        let decoded: MLXArray
        if useVAE {
            decoded = vaeDecoder!(final)
            eval(decoded)
        } else {
            // Fast, or a Detailed shot this device can't afford. Release the VAE side entirely so
            // TAESD develops with maximum headroom, then decode with the tiny bundled model. Feed
            // it the RAW latent — TAESD applies no VAE scaling (see TAESD.swift).
            let why = decoderPreference == .fast
                ? "user chose Fast"
                : "Detailed, but availMB \(formatMB(availableMB)) < needed \(formatMB(neededForVAE)) — falling back so the shot still draws"
            cameraLog("DRAW: developing with TAESD (\(why))")
            vaeDecoder = nil
            MLX.Stream.gpu.synchronize()
            MLX.Memory.clearCache()
            let taesd = try TAESDDecoder.bundled()
            decoded = taesd.decodePixels(final)
            eval(decoded)
        }
        let decodeSeconds = Date().timeIntervalSince(decodeStarted)

        let snapshot = MLX.Memory.snapshot()
        cameraLog("DRAW: done denoise=\(String(format: "%.2f", denoiseSeconds))s decode=\(String(format: "%.2f", decodeSeconds))s total=\(String(format: "%.2f", Date().timeIntervalSince(started)))s | mlxPeak=\(String(format: "%.1f", Double(snapshot.peakMemory) / 1_048_576)) MB iosAvailMB=\(formatMB(processAvailableMemoryMB())) thermal=\(thermalStateLabel())")

        // The decoder returns floats in 0…1 with a leading batch dimension — `[1, 512, 512, 3]`.
        // `SDImage` wants 8-bit samples and `precondition(data.ndim == 3)`. Handing it the raw
        // decoder output trips that precondition and takes the process down with a signal 5,
        // **after** a perfectly good image has been computed — which is exactly what happened
        // on the first successful draw. Scale, cast, drop the batch dim. The library doesn't do
        // this for you; the demo app does it inline and it's easy to miss.
        //
        // `SDImage` is the vendored library's `Image`, renamed — it collided with SwiftUI's.
        // See Vendor/StableDiffusion/VENDOR.md.
        let raster = (decoded * 255).asType(.uint8).squeezed()
        eval(raster)
        let image = SDImage(raster).asCGImage()

        // The autoencoder goes too, now the pixels exist. Frame 3 is over.
        MLX.Stream.gpu.synchronize()
        MLX.Memory.clearCache()
        cameraLog("DRAW: frame 3 complete — iosAvailMB=\(formatMB(processAvailableMemoryMB()))")
        return image
    }
}

enum DrawingError: LocalizedError {
    case notInstalled(String)
    case notEnoughMemory(message: String)
    /// The frozen config named a drawer with no pipeline spec in this build — the loader refuses
    /// rather than guess. Shouldn't happen while sd-turbo is the only drawer; a guard for when
    /// a shot's drawer id outlives the code that knew how to load it.
    case unknownDrawer(String)
    case wrongKind
    case producedNothing
    /// A failure captured across the ModelLane boundary, where the original error type
    /// isn't Sendable, so its message is carried as a string.
    case drawFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let repo):
            return "\(repo) isn't downloaded yet. Get it in Preferences → Models → Browse Model Library."
        case .notEnoughMemory(let message):
            return message
        case .unknownDrawer(let repo):
            return "\(repo) isn't a drawer this app knows how to load."
        case .wrongKind:
            return "The drawer loaded, but not as something that can draw from text."
        case .producedNothing:
            return "The drawing finished with no image. That shouldn't happen — check the step count."
        case .drawFailed(let message):
            return message
        }
    }
}

// ==== LEGO END: 26 The Hand (Frame 3 — Drawing From Words) ====
