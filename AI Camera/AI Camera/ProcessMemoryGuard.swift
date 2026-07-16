//
//  ProcessMemoryGuard.swift
//  AI Camera
//
//  Lifted from Hal Universal's `ProcessMemoryGuard.swift` (block 39) on 2026-07-15, at
//  Mark's instruction. His words, and the reason this file exists: *"I basically told the
//  previous cc that it essentially didn't have to write a fucking thing just copy the
//  fucking code from one app to the new app."* That ask was made on day one and not done.
//  AI Camera shipped with `Qwen.unload()` as a one-line stub — `loaded = nil` — wired to
//  nothing. Hal has spent two years learning why that isn't enough. This is that learning,
//  carried across rather than re-derived.
//
//  ── What the phone actually does, since this is the part that isn't obvious ──
//
//  Letting go of a model does not give the memory back. iOS reclaims Mach VM lazily — it
//  gets around to it. So dropping one model and immediately loading the next can get the
//  process killed *during the handoff*, holding neither model, dead anyway. That is the
//  single most dangerous moment in Mark's three-frame design (capture → words → drawing),
//  where every frame tears down before the next loads. This file is what makes a handoff
//  survivable: ask the OS how much room is *really* free, and wait until it is.
//
//  Two mechanisms, both Hal's:
//
//    1. Pre-flight refusal — check headroom against the model's requirement BEFORE the
//       loader mmaps weights and faults pages. A refusal the user can read beats a
//       process iOS terminates without comment.
//    2. Headroom poll — poll every ~150 ms until the target is met or we time out, so the
//       reclamation curve is *visible* rather than guessed at. Hal's swap path used to
//       sleep a fixed 500 ms and hope.
//
//  ── Where this deliberately differs from Hal ──
//
//  Hal estimates a model's size from its download catalog (`ModelConfiguration.sizeGB`),
//  because Hal downloads models and knows what it ordered; on a catalog miss it assumes
//  2.5 GB. AI Camera adopts whatever the family already fetched, so it can read the
//  **actual bytes on disk** via `SharedModelStore.sizeOnDisk`. Same formula, better input
//  — not cleverness, just a difference in the two apps' natures. The estimate path
//  survives for callers who have no repo yet (a model being sized before download).
//
//  ⚠️ The 0.75 ratio is calibrated for **4-bit quantized safetensors loaded via mmap**
//  (Hal's note). Qwen3.5-2B-MLX-4bit is exactly that, so it transfers unchanged. A
//  diffusion model for frame 3 is a different shape — fp16/fp32 weights, a different
//  residency pattern — and **this ratio should be re-measured before it is trusted there.**
//  Do not assume it carries. Measure it, the way Hal measured this one.
//

import Foundation
#if canImport(Darwin)
import Darwin
#endif

// ==== LEGO START: 25 ProcessMemoryGuard (Load-Time Memory Headroom) ====

// MARK: - Logging
//
// AI Camera had no logging of any kind before this file. Hal routes `halLog` through a
// RuntimeLog buffer the API can serve; AI Camera's antenna has no such buffer yet, so this
// keeps a small in-memory ring and `GET /memory` serves it (block 12). Without somewhere to
// read the reclamation curve, porting the poll would be decorative — the curve IS the
// instrument, and CLAUDE.md is explicit that an instrument beats a third guess.
//
// `nonisolated` + `@unchecked Sendable` with a lock, mirroring Hal's RuntimeLog: the
// project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so a plain top-level function
// would become implicitly `@MainActor` and break every off-main call site — which is all of
// them, since loads and unloads happen off the main actor by design.

/// A small ring of recent memory-log lines, readable through the antenna.
///
/// `nonisolated` on the **type**, not just on the methods. The methods were already marked
/// nonisolated — correctly, since every caller is off the main actor — but the stored
/// properties were left to the project's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
/// default, which made them `@MainActor` and left `log()` unable to touch its own storage.
/// That is six warnings, and this project treats warnings as errors. The `NSLock` is what
/// actually makes this safe, which is what `@unchecked Sendable` is asserting.
nonisolated final class MemoryLog: @unchecked Sendable {
    static let shared = MemoryLog()

    private let lock = NSLock()
    private var lines: [String] = []
    private let limit = 400

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    nonisolated func log(_ message: String) {
        let stamped = "\(formatter.string(from: Date())) \(message)"
        lock.lock()
        lines.append(stamped)
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
        lock.unlock()
        print(stamped)
    }

    /// Most recent lines, oldest first.
    nonisolated func recent(_ count: Int = 200) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(lines.suffix(count))
    }

    nonisolated func clear() {
        lock.lock()
        lines.removeAll()
        lock.unlock()
    }
}

/// AI Camera's `halLog`. Same job, same reason: `print` alone vanishes when the app runs
/// off a device install rather than from Xcode, which is Mark's actual workflow.
@inline(__always)
nonisolated func cameraLog(_ message: String) {
    MemoryLog.shared.log(message)
}

// MARK: - Process memory introspection

/// Bytes the process can still allocate before iOS terminates it, in MB.
///
/// Returns `.infinity` where the API isn't available (macOS), so callers **fail open** —
/// a guard that blocks loads on an unsupported platform is worse than no guard.
@inline(__always)
nonisolated func processAvailableMemoryMB() -> Double {
    #if !os(macOS)
    let bytes = os_proc_available_memory()
    if bytes == 0 { return .infinity }  // 0 = unsupported / already over the limit
    return Double(bytes) / (1024.0 * 1024.0)
    #else
    return .infinity
    #endif
}

// MARK: - Required-memory estimate

/// Effective dirty-memory ratio for 4-bit quantized safetensors loaded via mmap. Hal's
/// figure, hard-won. Covers tokenizer/vocab residency and the first prefill's scratch.
nonisolated private let dirtyMemoryRatio: Double = 0.75

/// Safety margin in MB above the process baseline and iOS's dirty-memory cliff. Hal's.
nonisolated private let safetyMarginMB: Double = 250.0

/// Conservative fallback when a size is genuinely unknown. Hal's.
nonisolated private let assumedSizeGB: Double = 2.5

/// Estimated MB the process needs available to load a model of `sizeGB`.
///
///     sizeGB * 1024 * 0.75 + 250
///
/// Pass `nil` only when the size is truly unknowable; the 2.5 GB assumption is a guess and
/// is labelled as one in the log.
nonisolated func requiredMemoryMBForLoad(sizeGB: Double?) -> Double {
    let gb = sizeGB ?? assumedSizeGB
    return gb * 1024.0 * dirtyMemoryRatio + safetyMarginMB
}

/// The same estimate, computed from a repo's **actual bytes on disk** rather than a
/// catalog figure. This is the path AI Camera should use for anything already in the
/// shared store — it is measured, not declared.
///
/// Returns the `nil`-size estimate if the repo isn't present (nothing to measure).
nonisolated func requiredMemoryMBForLoad(repo: String) -> Double {
    let bytes = SharedModelStore.sizeOnDisk(repo)
    guard bytes > 0 else { return requiredMemoryMBForLoad(sizeGB: nil) }
    // GiB, matching how iOS accounts for pages — sizeOnDisk returns real bytes.
    let gb = Double(bytes) / (1024.0 * 1024.0 * 1024.0)
    return requiredMemoryMBForLoad(sizeGB: gb)
}

// MARK: - Headroom polling

/// Outcome of `waitForMemoryHeadroom`.
struct MemoryHeadroomResult: Sendable {
    let success: Bool
    let finalAvailableMB: Double
    let pollsTaken: Int
    let elapsedSeconds: Double
}

/// Poll `os_proc_available_memory()` until there's room for `requiredMB` + 100 MB of
/// slack, or until `timeoutSeconds` elapses.
///
/// Every poll is logged, on purpose: the reclamation curve is the thing we could never see
/// before, and how long iOS takes depends on prior pressure and what else is running. A
/// timeout is **not** automatically fatal — the caller decides, usually by falling through
/// to the pre-flight check and refusing with a message.
nonisolated func waitForMemoryHeadroom(
    requiredMB: Double,
    timeoutSeconds: Double = 3.0,
    intervalMillis: UInt64 = 150
) async -> MemoryHeadroomResult {
    let target = requiredMB + 100.0
    let intervalNs = intervalMillis * 1_000_000
    let start = Date()
    let deadline = start.addingTimeInterval(timeoutSeconds)
    var pollCount = 0

    while Date() < deadline {
        let available = processAvailableMemoryMB()
        pollCount += 1
        let elapsed = Date().timeIntervalSince(start)
        cameraLog("MEMORY: headroom poll #\(pollCount) availableMB=\(formatMB(available)) targetMB=\(formatMB(target)) elapsed=\(String(format: "%.2f", elapsed))s")
        if available >= target {
            return MemoryHeadroomResult(success: true,
                                        finalAvailableMB: available,
                                        pollsTaken: pollCount,
                                        elapsedSeconds: elapsed)
        }
        try? await Task.sleep(nanoseconds: intervalNs)
    }

    let final = processAvailableMemoryMB()
    return MemoryHeadroomResult(success: false,
                                finalAvailableMB: final,
                                pollsTaken: pollCount,
                                elapsedSeconds: Date().timeIntervalSince(start))
}

// MARK: - Formatting

@inline(__always)
nonisolated func formatMB(_ mb: Double) -> String {
    if mb.isInfinite { return "∞" }
    return String(format: "%.0f", mb)
}

// MARK: - Refusal

/// What the user reads when a load is refused for memory.
///
/// Centralized so the wording is consistent and revisable in one place.
///
/// Note the register, and that it is deliberate: this is **the app's** voice, not the
/// machine's. Principle 3 governs what the *model* says about a photograph — no hedging,
/// no apology, "this is what I see." It does not govern an engineering refusal about RAM.
/// Confusing the two would be its own category error.
nonisolated func memoryRefusalMessage(
    modelName: String,
    availableMB: Double,
    requiredMB: Double
) -> String {
    let availableStr: String = availableMB.isInfinite
        ? "an unknown amount"
        : String(format: "%.1f GB", availableMB / 1024.0)
    let requiredStr = String(format: "%.1f GB", requiredMB / 1024.0)
    return "Not enough memory to load \(modelName) right now. It needs roughly \(requiredStr) but only \(availableStr) is available. Try closing other apps, or give iOS a moment — it reclaims memory lazily after a model is released."
}

// ==== LEGO END: 25 ProcessMemoryGuard (Load-Time Memory Headroom) ====
