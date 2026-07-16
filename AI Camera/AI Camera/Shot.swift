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
    static func save(_ images: [UIImage]) async {
        guard !images.isEmpty else { return }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return }
        try? await PHPhotoLibrary.shared().performChanges {
            // One change block so the pair (photo + words, for "Separate images") lands
            // together, in order.
            for image in images {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
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
    static func seeThenDraw(_ photograph: CGImage,
                            seer: Seer,
                            drawThird: Bool) async -> (perception: Perception, drawn: UIImage?) {
        // ── Frame 2. The eye reads the world and says what it sees. ──
        let perception = await seer.look(at: photograph)

        guard drawThird else { return (perception, nil) }

        // The hand draws from words. If the machine produced none — a filter blocked the
        // image, or the model declined — there is nothing to draw FROM. That outcome is
        // already recorded in frame 2; it is not a failure.
        let words = perception.wireText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return (perception, nil) }

        // Frame 2 is over. Let the eye go before the hand arrives.
        await QwenLoader.shared.unload()

        // ── Frame 3. The hand draws what the eye said. ──
        do {
            let image = try await DrawerLoader.shared.draw(Drawing(), prompt: words)
            // Frame 3 is over too. Nothing carries into the next shot; the next press reloads
            // the eye, the same path a cold start takes. (The drawer also tears itself down in
            // `draw`'s `defer` — this is belt to that braces.)
            await DrawerLoader.shared.unload()
            return (perception, UIImage(cgImage: image))
        } catch {
            cameraLog("DRAW: frame 3 skipped — \(error.localizedDescription)")
            await DrawerLoader.shared.unload()
            return (perception, nil)
        }
    }
}

// ==== LEGO END: 30 The Shot (One Press, All Three Frames) ====
