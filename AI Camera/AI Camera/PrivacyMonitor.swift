//
//  PrivacyMonitor.swift
//  AI Camera
//
//  The privacy producer for the annunciator (see StatusFeed.swift). It answers one question for
//  the user: right now, could anything leave the device, and if so, what and how do I stop it? It
//  posts a lock to the feed either way: a closed lock when nothing can leave, an open lock when
//  something might.
//
//  TWO INDEPENDENT THINGS CAN LEAVE, and the lock speaks to both (Mark, 2026-07-28):
//
//    1. THE LOOK (the eye). A local MLX eye runs entirely on the device: nothing it sees or writes
//       leaves. Apple Intelligence is Apple's own system, and only Apple decides when a request is
//       handled in the cloud, so while the device is online we CANNOT guarantee an Apple look stays
//       on the device. We do not claim it IS sent, nor that it is not. We claim only what is true:
//       online + Apple eye = possibly not fully local. With the eye off (silent loop) there is no
//       description at all, and the hand is always local, so nothing about the look leaves.
//
//    2. THE PLACE (the footer stamp). In reverse-geocode mode the shot's coordinate is sent to
//       Apple's mapping service to turn it into a place name. In raw-coordinate mode the stamp is
//       computed on the device and NOTHING is sent. With location off, there is no stamp and no
//       coordinate at all.
//
//  These are INDEPENDENT — a user can be private on one axis and exposed on the other — so the
//  popover describes each separately and tells the user exactly what to change to close it. That is
//  the whole point of the lock: it names the user's real exposure, granularly, not a fixed slogan.
//
//  The lock glyph is CLOSED only when BOTH axes stay on the device; it OPENS if EITHER can leave.
//
//  ── History ──
//  Through 2026-07-20 this was a single fixed paragraph, shared word-for-word with Hal, that spoke
//  only to the eye. Mark's 2026-07-28 call: Thomas stamps location where Hal does not, and a closed
//  lock while a coordinate was going to Apple for reverse geocoding was an overclaim. So the copy is
//  now Thomas-specific and state-aware. The eye investigation itself stays closed (Mark, 2026-07-20):
//  Apple's docs are incomplete, so we hold the conservative line rather than assert either way. See
//  HISTORY 2026-07-19 / 2026-07-20 / 2026-07-28.
//
//  The `NWPathMonitor` network wrapper is still shared in spirit with Hal; the location-authorization
//  watch and the two-axis copy are Thomas's. Thomas uses Observation (`@Observable`) to match the
//  rest of this app, where Hal uses Combine.
//

import SwiftUI
import Network
import CoreLocation

// ==== LEGO START: 34 PrivacyMonitor (Could Anything Leave The Device?) ====

/// Watches the two live inputs the privacy lock derives from: network reachability, and the app's
/// Location authorization. A single shared instance, started once when the capture screen's status
/// panel appears.
///
/// `@Observable` (not Combine) so the SwiftUI panel tracks these the same way it tracks every other
/// bit of app state here. Both start in their safe (locked) default — no network, not authorized —
/// until the first real update lands, so we never briefly claim more exposure than we've confirmed.
@MainActor
@Observable
final class PrivacyMonitor: NSObject {
    static let shared = PrivacyMonitor()

    /// True when a usable network path exists (Wi-Fi, cellular, wired, or VPN). With a network up,
    /// an Apple eye's look, or a reverse-geocode place lookup, may leave the device.
    private(set) var isNetworkAvailable: Bool = false

    /// True when the user has granted this app Location access. When false there is no coordinate at
    /// all, so the place axis can never leak regardless of the reverse-geocode setting.
    private(set) var isLocationAuthorized: Bool = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.MarkFriedlander.AI-Camera.PrivacyMonitor")
    private var started = false

    /// Reads and observes Location authorization ONLY. It never requests permission and never starts
    /// location updates — `Place` (Camera.swift) owns all of that. This manager exists purely so the
    /// lock can recompute the instant authorization changes.
    private let locationAuth = CLLocationManager()

    private override init() {
        super.init()
        locationAuth.delegate = self
        isLocationAuthorized = Self.authorized(locationAuth.authorizationStatus)
    }

    /// Begin monitoring. Idempotent, safe to call on every panel appearance.
    func start() {
        guard !started else { return }
        started = true
        // Re-read authorization on start in case it changed while the panel was away.
        isLocationAuthorized = Self.authorized(locationAuth.authorizationStatus)
        monitor.pathUpdateHandler = { [weak self] path in
            // `.satisfied` means a usable path exists. VPN reports satisfied (it IS a usable,
            // cloud-capable path, correctly treated as network-available). `.unsatisfied` and
            // `.requiresConnection` (Airplane Mode, Wi-Fi up but unreachable, cellular off) mean
            // not available, so both leak paths close.
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

    private static func authorized(_ status: CLAuthorizationStatus) -> Bool {
        status == .authorizedWhenInUse || status == .authorizedAlways
    }

    // MARK: - Lock decision (pure truth table + the words that describe it)

    /// The full privacy state as a pure function of its inputs, kept free of UI, the feed, and
    /// `Settings`, so it can be reasoned about (and unit-tested) in isolation. The caller passes the
    /// current eye, whether the eye is on, the raw-coordinate setting, and the two monitored inputs.
    ///
    /// It returns both the lock glyph decision AND the two lines of copy, so every word of the
    /// user-facing privacy statement lives in this one auditable place.
    nonisolated static func state(seer: Seer,
                                  useEye: Bool,
                                  rawCoordinates: Bool,
                                  locationAuthorized: Bool,
                                  networkAvailable: Bool) -> PrivacyState {
        // ── The look ──
        // Leaves only when the eye is on, it's Apple Intelligence, and a network is up. A local eye,
        // no network, or the eye off (silent loop) all keep the look on the device.
        let lookLeaves = useEye && seer == .apple && networkAvailable
        let lookLine: String
        if !useEye {
            lookLine = "**The look** stays on your iPhone. The eye is off, so the hand draws from your photo directly on the device, and nothing about the look leaves."
        } else if seer != .apple {
            lookLine = "**The look** stays on your iPhone. The eye is a local model, so nothing it sees or writes leaves the device."
        } else if networkAvailable {
            lookLine = "**The look** uses Apple Intelligence. With a network connection Apple may process it on Private Cloud Compute (encrypted in transit, non-persistent memory on Apple servers). Choose a downloaded local eye, or go offline, to keep it on the device."
        } else {
            lookLine = "**The look** uses Apple Intelligence, running on your iPhone because you're offline. Nothing about the look leaves."
        }

        // ── The place ──
        // A coordinate is sent only for a place-name lookup: it needs reverse-geocode mode (not raw),
        // granted location, and a network to reach Apple.
        let placeLeaves = !rawCoordinates && locationAuthorized && networkAvailable
        let placeLine: String
        if !locationAuthorized {
            placeLine = "**The place** isn't stamped. Location is off, so no coordinate is ever used or sent."
        } else if rawCoordinates {
            placeLine = "**The place** is raw latitude and longitude, computed on your iPhone. No coordinate is sent anywhere."
        } else if networkAvailable {
            placeLine = "**The place** is a name, looked up by sending this shot's coordinate to Apple's mapping service. Switch to raw coordinates in Settings to stamp latitude and longitude with no lookup, so nothing is sent."
        } else {
            placeLine = "**The place** is a name, but the lookup needs a network. While you're offline no coordinate is sent."
        }

        return PrivacyState(isLocked: !lookLeaves && !placeLeaves,
                            lookLine: lookLine,
                            placeLine: placeLine)
    }
}

extension PrivacyMonitor: @preconcurrency CLLocationManagerDelegate {
    /// Authorization changed (the only location event this monitor cares about). Recompute so the
    /// lock updates the instant the user grants or revokes Location.
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        isLocationAuthorized = Self.authorized(manager.authorizationStatus)
    }
}

/// The privacy state: the lock glyph decision plus the two lines of copy that describe the user's
/// real exposure on each axis. Produced purely by `PrivacyMonitor.state(...)`.
struct PrivacyState: Equatable {
    /// True = both axes stay on the device (closed lock). False = something may leave (open lock).
    let isLocked: Bool
    /// The eye axis, phrased for the current state (markdown: `**The look**` leads it).
    let lookLine: String
    /// The location axis, phrased for the current state (markdown: `**The place**` leads it).
    let placeLine: String
}

// MARK: - PrivacyPopover (the tap explanation)

/// The popover shown when the user taps the lock. It states, granularly, what is and isn't leaving
/// the device right now, one line per axis, each naming the remedy. The glyph (lock / lock.open)
/// matches `state.isLocked`.
///
/// ⛔️ The copy is generated by `PrivacyMonitor.state(...)`, the single auditable home for every
/// word of the privacy statement. Any change to what the user is told comes from Mark, in his words
/// (this two-axis, state-aware form is his, 2026-07-28). Do not "align," "simplify," or reword it
/// here or there without him.
struct PrivacyPopover: View {
    let state: PrivacyState
    /// Invoked when the user taps "Preferences": the caller dismisses the popover and opens
    /// Preferences. Preferences is the door to BOTH remedies the popover names — pick a downloaded
    /// local eye in the Model Library, OR switch off the place-name lookup (Mark, 2026-07-28).
    let onOpenPreferences: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Only the glyph changes with state. No title text.
            Image(systemName: state.isLocked ? "lock" : "lock.open")
                .font(.headline)

            Text(markdown(state.lookLine))
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(markdown(state.placeLine))
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: onOpenPreferences) {
                HStack(spacing: 4) {
                    Text("Preferences")
                    Image(systemName: "arrow.right")
                }
                .font(.subheadline.weight(.medium))
            }
            .padding(.top, 2)
        }
        .padding(16)
        .frame(width: 300)
    }

    /// Render the `**bold**` label at the head of each line. `Text(String)` alone would show the
    /// asterisks literally, so we parse the markdown into an AttributedString.
    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s)) ?? AttributedString(s)
    }
}

// ==== LEGO END: 34 PrivacyMonitor (Could Anything Leave The Device?) ====
