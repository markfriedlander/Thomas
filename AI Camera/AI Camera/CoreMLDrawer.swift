//
//  CoreMLDrawer.swift
//  AI Camera
//
//  Frame 3, the second hand — the machine re-imagining the scene on the **Neural Engine**.
//
//  ── Why a second engine exists ──
//
//  The first hand (`Drawing` / `DrawerLoader`) draws sd-turbo through MLX on the GPU. It works,
//  but a diffusion load costs ~2.7 GB resident and runs the GPU hot. On 2026-07-26 a throwaway
//  spike proved a different path: Apple's `ml-stable-diffusion` package running SD-2.1-base
//  (palettized, the `split_einsum_v2` build) with `.cpuAndNeuralEngine`. Measured on an iPhone 16
//  Plus: peak ~800 MB (about a third of MLX), ~11 s a shot once warm, cooler. This file is that
//  spike, productized — the runner moved in, the ad-hoc downloader dropped in favor of the real
//  shared-store plumbing (`MLXModelDownloader`, the same one sd-turbo uses).
//
//  ── The Neural Engine is the point, and it costs one thing up front ──
//
//  `.cpuAndNeuralEngine` is not a knob to soften when it's inconvenient — it is the entire reason
//  to run CoreML here (efficiency, heat, memory). The one price it charges: the FIRST draw after
//  install compiles the model for this exact device's Neural Engine — a one-time ~190 s cost, its
//  result cached by the OS outside our sandbox, so every later draw pays only the fast ~11 s. That
//  compile is why a draw keeps the screen awake while it runs (below): a foregrounded user carries
//  it to completion instead of the OS suspending us mid-compile. (A future improvement, parked in
//  NEXT: warm that compile at install/selection rather than on the first shot.)
//
//  ── Same discipline as the MLX hand ──
//
//  Load, draw, unload — every shot. Mark's rule holds across both engines: *"at no point should the
//  app maintain overhead from one frame into another."* The eye is already torn down before either
//  hand loads (`Shot.seeThenDraw`), so this loads into a freed device. And like the MLX hand it
//  never sees the photograph — it reads only what the eye said. The gap is the art.
//

import Foundation
import CoreML
import CoreGraphics
import UIKit
import SharedModelStoreKit
import StableDiffusion

// ==== LEGO START: 36 The CoreML Hand (Frame 3 On The Neural Engine) ====

/// Draws frame 3 on the Neural Engine, via Apple's `ml-stable-diffusion` package.
///
/// An actor, so its heavy synchronous `generateImages` runs off the main thread on a serial
/// executor — one draw at a time, which is what we want (one big model resident at a time). Loads
/// and unloads per draw; there is no resident-model cache to manage because there is no model kept
/// between shots. Deliberately simpler than `DrawerLoader`, which juggles a resident MLX generator.
actor CoreMLDrawer {
    static let shared = CoreMLDrawer()

    /// Where the package loads its `.mlmodelc` bundles from: the model's shared-store folder, then
    /// down into the delivered subtree (`split_einsum_v2/compiled/`). The download preserves
    /// repo-relative paths, so the Neural-Engine build lands exactly here. Keyed by the shared-store
    /// key — the version-stamped identity (`repo@<sha>`) for this pinned, non-`plainFolderRepos`
    /// drawer, same as Qwen — so a re-pin would land in its own folder and never be confused.
    nonisolated static func resourcesDir(for repoID: String) -> URL {
        let modelDir = SharedModelStore.mlxModelDir(sharedStoreKey(forRepoID: repoID))
        let prefix = ModelCatalog.model(id: repoID)?.folderPrefix ?? ""
        return prefix.isEmpty ? modelDir : modelDir.appendingPathComponent(prefix, isDirectory: true)
    }

    /// True while a load+draw is in flight, so a pre-warm and a real shot can't both try to load
    /// at once. (The actor already serializes calls; this just lets `prewarm` bow out early instead
    /// of queueing behind a real draw that's already doing the warming for it.)
    private var busy = false

    /// Whether we've already pre-warmed in THIS process. In-memory, not persisted, so it resets on
    /// every launch — see `prewarm` for why per-launch is the right granularity.
    private var prewarmedThisLaunch = false

    /// Pre-warm the Neural-Engine hand, in the background, so the user's FIRST real shot doesn't pay
    /// the one-time load + compile + program-warm (~83 s cold; HISTORY 2026-07-27). The analog of
    /// "warming up" an LLM: one throwaway 1-step draw whose only purpose is to get the model loaded
    /// and running on the Neural Engine once, so the real shot after it is fast. The image is discarded.
    ///
    /// **Once per LAUNCH, not once per install** (Mark, 2026-07-27). Even if iOS keeps the compiled
    /// model artifact on disk between launches, a freshly-started process still has to load the model
    /// and wake it on the Neural Engine — that per-process cost is exactly what the first real shot
    /// would otherwise eat — so warming every launch is the robust rule and betting on a persistent
    /// compile is not. Guarded by an in-memory flag (resets each launch) plus the `busy` check, so
    /// the launch trigger and the download-complete trigger together warm at most once per process,
    /// and it bows out if the model isn't downloaded or a real draw is already doing the warming.
    /// Reuses `draw` wholesale — same load, same teardown — so there is no second copy of the load
    /// path to drift.
    func prewarm(repoID: String) async {
        if prewarmedThisLaunch { return }
        guard FileManager.default.fileExists(
            atPath: Self.resourcesDir(for: repoID).appendingPathComponent("Unet.mlmodelc").path) else { return }
        if busy { return }
        cameraLog("COREML: pre-warming \(repoID) in the background — one throwaway draw to load + wake the Neural Engine")
        do {
            _ = try await draw(repoID: repoID, prompt: "a gray sphere on a plain background", steps: 1)
            prewarmedThisLaunch = true
            cameraLog("COREML: pre-warm complete — the first real shot this launch now skips the warm-up")
        } catch {
            // Harmless: the flag stays unset, so a later trigger this launch (or the first real shot)
            // still warms it.
            cameraLog("COREML: pre-warm did not complete (fine — the first shot will warm it): \(error.localizedDescription)")
        }
    }

    /// Draw. Words in, a picture out. Throws rather than returning nil, so `Shot` can log the reason
    /// and land the shot with the frames that succeeded intact (a failed hand is silent by design —
    /// see `Shot.seeThenDraw`).
    ///
    /// Two modes, one method:
    ///   - **Text-to-image** (the normal chain): `startingImage == nil`. The hand draws from the
    ///     eye's words alone and never sees the photograph.
    ///   - **Image-to-image** (the SILENT LOOP, eye off): a photograph is passed in, so the hand
    ///     reads reality directly and re-imagines it, nudged by an optional short `prompt`. This is
    ///     the "different gap" — what the machine chooses to carry forward from the image itself.
    ///     Only the CoreML hand can do this (the package supports it and our model ships the VAE
    ///     encoder); the MLX hand is text-in only.
    ///
    /// - Parameters:
    ///   - repoID: the CoreML drawer's repo id (its resources come from `resourcesDir(for:)`).
    ///   - prompt: the words that steer the draw — the eye's words in the normal chain, or the small
    ///     hand prompt in the silent loop (may be empty there — the image alone still steers it).
    ///   - steps: denoising steps, frozen per-shot from the step knob (`ShotConfig.drawSteps`).
    ///   - startingImage: the photograph, for the silent loop. `nil` for the normal text-only chain.
    ///   - strength: how far to transform the starting image, 0→barely touched, 1→fully reimagined.
    ///     Clamped below 1.0 because the package treats strength ≥ 1.0 as "ignore the image." Unused
    ///     when `startingImage` is nil.
    func draw(repoID: String, prompt: String, steps: Int,
              startingImage: CGImage? = nil, strength: Float = 1.0) async throws -> CGImage {
        let dir = Self.resourcesDir(for: repoID)
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("Unet.mlmodelc").path) else {
            throw CoreMLDrawError.notInstalled(repoID)
        }
        // Mark the actor busy for the whole load+draw, so a background `prewarm` bows out instead of
        // queueing behind a real shot that's already warming the compile. Cleared however we exit.
        busy = true
        defer { busy = false }

        // Keep the screen awake for the duration of THIS draw only (defer restores it). The first
        // draw's Neural-Engine compile is long (~190 s); a foregrounded user shouldn't have the
        // screen lock and let the OS suspend the compile out from under the shot. Scoped, so a
        // normal ~11 s draw doesn't hold the screen open any longer than it runs.
        await MainActor.run { UIApplication.shared.isIdleTimerDisabled = true }
        defer { Task { @MainActor in UIApplication.shared.isIdleTimerDisabled = false } }

        let started = Date()
        let availBefore = processAvailableMemoryMB()

        // `.cpuAndNeuralEngine` — the whole reason this hand exists. Do not soften it.
        let mlConfig = MLModelConfiguration()
        mlConfig.computeUnits = .cpuAndNeuralEngine
        cameraLog("COREML: loading \(repoID) on the Neural Engine (first draw after install compiles, ~190s once) availMB=\(formatMB(availBefore))")

        // `reduceMemory: true` is not optional on a phone: it streams the sub-models in and out
        // rather than holding them all resident, which is how the peak stays ~800 MB.
        let pipeline = try StableDiffusionPipeline(resourcesAt: dir,
                                                   controlNet: [],
                                                   configuration: mlConfig,
                                                   reduceMemory: true)
        try pipeline.loadResources()
        // However this draw exits — success, throw, or the guard below — the model does not survive
        // it. Symmetry with the MLX hand's teardown `defer`.
        defer { pipeline.unloadResources() }

        let availLoaded = processAvailableMemoryMB()
        cameraLog("COREML: loaded \(repoID) in \(String(format: "%.1f", Date().timeIntervalSince(started)))s — drawing \(steps) steps | availMB \(formatMB(availBefore)) → \(formatMB(availLoaded))")

        var config = StableDiffusionPipeline.Configuration(prompt: prompt)
        config.stepCount = steps
        // SD-2.1 base is NOT a distilled turbo model — it needs classifier-free guidance to track
        // the prompt. (The MLX hand's sd-turbo sets cfg 0 for the opposite reason; different model.)
        config.guidanceScale = 7.5
        config.imageCount = 1
        // A fresh seed each press, so the same words don't always draw the identical picture — the
        // MLX hand is random per shot too (`Drawing.sdTurbo.seed == nil`). App code, so `random` is
        // fine here (the restriction is on workflow scripts, not the app).
        config.seed = UInt32.random(in: 0...UInt32.max)
        // No safety filter on the hand — Principle 3. The eye is unguarded (Qwen/Smol) and the hand
        // draws what the eye said, unhedged; a filter here would be the app apologizing for a
        // perception it should simply state. (Also skips loading the safety model — less memory.)
        config.disableSafety = true

        // ── Silent loop: feed the photograph in. ──
        // Resized to the model's native 512² (center-cropped square first), the size the VAE encoder
        // expects. Strength kept strictly below 1.0 so the package stays in image-to-image mode
        // (`PipelineConfiguration.mode` flips to text-only at strength ≥ 1.0). Higher = more
        // transformation; the actual denoise steps run become steps × strength.
        if let start = startingImage {
            config.startingImage = Self.square512(start) ?? start
            config.strength = min(max(strength, 0.05), 0.95)
            cameraLog("COREML: SILENT LOOP (image-to-image) strength=\(config.strength) prompt=\"\(prompt.prefix(60))\"")
        }

        let drawStarted = Date()
        var stepN = 0
        let images = try pipeline.generateImages(configuration: config) { _ in
            stepN += 1
            cameraLog("COREML: step \(stepN) at \(String(format: "%.1f", Date().timeIntervalSince(drawStarted)))s availMB=\(formatMB(processAvailableMemoryMB()))")
            return true
        }

        guard let cg = images.first ?? nil else {
            throw CoreMLDrawError.producedNothing
        }
        cameraLog("COREML: DONE \(repoID) total=\(String(format: "%.1f", Date().timeIntervalSince(started)))s draw=\(String(format: "%.1f", Date().timeIntervalSince(drawStarted)))s availMB=\(formatMB(processAvailableMemoryMB())) thermal=\(thermalStateLabel())")
        return cg
    }
}

extension CoreMLDrawer {
    /// Center-crop to square, then scale to the model's native 512×512 — the size the VAE encoder
    /// expects for the silent loop's starting image. The photograph is arbitrary aspect; this makes
    /// it the drawer's shape (the same "the hand's ratio wins" rule the square layouts use).
    nonisolated static func square512(_ image: CGImage) -> CGImage? {
        let side = 512
        let w = image.width, h = image.height
        let m = min(w, h)
        guard let cropped = image.cropping(to: CGRect(x: (w - m) / 2, y: (h - m) / 2, width: m, height: m)),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: side, height: side))
        return ctx.makeImage()
    }
}

enum CoreMLDrawError: LocalizedError {
    case notInstalled(String)
    case producedNothing

    var errorDescription: String? {
        switch self {
        case .notInstalled(let repo):
            return "\(repo) isn't downloaded yet. Get it in Preferences → Models → Browse Model Library."
        case .producedNothing:
            return "The Neural-Engine drawing finished with no image. That shouldn't happen — check the step count."
        }
    }
}

/// Delete the throwaway CoreML spike's leftover model, if any. The spike (2026-07-26, since removed)
/// downloaded its ~1 GB model to `<Application Support>/coreml-spike/` in a flattened layout the
/// production hand can't load from — so it's pure orphaned weight once the spike is gone. Called
/// once per launch off-main (`AI_CameraApp.init`). Idempotent: after the first reap there's nothing
/// to find, and on a device that never ran the spike the directory never existed.
nonisolated func reapCoreMLSpikeLeftovers() {
    let fm = FileManager.default
    guard let appSup = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
    let dir = appSup.appendingPathComponent("coreml-spike", isDirectory: true)
    guard fm.fileExists(atPath: dir.path) else { return }
    do {
        try fm.removeItem(at: dir)
        cameraLog("COREML: reaped the retired evaluation spike's leftover model dir (reclaimed its space)")
    } catch {
        cameraLog("COREML: could not reap spike leftovers at \(dir.path): \(error.localizedDescription)")
    }
}

// ==== LEGO END: 36 The CoreML Hand (Frame 3 On The Neural Engine) ====
