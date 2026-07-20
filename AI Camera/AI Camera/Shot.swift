//
//  Shot.swift
//  AI Camera
//
//  One press, all three frames — the heavy pipeline itself, in one place.
//
//  ── Why this is extracted ──
//
//  This is the exact sequence a shutter press runs: the eye sees, the eye is torn down, the
//  hand draws from the words. It lives here, alone, because **two things run it** — the live
//  shutter (`CameraView.develop`) and the antenna's `POST /shoot` — and they must run the
//  *same* code, not two copies that drift.
//
//  That mattered the moment it was written. On 2026-07-16 the drawing was proven with
//  `POST /draw`, which runs the drawer **in isolation** — no eye loaded, no photograph
//  resident. It worked. Then the shutter crashed, because the real path holds more: a
//  captured photograph, and whatever the eye hasn't finished giving back. Mark's question was
//  the right one — *"did you use the whole path or have it draw in isolation?"* — and the
//  answer was isolation. A measurement of the wrong thing is not neutral; it is persuasive
//  (HISTORY 2026-07-15). So the instrument that measures frame 3 now runs **this**, the whole
//  pipeline, not the drawer alone.
//

import CoreGraphics
import Photos
import UIKit

// ==== LEGO START: 30 The Shot (One Press, All Three Frames) ====

@MainActor
enum Shot {

    /// Into the camera roll, where the shot develops.
    ///
    /// Shared so the live shutter (`CameraView.develop`) and a remote press (`POST /press`)
    /// save the same way — a remote press is a real press and lands in Photos like one.
    ///
    /// - Returns: `true` only if the assets actually landed in Photos. The dark room queue leans
    ///   on this: a shot is deleted from the durable store ONLY when this returns `true`, so a
    ///   denied permission or a failed write leaves the shot on disk to retry rather than lost.
    @discardableResult
    static func save(_ images: [UIImage]) async -> Bool {
        guard !images.isEmpty else { return false }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                // One change block so the pair (photo + words, for "Separate images") lands
                // together, in order.
                for image in images {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                }
            }
            return true
        } catch {
            cameraLog("SAVE: Photos write failed — \(error.localizedDescription)")
            return false
        }
    }

    /// See, then draw from what was seen. Returns the words and the optional drawing.
    ///
    /// **Does NOT enter `ModelLane` itself** — the caller does, exactly once, so this is
    /// never double-entered. `CameraView.develop` wraps it in the lane; `POST /shoot` wraps
    /// it in the lane; both get one lane op per shot.
    ///
    /// ── Why the eye is torn down before the hand loads ──
    ///
    /// Mark's design, verbatim: *"at no point should the app maintain overhead from one frame
    /// into another."* Frame 2 is finished the moment the words exist. Holding 1.6 GB of Qwen
    /// through a 2.7 GB diffusion load asks the phone for 4.3 GB to do a job that needs 2.7,
    /// and iOS answers that by killing the app.
    ///
    /// ── Why a failed drawing is silent ──
    ///
    /// Frames 1 and 2 have already succeeded and are a complete photograph. If the drawing
    /// can't happen — no model, no memory — the shot still lands with the photograph and the
    /// words. Taking the whole frame down because the optional third panel failed would be the
    /// worst trade available. **This is not Principle 3 softened:** Principle 3 governs what
    /// the machine *says about a photograph*, not an engineering failure to allocate memory.
    /// - Returns: the perception, the optional drawing, and `wordsForHand` — the exact text the
    ///   hand was drawn from. That equals the full perception unless it had to be condensed to
    ///   fit the drawer; the caller uses it to honor `Settings.frameTwoShows` (show the chain
    ///   the hand actually received, or the eye's full words).
    /// Develops from a FROZEN `ShotConfig` — the settings captured at shutter-press — not from
    /// live `Settings`. That is the dark room queue's rule: a shot develops as it was configured
    /// when taken, however the user changes settings afterward.
    static func seeThenDraw(_ photograph: CGImage,
                            config: ShotConfig) async -> (perception: Perception, drawn: UIImage?, wordsForHand: String) {
        let seer = config.seer
        // ── Frame 2. The eye reads the world and says what it sees. ──
        let perception = await seer.look(at: photograph,
                                         systemPrompt: config.systemPrompt,
                                         temperature: config.temperature)

        // The full perception — always what frame 2 shows by default, and the fallback for
        // `wordsForHand` in every early return below.
        let fullWords = perception.wireText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard config.drawsThirdFrame else { return (perception, nil, fullWords) }

        // The hand draws from words. If the machine produced none — a filter blocked the
        // image, or the model declined — there is nothing to draw FROM. That outcome is
        // already recorded in frame 2; it is not a failure.
        guard !fullWords.isEmpty else { return (perception, nil, fullWords) }

        // ── Condense, but only if the words overrun the hand's budget. ──
        //
        // The drawer's text encoder (CLIP) reads ~75 tokens and no more; a longer prompt used
        // to *crash* the app (VENDOR.md #3), and the tokenizer's hard truncation is now the
        // floor beneath this. But truncation CHOPS — it hands the drawer the front of a
        // sentence. So first we ask the SAME eye that saw to say the same thing in fewer words
        // (Mark's call, 2026-07-16: summarize, don't truncate). Only when over budget, and only
        // now, while the eye is still resident. On failure we pass the full words on and let the
        // hard cap catch them — the belt stays buckled, we just try not to need it.
        var wordsForHand = fullWords
        if PromptBudget.exceedsDrawerBudget(fullWords),
           let shorter = await seer.condense(fullWords, toAtMostWords: PromptBudget.condenseTargetWords,
                                             systemPrompt: config.systemPrompt, temperature: config.temperature) {
            cameraLog("CONDENSE: \(PromptBudget.wordCount(fullWords)) words → \(PromptBudget.wordCount(shorter)) for the hand")
            wordsForHand = shorter
        }

        // The hand takes ONLY the eye's words — no style, no framing, pure information. A
        // user-facing "art direction" style prompt was built and then deliberately removed
        // (2026-07-16): inserting one puts a human's aesthetic into a machine→machine chain and
        // changes what the drawer perceives the eye to have seen. Parked in NEXT as an opt-in
        // mode, clearly outside the pure chain.
        let prompt = wordsForHand

        // Frame 2 is over. Let the eye go before the hand arrives.
        await QwenLoader.shared.unload()

        // How big to save it, with which upscaler, and which developer — from the frozen config.
        let size = config.drawingSize
        let method = config.upscaler
        let decoderPreference = config.decoderChoice

        // ── Frame 3. The hand draws what the eye said. ──
        do {
            let drawn = try await DrawerLoader.shared.draw(
                Drawing(), prompt: prompt, decoderPreference: decoderPreference)
            // Frame 3's model is over. Tear it down BEFORE upscaling, so the upscale (which
            // uses the GPU too) runs with the drawer's memory already returned. (The drawer
            // also tears itself down in `draw`'s `defer` — this is belt to that braces.)
            await DrawerLoader.shared.unload()
            // Enlarge after the draw — cheap, and it never touched the VAE spike. `.native`
            // returns the 512² unchanged.
            let sized = Upscaler.enlarge(drawn, to: size, method: method)
            return (perception, UIImage(cgImage: sized), wordsForHand)
        } catch {
            cameraLog("DRAW: frame 3 skipped — \(error.localizedDescription)")
            await DrawerLoader.shared.unload()
            return (perception, nil, wordsForHand)
        }
    }
}

/// Whether the eye's words will overrun the hand's prompt budget — the trigger for
/// condensation (`Eye.condense` / `Qwen.condense`).
///
/// **Word count, not exact CLIP tokens.** Mark's call for round one (2026-07-16); wiring the
/// drawer's real CLIP tokenizer in here is a parked upgrade (see NEXT) that would let us
/// condense *only* when strictly necessary. The drawer's CLIP encoder holds 75 content tokens;
/// English descriptive prose runs very roughly 1.3–1.5 tokens per word, so ~50 words is the
/// real ceiling. We trip well below it (45) and aim the condenser comfortably under (35), on
/// purpose: **Mark wants truncation to be a genuine last resort**, so we'd rather condense a
/// borderline shot that would have just fit than let the hard cap ever chop one. The cost is a
/// short extra pass on wordy shots; the exact-tokenizer upgrade is what removes the guesswork.
enum PromptBudget {
    /// Above this many words, condense before handing off to the drawer.
    static let triggerWords = 45
    /// What the condenser aims for — safely under CLIP's 75 tokens even at a high token/word
    /// ratio.
    static let condenseTargetWords = 35

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
    static func exceedsDrawerBudget(_ text: String) -> Bool {
        wordCount(text) > triggerWords
    }
}

// ==== LEGO END: 30 The Shot (One Press, All Three Frames) ====
