//
//  StatusFeed.swift
//  AI Camera
//
//  The annunciator: one place the whole app posts passive status to, one panel that renders it,
//  in the upper-left of the capture screen.
//
//  The name in code is plain (`StatusFeed`) so any open-source reader gets it at a glance. The
//  idea behind it is an *annunciator*, an instrument's panel of small labelled lights that come
//  on only when their condition holds (a camera is an instrument, so the metaphor fits). It's
//  kept as a comment rather than a class name because the likely readers of a SwiftUI camera repo
//  skew app-dev, and "annunciator" is aviation and industrial vocabulary.
//
//  WHY ONE FEED AND NOT THREE INDICATORS (Mark, 2026-07-20). Privacy, developing, and thermal all
//  want the same corner of the same screen. Building three bespoke indicators that each reach for
//  that corner is three fragile things to keep from colliding. Instead there is ONE feed: a
//  producer publishes a small message under its own `kind`, the panel renders whatever is
//  currently active. Adding a fourth status later costs a `publish(...)` call, not a fourth
//  widget. It is growth-agnostic by construction (CLAUDE.md, "Constraints go in code").
//
//  "Only when relevant" is inherent, not a rule to remember: a message is on screen exactly while
//  its condition holds (a producer publishes when the condition starts and clears when it ends),
//  so the corner is quiet most of the time. Passive status, no controls: this honors the
//  sacred-and-dumb capture screen (the rule was never "nothing on screen," it is "no
//  configuration here").
//

import SwiftUI

// ==== LEGO START: 33 StatusFeed (The Annunciator) ====

/// One status light on the panel, a small value, deliberately free of behavior so the logic that
/// decides *whether* to show it can be reasoned about (and tested) apart from how it looks.
///
/// A message is keyed by its `kind`: a producer owns its kind and there is at most one message per
/// kind on the panel at a time (publishing again replaces it). The optional `tap` names an action
/// the *renderer* interprets, so the message stays a pure value and the view decides what a tap
/// does. That keeps `StatusMessage` `Equatable` (a stored closure would not be).
nonisolated struct StatusMessage: Identifiable, Equatable {

    /// The families. `rawValue` also fixes the panel's top-to-bottom order (lower first), so the
    /// order is stable no matter what sequence the producers happen to publish in.
    ///
    /// There is ONE dark-room family, not separate developing/thermal/blocked pills (Mark,
    /// 2026-07-21): a single pill speaks for the whole condition of the dark room, in five states —
    /// cooling down, paused, developing N, N blocked, or (nothing to report) gone. The worker decides
    /// which by precedence; see `DarkRoomWorker.syncStatusFeed`.
    enum Kind: Int, CaseIterable { case privacy = 0, darkRoom = 1 }

    /// What a tap does. An enum, not a closure, so the message stays a value; the renderer maps
    /// each case to a behavior (present the privacy explanation, or open the Dark Room).
    enum Tap: Equatable { case explainPrivacy, openDarkRoom }

    let kind: Kind
    /// An SF Symbol name, or `nil` when a spinner stands in for the icon.
    var icon: String?
    /// Show a small activity spinner instead of an icon. The developing message uses this, the
    /// same understated spinner the old developing toast had.
    var showsSpinner: Bool = false
    var text: String
    var tap: Tap? = nil

    var id: Kind { kind }

    // MARK: - Factories (each producer's message, in one place)

    // The one dark-room pill, in its states. All are `.darkRoom` and all open the Dark Room on tap;
    // the worker publishes exactly one at a time by precedence (cooling > developing > blocked),
    // and clears the family when there is nothing to report so the pill disappears.

    /// State 1 — cooling down: the queue is holding until the phone cools. A snowflake, not a
    /// spinner, because this is a deliberate pause, not active work. Highest precedence: when the
    /// phone is hot this is *why* nothing is progressing, so it speaks over the count.
    static let cooling = StatusMessage(kind: .darkRoom,
                                       icon: "snowflake",
                                       text: "Cooling down…",
                                       tap: .openDarkRoom)

    /// State 2 — developing N: shots actively in the bath. A spinner, no icon, echoing the toast
    /// Mark called "beautiful and understated." Singular when there's one.
    static func developing(count: Int) -> StatusMessage {
        StatusMessage(kind: .darkRoom,
                      icon: nil,
                      showsSpinner: true,
                      text: count == 1 ? "Developing" : "Developing \(count)",
                      tap: .openDarkRoom)
    }

    /// State 3 — N blocked: shots held because a model they need isn't installed. A warning
    /// triangle. Shown only when nothing is developing (blocked shots are the whole story).
    static func blocked(count: Int) -> StatusMessage {
        StatusMessage(kind: .darkRoom,
                      icon: "exclamationmark.triangle.fill",
                      text: count == 1 ? "1 blocked" : "\(count) blocked",
                      tap: .openDarkRoom)
    }

    /// State 4 — paused: the user paused the queue while shots are waiting, so nothing develops on
    /// purpose. Ranks above developing/blocked (it is why they aren't moving), below cooling.
    static let paused = StatusMessage(kind: .darkRoom,
                                      icon: "pause.fill",
                                      text: "Paused",
                                      tap: .openDarkRoom)

    /// The privacy lock. Shown in BOTH states (Mark, 2026-07-20, standardized with Hal): a CLOSED
    /// lock when nothing can leave the device (a local eye, or no network), an OPEN lock when the
    /// Apple eye is chosen with a network up and a look may not stay on the device. Only the glyph
    /// changes; the popover words are identical either way (they describe both cases). Glyph only,
    /// no text on the capsule: the lock IS the message; the paragraph lives in the popover. Tap to
    /// read it and jump to a local model.
    static func privacy(locked: Bool) -> StatusMessage {
        StatusMessage(kind: .privacy,
                      icon: locked ? "lock" : "lock.open",
                      text: "",
                      tap: .explainPrivacy)
    }
}

/// The single source of truth for what the annunciator is currently showing. Producers publish and
/// clear their own kind; the panel observes `messages`. `@MainActor` because every producer and the
/// renderer are already on the main actor, so no hop is ever needed.
@MainActor
@Observable
final class StatusFeed {
    static let shared = StatusFeed()
    private init() {}

    /// The active messages, held in `Kind` order (see `Kind.rawValue`). Never more than one per
    /// kind.
    private(set) var messages: [StatusMessage] = []

    /// Show `message`, replacing any current message of the same kind. A no-op if an identical
    /// message is already up, so a producer can over-call cheaply (the dark room worker publishes on
    /// every count change).
    func publish(_ message: StatusMessage) {
        if let i = messages.firstIndex(where: { $0.kind == message.kind }) {
            guard messages[i] != message else { return }
            messages[i] = message
        } else {
            messages.append(message)
            messages.sort { $0.kind.rawValue < $1.kind.rawValue }
        }
    }

    /// Take a kind's message off the panel (its condition ended). Idempotent.
    func clear(_ kind: StatusMessage.Kind) {
        messages.removeAll { $0.kind == kind }
    }
}

// MARK: - The panel

/// The upper-left panel: a quiet vertical stack of capsules, one per active message. Empty (and so
/// invisible) whenever nothing is active, which is most of the time.
///
/// It also hosts the **privacy producer**, the one family whose condition is derived from live app
/// state (the chosen eye plus network reachability) rather than pushed by a background worker. That
/// derivation lives here, next to where it is shown, because this panel is always on the (root)
/// capture screen; see the `.onChange` hooks below. The developing and thermal families are pushed
/// by `DarkRoomWorker` directly and need nothing here.
struct StatusFeedView: View {
    /// Opens the Model Library, so the privacy explanation can offer a one-tap way to pick a
    /// downloaded local model (matching Hal's popover).
    let onOpenModelLibrary: () -> Void

    @State private var feed = StatusFeed.shared
    @State private var settings = Settings.shared
    @State private var network = PrivacyMonitor.shared
    @State private var showingPrivacy = false
    @State private var showingDarkRoom = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(feed.messages) { message in
                capsule(for: message)
            }
        }
        // The privacy producer: recompute the lock whenever the eye or the network changes, and
        // once when the panel first appears. The lock shows in BOTH states (Mark, 2026-07-20) — a
        // closed lock when nothing can leave (local eye, or no network), an open lock on the Apple
        // eye with a network up — so this publishes either way and only the glyph changes.
        .task { network.start() }
        .onAppear { refreshPrivacy() }
        .onChange(of: settings.seer) { _, _ in refreshPrivacy() }
        .onChange(of: network.isNetworkAvailable) { _, _ in refreshPrivacy() }
        .onDisappear { feed.clear(.privacy) }
        .sheet(isPresented: $showingDarkRoom) { DarkRoomView() }
    }

    private func refreshPrivacy() {
        // The lock is shown in BOTH states — only the glyph differs (Mark, 2026-07-20). So this
        // always publishes; it never clears on state, it just swaps the closed lock for the open one.
        let locked = PrivacyMonitor.isLocked(seer: settings.seer,
                                             networkAvailable: network.isNetworkAvailable)
        feed.publish(.privacy(locked: locked))
    }

    /// One capsule. Tappable only if the message names a tap action; otherwise a plain label.
    @ViewBuilder
    private func capsule(for message: StatusMessage) -> some View {
        switch message.tap {
        case .explainPrivacy:
            Button { showingPrivacy = true } label: { capsuleBody(message) }
                .buttonStyle(.plain)
                .popover(isPresented: $showingPrivacy) {
                    PrivacyPopover(
                        isLocked: PrivacyMonitor.isLocked(seer: settings.seer,
                                                          networkAvailable: network.isNetworkAvailable),
                        onOpenModelLibrary: {
                            showingPrivacy = false
                            onOpenModelLibrary()
                        })
                    .presentationCompactAdaptation(.popover)
                }
        case .openDarkRoom:
            Button { showingDarkRoom = true } label: { capsuleBody(message) }
                .buttonStyle(.plain)
        case .none:
            capsuleBody(message)
        }
    }

    private func capsuleBody(_ message: StatusMessage) -> some View {
        HStack(spacing: 7) {
            if message.showsSpinner {
                ProgressView().tint(.white).scaleEffect(0.7)
            } else if let icon = message.icon {
                Image(systemName: icon).font(.footnote.weight(.semibold))
            }
            // Glyph-only messages (the privacy lock) carry no text: the glyph is the whole message.
            if !message.text.isEmpty {
                Text(message.text)
                    .font(.footnote.weight(.medium))
            }
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.black.opacity(0.35), in: Capsule())
    }
}

// ==== LEGO END: 33 StatusFeed (The Annunciator) ====
