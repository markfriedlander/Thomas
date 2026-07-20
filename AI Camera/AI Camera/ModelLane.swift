//
//  ModelLane.swift
//  Thomas / AI Camera
//
//  The single lane every heavy model operation passes through — one at a time, with the phone
//  let to settle between each. This is core app machinery (the memory-safety spine), NOT a debug
//  tool: the real shutter path (`DarkRoomWorker`) and the antenna both run through it. It lived
//  inside the DEBUG-only antenna file for historical reasons (it was born during the crash-fixing
//  work, which happened through the antenna) and moved here 2026-07-20 so the shipping app — which
//  cannot function safely without it — actually compiles and contains it. Only the doorway (the
//  listener + its commands) stays DEBUG-only; everything the app DOES, including this, ships.
//

import Foundation
import MLX   // Stream.gpu.synchronize(), Memory.clearCache() — the settle

// ==== LEGO START: 9 The Model Lane (Serialization + Settle) ====

/// The single lane every heavy model operation passes through, one at a time, with the
/// phone let to settle between each.
///
/// ⚠️ This exists instead of a note telling you to pace your calls.
///
/// **Mark's rule, 2026-07-16, and it is the whole design of this file:** *"we should be
/// drawing one at a time in sequence. We should also be building and tearing down the drawer
/// each time. Give it time to settle between as well just the same way we move between frames
/// or if you look at Hal between prompts. This is how we make sure that one operation has its
/// own world and all its resources from scratch."*
///
/// It started life as `LookQueue`, serializing only AFM looks (the Foundation Models SDK has
/// a `concurrentRequests` error — AFM rejects overlapping sessions outright). **That was not
/// enough, and the gap crashed the app.** Measured 2026-07-16: two draws fired at once, or a
/// draw started while the eye was still resident, jetsams the process (signal 9) — a
/// 2.7 GB diffusion load has no room to run twice. Looks were serialized; **draws were not**,
/// and neither the shutter's own looks nor either engine's draws shared a lane. So this is
/// now the lane for *everything* heavy: every look and every draw, from the shutter and from
/// the antenna alike.
///
/// Two guarantees:
///   1. **One at a time.** FIFO. A second caller queues behind the first rather than racing
///      it. The actor only protects `tail`; the serialization is the task chaining. (A bare
///      `actor` would NOT do this — actors are re-entrant across `await` and would let a
///      second op start mid-suspension, which is exactly the bug.)
///   2. **Settle between.** After each op finishes, drain the GPU, clear MLX's cache, and
///      **poll until iOS has actually reclaimed the memory** before the next op starts. Not
///      a guessed sleep — the same measured wait Hal does between model swaps
///      (`waitForMemoryHeadroom`). Every op therefore begins in a clean world: whatever ran
///      before it is not merely released but *reclaimed*.
actor ModelLane {
    static let shared = ModelLane()

    /// Completes when everything enqueued so far has finished (including its settle).
    private var tail: Task<Void, Never> = Task {}

    /// Run `work` once every previously-enqueued item has finished, then settle before the
    /// lane is handed to the next caller. FIFO.
    ///
    /// - Parameter label: names the op in the log, so the sequence reads as a story —
    ///   `look` … `settle` … `draw` … `settle` — rather than anonymous waits.
    func run<T: Sendable>(_ label: String, _ work: @Sendable @escaping () async -> T) async -> T {
        let previous = tail
        let mine = Task<T, Never> {
            await previous.value
            // Thermal guard: if the phone is hot, hold here — after the previous shot has
            // finished and settled — until it cools, rather than stacking another heavy draw
            // onto the heat. No-op when cool; cancellable, so a stop is never stuck behind it.
            await ThermalGovernor.shared.pace()
            let result = await work()
            // The settle is part of the op, not a courtesy after it: the next caller must
            // not begin until this one's world is not just dropped but reclaimed.
            await Self.settle(after: label)
            return result
        }
        // Update the tail synchronously, before any suspension, so a second caller entering
        // `run` queues behind `mine` (and its settle) rather than racing it.
        tail = Task { _ = await mine.value }
        return await mine.value
    }

    /// Let the phone settle: drain GPU work, release MLX's cache, and wait for iOS to give
    /// the memory back, so the next operation starts from scratch.
    ///
    /// iOS reclaims Mach VM lazily. Measured 2026-07-16, the reclaim is usually fast (a Qwen
    /// teardown returned ~1.6 GB in 79 ms) — but *usually* is not *always*, and the whole
    /// point of settling is that the next 2.7 GB load never races a reclaim that hasn't
    /// finished. So this polls until availability plateaus (two reads within 50 MB) rather
    /// than trusting a fixed delay. Bounded, because a settle that never ends is worse than a
    /// settle that's a little early.
    private static func settle(after label: String) async {
        MLX.Stream.gpu.synchronize()
        MLX.Memory.clearCache()
        let start = Date()
        let deadline = start.addingTimeInterval(2.0)
        var last = processAvailableMemoryMB()
        var plateaus = 0
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 150_000_000)
            let now = processAvailableMemoryMB()
            // A plateau: the reclaim has stopped climbing. Two in a row = settled.
            if abs(now - last) < 50 {
                plateaus += 1
                if plateaus >= 2 { break }
            } else {
                plateaus = 0
            }
            last = now
        }
        cameraLog("LANE: settled after \(label) — availableMB=\(formatMB(processAvailableMemoryMB())) in \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
    }
}

// ==== LEGO END: 9 The Model Lane (Serialization + Settle) ====
