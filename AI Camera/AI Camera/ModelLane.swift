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
import Synchronization
import UIKit

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
            await self.waitForBeside()
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

    // MARK: Beside the lane

    /// Small GPU jobs running beside a Neural-Engine drawing (the live step previews). The Core ML hand
    /// leaves the GPU idle, so a preview may decode while it draws without waiting the whole drawing; but
    /// it must be done before the next lane operation starts, or two GPU jobs overlap (review round 3,
    /// 2026-11-14: the previews ran outside the lane and could overlap the next shot's eye).
    private var besideCount = 0

    /// Run a small GPU job beside the lane's current Neural-Engine operation. Callers decide it is that
    /// moment (a Core ML drawing in progress); the next lane operation waits for this to finish.
    func runBeside<T: Sendable>(_ work: @Sendable () async -> T) async -> T {
        besideCount += 1
        defer { besideCount -= 1 }
        return await work()
    }

    private func waitForBeside() async {
        while besideCount > 0 { try? await Task.sleep(nanoseconds: 30_000_000) }
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
        // MLX cannot create its GPU device in the Simulator and aborts the app; the Simulator is only
        // used to check layouts (2026-11-13), and runs no MLX model, so there is nothing to drain.
        #if !targetEnvironment(simulator)
        MLX.Stream.gpu.synchronize()
        MLX.Memory.clearCache()
        #endif
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

/// Whether heavy model work may take its next step right now: the app's foreground state, readable
/// from any thread, checked between drawing steps and between the eye's words.
///
/// WHY (independent review, round 3, 2026-11-14). iOS refuses GPU work from an app in the background,
/// and a refused MLX command fails inside MLX, which takes the app down. The old safety (2026-07-21)
/// let the operation in flight finish inside the background grace window before abandoning the shot,
/// but an MLX operation in flight IS GPU work, and a whole look or drawing can outlast the window. So
/// the work now stops itself at the next step instead:
///   - **inactive** (the screen is locking, Control Center, a call coming in): GPU work waits between
///     steps, so nothing is mid-flight when the app reaches the background. If the app comes straight
///     back (a glance at Control Center), the step goes on and nothing is lost.
///   - **background**: the work stops; the Dark Room leaves the shot queued and develops it whole on
///     return, as before.
/// On a Mac (Designed for iPad) another window in front makes Thomas inactive, and macOS allows GPU work
/// then, so a Mac only stops for the background.
nonisolated enum ForegroundGate {
    enum State: Int, Sendable { case active = 0, inactive = 1, background = 2 }

    private static let state = Atomic<Int>(State.active.rawValue)
    private static let started = Atomic<Bool>(false)

    static var current: State { State(rawValue: state.load(ordering: .relaxed)) ?? .active }

    /// True once the app is in the background: whatever is running should stop at its next step.
    static var isLeaving: Bool { current == .background }

    /// Follow the app's state from now on: the starting state, then each change. Once, at launch.
    @MainActor static func start() {
        guard !started.exchange(true, ordering: .relaxed) else { return }
        set(from: UIApplication.shared.applicationState)
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in set(.active) }
        nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: nil) { _ in set(.inactive) }
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in set(.background) }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { _ in set(.inactive) }
    }

    @MainActor static func set(from appState: UIApplication.State) {
        switch appState {
        case .active: set(.active)
        case .background: set(.background)
        default: set(.inactive)
        }
    }

    static func set(_ s: State) {
        let before = state.exchange(s.rawValue, ordering: .relaxed)
        if before != s.rawValue { cameraLog("GATE: \(State(rawValue: before).map { "\($0)" } ?? "?") -> \(s)") }
    }

    /// Call between GPU steps. Waits while the app is inactive (on a phone), and returns false once it
    /// is in the background, meaning "stop now and abandon".
    static func mayContinue() async -> Bool {
        if !ProcessInfo.processInfo.isiOSAppOnMac {
            while current == .inactive { try? await Task.sleep(nanoseconds: 100_000_000) }
        }
        return current != .background
    }

    /// For work that can't wait between steps (the eye's words arrive from a stream that keeps going):
    /// true while it may keep running. On a phone it must stop as soon as the app is inactive.
    static var mayRunGPU: Bool {
        ProcessInfo.processInfo.isiOSAppOnMac ? current != .background : current == .active
    }
}

// ==== LEGO END: 9 The Model Lane (Serialization + Settle) ====
