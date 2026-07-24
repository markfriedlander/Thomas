//
//  PrivacyMonitor.swift
//  AI Camera
//
//  The privacy producer for the annunciator (see StatusFeed.swift). It answers one question,
//  could this look leave the device right now, and posts a lock to the feed either way: a closed
//  lock when nothing can leave, an open lock when a look might not stay on the device.
//
//  THE HONEST LINE (Mark's standing stance, reaffirmed 2026-07-20). A local MLX eye (Qwen) runs
//  entirely on the device: nothing the camera sees, and nothing it writes, leaves. Apple
//  Intelligence is Apple's own system, and only Apple decides when a request is handled in the
//  cloud, so while the device is online we CANNOT guarantee an Apple Intelligence look stays on
//  the device. We do not claim it IS sent to the cloud, and we do not claim it is not. We claim
//  only what is true: with the network up and the Apple eye chosen, it is *possible* it is not
//  fully local, and we give the user a light that shows exactly when that is the case.
//
//  We do NOT try to settle Apple's behavior beyond this. The investigation is closed (Mark's
//  call): Apple's documentation is incomplete on the point, so we hold the conservative line
//  rather than assert a certainty in either direction. See HISTORY 2026-07-19 / 2026-07-20.
//
//  So the lock is CLOSED (a closed-lock glyph) on the local eye, or with no network, and OPEN (an
//  open-lock glyph) on the Apple eye WITH a network available. It is shown in BOTH states; only the
//  glyph changes, and the popover words are identical either way (they describe both cases).
//
//  Ported from Hal's PrivacyMonitor.swift so the privacy logic stays standardized across the
//  studio. Two things are shared with Hal in spirit: the `NWPathMonitor` wrapper and the PURE
//  `isLocked` truth table. Thomas's differences: it has no "salon," its eyes are `Seer` (not
//  Hal's `ModelSource`), and it uses the Observation framework (`@Observable`) to match the rest
//  of this app, where Hal uses Combine's `ObservableObject`. The user-facing copy in the popover
//  is Hal's, verbatim.
//

import SwiftUI
import Network

// ==== LEGO START: 34 PrivacyMonitor (Could This Look Leave The Device?) ====

/// Watches the device's network reachability for the privacy lock. A single shared instance,
/// started once when the capture screen's status panel appears.
///
/// `@Observable` (not Combine) so the SwiftUI panel tracks `isNetworkAvailable` the same way it
/// tracks every other bit of app state here. It starts `false`, the safe (locked) default, until
/// the first `NWPathMonitor` update lands, so we never briefly claim "cloud possible" before we
/// actually know there is a network.
@MainActor
@Observable
final class PrivacyMonitor {
    static let shared = PrivacyMonitor()

    /// True when a usable network path exists (Wi-Fi, cellular, wired, or VPN). With a network up
    /// and the Apple eye chosen, we can't guarantee on-device, so the lock opens.
    private(set) var isNetworkAvailable: Bool = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.MarkFriedlander.AI-Camera.PrivacyMonitor")
    private var started = false

    private init() {}

    /// Begin monitoring. Idempotent, safe to call on every panel appearance.
    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            // `.satisfied` means a usable path exists. VPN reports satisfied (it IS a usable,
            // cloud-capable path, correctly treated as network-available). `.unsatisfied` and
            // `.requiresConnection` (Airplane Mode, Wi-Fi up but unreachable, cellular off) mean
            // not available, so the lock closes.
            let available = (path.status == .satisfied)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isNetworkAvailable != available {
                    self.isNetworkAvailable = available
                }
            }
        }
        monitor.start(queue: queue)
    }

    // MARK: - Lock decision (pure truth table)

    /// The lock/unlock decision as a pure function of its inputs, kept free of UI, the feed, and
    /// even `Settings`, so it can be reasoned about (and unit-tested) in isolation, exactly as
    /// Hal's is. The caller passes the current eye and network state.
    ///
    /// Returns `true` = locked (a local eye, or no network, nothing leaves the device), `false` =
    /// unlocked (the Apple eye with a network up, we can't guarantee it stays on-device).
    nonisolated static func isLocked(seer: Seer, networkAvailable: Bool) -> Bool {
        // No network means nothing can leave the device, whatever the eye is.
        guard networkAvailable else { return true }

        switch seer {
        case .mlx:   return true    // any local MLX eye, entirely on-device
        case .apple: return false   // Apple Intelligence + network, can't guarantee on-device
        }
    }
}

// MARK: - PrivacyPopover (the tap explanation)

/// The small popover shown when the user taps the lock. It shows the canonical privacy copy
/// (identical in both lock states) and offers a one-tap jump to the Model Library. Only the glyph
/// (lock / lock.open) changes with state; the words never change. See the DO-NOT-EDIT marker on
/// `explanation` below.
///
/// Ported from Hal's `PrivacyLockPopover` so the two apps stay word-for-word identical (Mark
/// standardized the privacy copy across the studio on 2026-07-20).
struct PrivacyPopover: View {
    let isLocked: Bool
    /// Invoked when the user taps "Model Library": the caller dismisses the popover and opens the
    /// Model Library, where a downloaded local model is chosen.
    let onOpenModelLibrary: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Only the glyph changes with state. No title text.
            Image(systemName: isLocked ? "lock" : "lock.open")
                .font(.headline)

            Text(explanation)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: onOpenModelLibrary) {
                HStack(spacing: 4) {
                    Text("Model Library")
                    Image(systemName: "arrow.right")
                }
                .font(.subheadline.weight(.medium))
            }
            .padding(.top, 2)
        }
        .padding(16)
        .frame(width: 280)
    }

    // ⛔️ CANONICAL PRIVACY COPY — DO NOT EDIT, REWRITE, "ALIGN", OR "MAKE HONEST".
    // Written and locked by Mark on 2026-07-20 as the single definitive privacy statement, word
    // for word identical to Hal's and to the App Store description's "Genuinely Private" paragraph.
    // It is shown VERBATIM in BOTH lock states; only the glyph (lock / lock.open) changes. It
    // describes both conditions, so it is true in either state and can never mislead. Any future
    // CC: leave it exactly as written. If a change is ever genuinely needed it comes from Mark, in
    // his words, not yours.
    private var explanation: String {
        "When you use a local MLX model, your conversations never leave your iPhone. No network calls. No server. When using Apple Intelligence, inference is on-device when offline; when connected, Apple's Private Cloud Compute may be used (encrypted in transit, processed in non-persistent memory on Apple-controlled servers)."
    }
}

// ==== LEGO END: 34 PrivacyMonitor (Could This Look Leave The Device?) ====
