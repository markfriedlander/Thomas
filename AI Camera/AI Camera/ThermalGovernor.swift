//
//  ThermalGovernor.swift
//  Thomas / AI Camera
//
//  Ported from Posey's `ThermalGovernor` (read and verified against that file on
//  2026-07-19, not reconstructed from memory) and retuned for a camera: Posey paces
//  hundreds of small back-to-back embed ops; Thomas paces one heavy shot — a
//  several-second MLX draw — at a time.
//

// ==== LEGO START: 31 ThermalGovernor (Backing Off When The Phone Runs Hot) ====

import Foundation

/// Proactive thermal backoff for the draw pipeline — the guard that the thermal
/// instrument (`processThermalState`) was built to justify.
///
/// **Why.** Mark hit a draw crash with the phone running hot. Thermal throttling and
/// memory jetsam compound, and rapid-fire shots stack heat. The instrument made the
/// state visible; this acts on it. It runs at the one chokepoint every shot passes
/// through — `ModelLane`'s serialize/settle boundary — and, when the phone is
/// `serious`/`critical`, holds the next shot until it cools rather than piling another
/// 5–10 s of GPU onto an already-hot device.
///
/// Honors `Task` cancellation, so a stop is never stuck behind a cooldown. A DEBUG-only
/// injected state lets the backoff be exercised without deliberately overheating real
/// hardware (drivable from the antenna — see `POST /thermal`).
actor ThermalGovernor {

    static let shared = ThermalGovernor()

    /// Internal (not private) so a `@testable` build can construct an isolated instance.
    init() {}

    // MARK: - Thermal source (+ test injection)

    #if DEBUG
    /// Test-only override of the OS thermal state. Actor-isolated so it serializes
    /// cleanly with `pace()`.
    private var debugThermalState: ProcessInfo.ThermalState?
    func setDebugThermalState(_ state: ProcessInfo.ThermalState?) {
        debugThermalState = state
    }
    #endif

    private func currentState() -> ProcessInfo.ThermalState {
        #if DEBUG
        if let injected = debugThermalState { return injected }
        #endif
        return ProcessInfo.processInfo.thermalState
    }

    /// The state the governor is actually acting on (respects DEBUG injection). For the
    /// antenna's `GET /thermal`, so a test can confirm the injected state took.
    func snapshot() -> ProcessInfo.ThermalState { currentState() }

    // MARK: - Pacing policy (⚠️ STARTING VALUE — device-tune from the logs)

    /// A camera must not delay a shot when the phone is fine, so `nominal`/`fair` proceed
    /// immediately. When the phone is hot — `serious` OR `critical` — the next shot is held
    /// until it cools back to `fair`/`nominal`, rather than stacking another 5–10 s of GPU onto
    /// a device iOS is already throttling. One rule, tied to a real condition instead of a
    /// guessed timer: "serious" and "critical" both mean "too hot, wait." The re-check cadence
    /// is the only number, and it's tunable.
    private static let recheckNanos: UInt64 = 2_000_000_000  // re-check every 2 s while hot

    /// Cool enough to run a heavy op. Anything not `nominal`/`fair` — including any future
    /// state Apple adds — is treated as hot, which is the safe default for a thermal guard.
    private func isCool(_ s: ProcessInfo.ThermalState) -> Bool {
        s == .nominal || s == .fair
    }

    /// Whether the phone is too hot to develop right now — the *same* threshold `pace()` holds on,
    /// so there is one definition of "hot." The dark room worker polls this to show a "cooling
    /// down" state in the toast while it waits, without duplicating the policy.
    func isHotNow() -> Bool { !isCool(currentState()) }

    /// Pace one shot at the `ModelLane` boundary, before the heavy op begins. Returns
    /// immediately when the phone is cool or the Task is cancelled; when hot, holds (and logs,
    /// so the wait is visible in `GET /memory`) until it cools to fair or nominal.
    func pace() async {
        if Task.isCancelled { return }
        if isCool(currentState()) { return }

        cameraLog("THERMAL: \(thermalStateLabel(currentState())) — holding the next shot until the phone cools")
        var waited = 0.0
        while !Task.isCancelled {
            let state = currentState()
            if isCool(state) {
                cameraLog("THERMAL: cooled to \(thermalStateLabel(state)) after \(String(format: "%.0f", waited))s — releasing the shot")
                return
            }
            try? await Task.sleep(nanoseconds: Self.recheckNanos)
            waited += Double(Self.recheckNanos) / 1_000_000_000
        }
    }
}

// ==== LEGO END: 31 ThermalGovernor (Backing Off When The Phone Runs Hot) ====
