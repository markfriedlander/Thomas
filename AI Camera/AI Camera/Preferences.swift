//
//  Preferences.swift
//  AI Camera
//
//  The film drawer. Everything hectic lives here so the capture screen can stay sacred
//  and dumb — an SLR has a green AUTO box on the dial AND full manual controls, and you
//  don't have to choose.
//
//  ⚠️ PRINCIPLE 2 GOVERNS THIS FILE. "It teaches by not hiding."
//
//  A real SLR doesn't rename its mechanics. The dial says f/2.8, 1/250, ISO 400 — hard,
//  technical, honest words — and photographers learn them *because the camera exposes
//  them*. So: **metaphor for the object, real terminology for the controls.** A system
//  prompt is called a system prompt. A temperature is called a temperature. There is no
//  "Dreaminess" slider here and there never will be.
//
//  And presets MUST SHOW THEIR WORK: loading one writes its actual prompt text and
//  temperature into the visible, editable fields. That makes every preset a **worked
//  example** rather than a simplification — you learn what a system prompt *is* by
//  watching a good one operate. Transparency-as-architecture, in camera form.
//
//  ⚠️ Never add a "poetic" preset. Mark, 2026-07-14: the machine's plain inventory is
//  already poetic *because it isn't performing*. Ask it for truth, not for lyricism —
//  performed lyricism is the machine faking a feeling it doesn't have, which is exactly
//  Principle 3's sin.
//

import SwiftUI
#if canImport(UIKit)
import UIKit   // UIPasteboard — the antenna panel's copy buttons (DEBUG only)
#endif

// ==== LEGO START: 20 Settings (What The Camera Is Loaded With) ====

/// What frame 2 prints — the eye's words, in one of two honesties.
///
/// The app's chain is reality → the eye's words → the hand's drawing. When a description runs
/// too long for the hand and gets condensed (`Shot` / `Eye.condense`), those two diverge, and
/// Mark made the divergence a user-facing choice (2026-07-16): do you want to see *what the eye
/// saw*, or *what the eye saw and passed on*?
///
/// Default `.sentToHand` — the airtight chain, where frame 2 is literally what frame 3 was
/// drawn from, no hidden step. `.fullPerception` is the opt-in "show me everything the eye
/// said, even the part the hand didn't get." The two read identically on any shot short enough
/// to need no condensing — which, with Layer 1 keeping the eye brief, is most of them.
nonisolated enum FrameTwoWords: String, CaseIterable, Sendable {
    case sentToHand
    case fullPerception

    var name: String {
        switch self {
        case .sentToHand:     return "What the hand received"
        case .fullPerception: return "The eye's full words"
        }
    }
}

/// Which "developer" turns the drawing's latent into a finished image — the last, memory-heavy
/// step of frame 3. Two honest choices. A third "Automatic" would make "Detailed" a broken
/// promise, because we override toward safety *regardless* of the choice (a Detailed user who
/// explicitly did not pick Automatic would still get silently switched). So instead: two
/// preferences, and a plain notice that we are ultimately driving and will not let it crash.
nonisolated enum DecoderChoice: String, CaseIterable, Sendable {
    case detailed   // the full VAE, tiled to fit — sd-turbo's own decoder, best fidelity
    case fast       // TAESD — a tiny distilled decoder, softer but nearly impossible to crash

    var name: String {
        switch self {
        case .detailed: return "Detailed"
        case .fast:     return "Fast"
        }
    }
}

/// What the camera is loaded with. Set before you raise it; never per-shot.
///
/// `@AppStorage` because a camera remembers its settings when you put it down. The shot
/// stays atomic: nothing here is asked at the moment of the press.
@MainActor
@Observable
final class Settings {
    static let shared = Settings()

    /// Which eye the NEXT shutter-press will record. Purely a recording template now.
    ///
    /// ⭐ Model-ownership rule (Mark, 2026-07-19): the live settings do NOT load or unload any
    /// model. **The dark room queue's worker is the sole owner of model loading** — it loads
    /// whatever each shot's *frozen* config names, and tears it down between shots. Changing the
    /// eye here only changes what the next press records; it must never yank a model the worker is
    /// mid-use of. So this setter just stores the choice — no `unload()`.
    ///
    /// (This also kills a latent bug: switching your eye mid-session can no longer pull a 1.6 GB
    /// model out from under a shot the worker is actively developing.)
    var seer: Seer {
        // Persisted by its canonical `token` (see Seer): "apple", or the MLX repo id. An old
        // install that saved the pre-generalization "qwen"/"afm" rawValue still reads back
        // correctly through `Seer(token:)`.
        didSet { store(seer.token, "seer") }
    }
    var layout: Layout {
        didSet { store(layout.rawValue, "layout") }
    }
    /// Whether a shot also draws the third frame.
    ///
    /// **Off by default, and that is the ship strategy rather than timidity.** Panels 1 and 2
    /// work on a fresh install with zero download (CLAUDE.md: *"Panel 3, the re-imagining, is
    /// the download"*). Defaulting this on would mean a camera that fails on first press for
    /// anyone who hasn't been to the library yet.
    ///
    /// It also costs real time — ~10 s on an iPhone 16 Plus, load included — so it is a
    /// choice, not a default. The latency is the film developing, but the user gets to decide
    /// how long the bath takes.
    var drawsThirdFrame: Bool {
        didSet { store(drawsThirdFrame, "drawsThirdFrame") }
    }
    /// Which hand draws the third frame — the drawer's shared-store repo id. The counterpart to
    /// `seer` for the eye: `drawsThirdFrame` is the on/off, this is the which. Only sd-turbo
    /// exists today, so it is effectively constant until a second drawer (and a picker) arrive;
    /// it is stored now so each shot can freeze the drawer it was taken with (see `ShotConfig`).
    var selectedDrawer: String {
        didSet { store(selectedDrawer, "selectedDrawer") }
    }
    /// The step knob's value **per drawer** — how many denoising steps each hand draws with.
    ///
    /// Per-drawer because the right number is a property of the model, not a global taste: turbo
    /// draws in a handful of steps, SD-2.1 wants ~20, and switching hands shouldn't drag the wrong
    /// number along. A drawer with no entry here falls to its catalog default (`drawSteps(for:)`).
    /// `[String: Int]` is plist-native, so it stores straight into UserDefaults, no JSON.
    var drawStepsByDrawer: [String: Int] {
        didSet { store(drawStepsByDrawer, "drawStepsByDrawer") }
    }

    /// The step count for a given drawer — the stored value clamped to the drawer's range, or the
    /// drawer's catalog default when the user hasn't touched the knob for it. The clamp means a
    /// stored value can never fall outside the range the UI offers, even if a drawer's range changes
    /// in a later build.
    func drawSteps(for repoID: String) -> Int {
        let spec = ModelCatalog.model(id: repoID)?.drawSteps
        guard let stored = drawStepsByDrawer[repoID] else { return spec?.default ?? 4 }
        guard let range = spec?.range else { return stored }
        return min(max(stored, range.lowerBound), range.upperBound)
    }

    /// Set the step count for a given drawer.
    func setDrawSteps(_ n: Int, for repoID: String) {
        var m = drawStepsByDrawer
        m[repoID] = n
        drawStepsByDrawer = m
    }

    /// What the Preferences step slider binds to: the currently selected drawer's step count.
    /// Reads through the clamp above; writes into the per-drawer map for `selectedDrawer`.
    var currentDrawerSteps: Int {
        get { drawSteps(for: selectedDrawer) }
        set { setDrawSteps(newValue, for: selectedDrawer) }
    }
    var systemPrompt: String {
        didSet { store(systemPrompt, "systemPrompt") }
    }
    var temperature: Double {
        didSet { store(temperature, "temperature") }
    }
    // ── The SILENT LOOP (eye off → the hand reads the photo directly). 2026-07-27. ──
    //
    // A hand prompt was DEACTIVATED on 2026-07-16 because putting a human's aesthetic into the
    // machine→machine chain "changes what the drawer perceives the eye to have seen." That reasoning
    // still holds — for the NORMAL chain. So the hand prompt lives ONLY here, in the silent loop,
    // where there is no eye and no words to protect: the eye is off, the photograph goes straight
    // into the (CoreML) hand, and a short prompt nudges its re-interpretation. A different gap.

    /// Whether the eye runs at all. Off = the silent loop. Default on (the language loop is the
    /// app's thesis).
    ///
    /// The silent loop ONLY works on the SD-2.1 (Core ML) hand (sd-turbo can't read a photo in), so
    /// turning the eye OFF auto-selects that hand and turns drawing on — when it's installed — so
    /// "eye off" always lands on a hand that can do the job. Enforced HERE in the model (Principle 7),
    /// not in screen code, so it holds however the eye is toggled — Preferences, the antenna, a future
    /// preset — and can't be bypassed. No auto-restore on the way back (Mark, 2026-07-27). If SD-2.1
    /// isn't installed nothing switches; the UI tells the user to download it.
    var useEye: Bool {
        didSet {
            store(useEye, "useEye")
            if !useEye, DrawerLoader.isAvailable(ModelCatalog.coreMLSD21.id) {
                selectedDrawer = ModelCatalog.coreMLSD21.id
                drawsThirdFrame = true
            }
        }
    }
    /// The small instruction the hand gets in the silent loop — art direction on the re-imagining,
    /// not a description of the scene. Empty is fine (the image alone steers the draw). Char-capped
    /// in the UI so it can't crowd the model's ~75-token ceiling.
    var handPrompt: String {
        didSet { store(handPrompt, "handPrompt") }
    }
    /// How far the silent loop transforms the photograph: 0 → barely touched, 1 → fully reimagined.
    /// Clamped into image-to-image range by the drawer. Default 0.6 — a clear re-imagining that still
    /// remembers the photo.
    var handStrength: Double {
        didSet { store(handStrength, "handStrength") }
    }

    /// What frame 2 prints — the eye's full words, or the (possibly condensed) words the hand
    /// actually received. See `FrameTwoWords`. Default is the airtight chain.
    var frameTwoShows: FrameTwoWords {
        didSet { store(frameTwoShows.rawValue, "frameTwoShows") }
    }
    /// How large the drawing is saved. The model draws at 512²; anything larger is upscaled
    /// AFTER the draw (the upscale is light and never touches the VAE memory spike). `native`
    /// = 512, no upscaling — the honest baseline, what the model actually made.
    var drawingSize: DrawingSize {
        didSet { store(drawingSize.rawValue, "drawingSize") }
    }
    /// Which upscaler does the enlarging, when `drawingSize` is larger than native. MetalFX is
    /// sharper (GPU) but falls back to Core Image on any device that doesn't support it.
    var upscaler: UpscaleMethod {
        didSet { store(upscaler.rawValue, "upscaler") }
    }
    /// Which decoder develops the drawing — the full VAE (Detailed) or the tiny bundled TAESD
    /// (Fast). A preference, not an absolute: on a device too tight to afford the full decode this
    /// shot, Detailed quietly falls back to Fast rather than crash (disclosed in `decoderSection`).
    /// Default Detailed — best fidelity, kept safe by the fallback.
    var decoderChoice: DecoderChoice {
        didSet { store(decoderChoice.rawValue, "decoderChoice") }
    }
    /// Stamp the footer with raw latitude/longitude instead of a reverse-geocoded place name.
    /// **A privacy choice (Mark, 2026-07-21).** Turning a coordinate into "Los Angeles, CA" sends
    /// that coordinate to Apple's mapping service (reverse geocoding). Raw coordinates skip that
    /// lookup entirely, so with a local eye and hand there is genuinely NO network call in the shot
    /// path — provably local, which is what CLAUDE.md Principle 5 was always meant to cash out to.
    /// Off by default (the place name reads more naturally); on, the footer is forensic.
    var stampRawCoordinates: Bool {
        didSet { store(stampRawCoordinates, "stampRawCoordinates") }
    }

    private init() {
        let d = UserDefaults.standard
        seer = Seer(token: d.string(forKey: "seer") ?? "")
        layout = Layout(rawValue: d.string(forKey: "layout") ?? "") ?? .superimposed
        drawsThirdFrame = d.bool(forKey: "drawsThirdFrame")
        selectedDrawer = d.string(forKey: "selectedDrawer") ?? ModelCatalog.sdTurbo.id
        drawStepsByDrawer = (d.dictionary(forKey: "drawStepsByDrawer") as? [String: Int]) ?? [:]
        useEye = (d.object(forKey: "useEye") as? Bool) ?? true   // default: the eye is on
        handPrompt = d.string(forKey: "handPrompt") ?? ""
        handStrength = (d.object(forKey: "handStrength") as? Double) ?? 0.6
        systemPrompt = d.string(forKey: "systemPrompt") ?? Eye.plain.systemPrompt
        temperature = d.object(forKey: "temperature") as? Double ?? Eye.plain.temperature
        // handPrompt parked — see the property above.
        frameTwoShows = FrameTwoWords(rawValue: d.string(forKey: "frameTwoShows") ?? "") ?? .sentToHand
        drawingSize = DrawingSize(rawValue: d.string(forKey: "drawingSize") ?? "") ?? .native
        upscaler = UpscaleMethod(rawValue: d.string(forKey: "upscaler") ?? "") ?? .metalFX
        decoderChoice = DecoderChoice(rawValue: d.string(forKey: "decoderChoice") ?? "") ?? .detailed
        stampRawCoordinates = d.bool(forKey: "stampRawCoordinates")   // default false
    }

    private func store(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    /// The loaded eye, built from the current settings. This is what the shutter uses.
    var loadedSeer: Seer { seer }

    var eye: Eye {
        var e = Eye.plain
        e.systemPrompt = systemPrompt
        e.temperature = temperature
        return e
    }

    /// Back to the system prompt and temperature the camera shipped with.
    func resetPromptToDefault() {
        systemPrompt = Eye.plain.systemPrompt
        temperature = Eye.plain.temperature
    }

    /// Factory reset — every setting, not just the prompt.
    ///
    /// The list is written out rather than looped so that adding a setting and forgetting
    /// to reset it is a visible omission in this function, not an invisible one.
    func resetEverything() {
        seer = .apple
        layout = .superimposed
        drawsThirdFrame = false
        selectedDrawer = ModelCatalog.sdTurbo.id
        drawStepsByDrawer = [:]   // every drawer back to its catalog-default step count
        useEye = true             // the eye on — the language loop is the default
        handPrompt = ""
        handStrength = 0.6
        systemPrompt = Eye.plain.systemPrompt
        temperature = Eye.plain.temperature
        // handPrompt parked — see the property above.
        frameTwoShows = .sentToHand
        drawingSize = .native
        upscaler = .metalFX
        decoderChoice = .detailed
        stampRawCoordinates = false
    }
}

/// A named starting point that **shows its work**.
///
/// Not a hidden configuration — selecting one fills the visible fields with its actual
/// text and number, which you can then read, edit, or ignore. The preset is a worked
/// example, and the moment you change a word it stops being a preset and starts being
/// yours. That's the intent.
struct Preset: Identifiable {
    let id = UUID()
    let name: String
    let note: String
    let systemPrompt: String
    let temperature: Double

    static let all: [Preset] = [
        Preset(
            name: "Plain",
            note: "The default. Asks for a flat, unhedged report and nothing else.",
            systemPrompt: Eye.plain.systemPrompt,
            temperature: 0.6
        ),
        Preset(
            name: "Inventory",
            note: "Names things and counts them. Nouns, no atmosphere.",
            systemPrompt: """
                You are the eye of a camera. List what is in front of you.

                Name each thing plainly, in the first person, present tense. Count things \
                when there is more than one. Do not describe mood, atmosphere, or what the \
                scene means. Never hedge — no "appears to be", "possibly", "I think". You \
                are not guessing and you are not being graded.

                Do not mention that this is a photograph or an image.

                Two or three sentences.
                """,
            temperature: 0.5
        ),
        Preset(
            name: "Close Reader",
            note: "Pushes for detail — texture, edges, small things. Where naming breaks down.",
            systemPrompt: """
                You are the eye of a camera. Report the small things.

                Speak in the first person, present tense. Attend to texture, edge, and \
                surface. Name the parts of things, precisely, when you know their names. \
                Never hedge — no "appears to be", "possibly", "I think". You are not \
                guessing and you are not being graded.

                Do not mention that this is a photograph or an image.

                Two or three sentences.
                """,
            temperature: 0.6
        ),
        Preset(
            name: "Deadpan",
            note: "Says the least it can and stops. Nothing is interesting to it.",
            systemPrompt: """
                You are the eye of a camera. Say what is there. Stop.

                First person, present tense. Short declarative sentences. No adjectives \
                unless the thing cannot be identified without one. Never hedge. You are \
                not guessing and you are not being graded.

                Do not mention that this is a photograph or an image.

                No more than three sentences. Fewer is better.
                """,
            temperature: 0.4
        )
    ]
}

// ==== LEGO END: 20 Settings (What The Camera Is Loaded With) ====

// ==== LEGO START: 21 PreferencesView (The Film Drawer) ====

struct PreferencesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = Settings.shared
    /// The app-level model-store signal. The Eye/Hand rows below show whether a model is on disk,
    /// which is a filesystem fact SwiftUI can't observe; reading `storeSignal.version` makes this
    /// screen redraw when a model is downloaded, deleted, or cleared anywhere. Without it, removing
    /// a model in the library left a stale green "active" dot here (2026-07-30). See `ModelStoreSignal`.
    @State private var storeSignal = ModelStoreSignal.shared
    @State private var showingPresets = false
    @State private var confirmingReset = false
    @State private var showingLayerOneInfo = false
    @State private var showingDarkRoom = false
    @FocusState private var promptFocused: Bool
    #if DEBUG
    /// Which antenna field last flashed "copied" (nil = none). Drives the copy-button
    /// checkmark; cleared after a beat. See antennaSection.
    @State private var copiedAntennaField: String?
    #endif

    var body: some View {
        NavigationStack {
            Form {
                modelSection
                eyeSection
                handSection
                silentLoopSection
                decoderSection
                sizeSection
                layoutSection
                locationSection
                darkRoomSection
                resetSection
                aboutSection
                #if DEBUG
                antennaSection
                #endif
            }
            .sheet(isPresented: $showingDarkRoom) { DarkRoomView() }
            #if DEBUG
            // Human-parity for the antenna's model-library verb: push the SAME `ModelLibraryView` the
            // "Browse Model Library" row pushes, onto Preferences' own nav stack — not a parallel
            // presenter. Driven by the bridge flag the antenna sets, and cleared when the library is
            // popped. DEBUG-only (the bridge exists only in DEBUG). See `AntennaUIBridge.tapModelLibrary`.
            .navigationDestination(isPresented: Binding(
                get: { AntennaUIBridge.shared.tapModelLibrary },
                set: { AntennaUIBridge.shared.tapModelLibrary = $0 }
            )) { ModelLibraryView() }
            #endif
            // ⚠️ The presets sheet lives HERE, on the Form, not on `promptSection`.
            //
            // It used to hang off the Section, and that is why it "hid itself as soon as you
            // clicked" (Mark, 2026-07-16): `settings` is `@Observable`, the system-prompt
            // TextEditor mutates it on the way in, the Section re-evaluates, and a `.sheet`
            // bound to a view that's being rebuilt gets torn down — it opens and instantly
            // dismisses. A sheet has to hang off a stable parent. The Form is stable; the
            // Section is not.
            // ⏸️ PRESETS COMMENTED OUT 2026-07-27 (Mark). The current presets are eye-only; the
            // planned replacement is bigger and different — save a WHOLE setup (an eye configured +
            // a hand configured) as a named group you can load/edit/delete, so users define their
            // own complete looks. Kept in code (PresetPicker + Eye.presets) so reviving/expanding is
            // trivial; just the entry points are hidden. See NEXT ("full-config presets").
            // .sheet(isPresented: $showingPresets) {
            //     PresetPicker { preset in
            //         // Show your work: the preset writes into the visible fields. Nothing is
            //         // configured behind your back, and you can see exactly what it did.
            //         settings.systemPrompt = preset.systemPrompt
            //         settings.temperature = preset.temperature
            //     }
            // }
            // Same reason as the presets sheet: alerts hang off the stable Form, not a Section
            // that re-renders when `settings` changes.
            .alert("Why can't I change this line?", isPresented: $showingLayerOneInfo) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("This keeps the eye's description short enough for the hand to draw from — the drawing model can only read about seventy-five words, and a longer description used to crash the camera. It's locked so it can't be removed by accident. Everything below it is yours.")
            }
            .navigationTitle("Preferences")
            .navigationBarTitleDisplayMode(.inline)
            // Keep the selected layout producible: if turning the eye or hand off (or switching to an
            // un-downloaded hand) makes the current layout impossible, snap to the richest available
            // one. This is the content-aware half of the layout rebuild (2026-07-27) — it's why the
            // picker never shows a greyed-out layout you can't make (retires bug #22).
            // The eye→SD-2.1 auto-switch now lives in `Settings.useEye` (model-level, so the antenna
            // and any future preset get it too). Here we only keep the layout coherent with the toggles.
            .onChange(of: settings.useEye) { _, _ in snapLayoutIfNeeded() }
            .onChange(of: settings.drawsThirdFrame) { _, _ in snapLayoutIfNeeded() }
            .onChange(of: settings.selectedDrawer) { _, _ in snapLayoutIfNeeded() }
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                // The system prompt is a multi-line editor, and a keyboard over one has no
                // Return key to escape with. This is the way out.
                ToolbarItem(placement: .keyboard) {
                    HStack {
                        Spacer()
                        Button("Done") { promptFocused = false }
                    }
                }
            }
        }
    }

    // MARK: - Location (how the footer stamps place)

    /// A privacy switch (Mark, 2026-07-21): stamp raw latitude/longitude instead of a place name,
    /// which skips the reverse-geocode lookup and its network call entirely. With a local eye and
    /// hand, raw coordinates make the whole shot path provably local.
    private var locationSection: some View {
        Section {
            Toggle("Stamp raw coordinates", isOn: $settings.stampRawCoordinates)
        } header: {
            Text("Location")
        } footer: {
            Text("The footer stamps where a shot was taken. Normally that's a place name (\"Los Angeles, CA\"), looked up by sending the coordinate to Apple's mapping service. Turn this on to stamp raw latitude and longitude instead — no lookup, no network call — so with a downloaded local eye and hand, nothing about the shot leaves your phone.")
        }
    }

    // MARK: - The dark room (a second door into the developing queue)

    /// A way into the Dark Room from Preferences (Mark, 2026-07-21), alongside the "Developing N"
    /// status on the capture screen. Reachable even when nothing is developing — which is the only
    /// door to shots that are *blocked* waiting for a model to be re-downloaded.
    private var darkRoomSection: some View {
        Section {
            Button {
                showingDarkRoom = true
            } label: {
                Label("Enter the Dark Room", systemImage: "tray.full")
            }
        } footer: {
            Text("Shots develop in the background and land in Photos. The dark room shows what's still developing, and lets you pause, reorder, delete, or load a picture to develop.")
        }
    }

    // MARK: - Which machine is looking

    /// The models **in use** — each with the shared status dot — and a row through to the
    /// library. Adapted from Hal's convention, but where Hal shows one active model this shows
    /// as many as a shot enlists: the eye always, and the hand too when the third frame is
    /// being drawn (Mark, 2026-07-16 — *"Models loaded should include both models in use"*).
    ///
    /// **This replaced a second, older way of choosing the eye.** Preferences used to carry
    /// its own `Picker` over Apple/Qwen plus a footer spelling out each one's trade-offs —
    /// written when there was nowhere else for that to live. The library now selects models
    /// and describes them (`ModelCatalog`'s blurbs are that footer's text, moved to where
    /// the model is), so the picker was a second control for one setting and the footer was
    /// a second copy of one description. Two places to change a thing is how they drift.
    private var modelSection: some View {
        Section {
            // The eye is always in use; green when it's ready to shoot, no dot when it isn't
            // (the reason text below says why). See `ModelStatusDot`.
            loadedRow(role: "Eye",
                      name: settings.seer.name,
                      downloaded: settings.seer.isAvailable)
                .id(storeSignal.version)   // redraw when the store changes — `isAvailable` reads disk
            // The hand joins it only when the third frame is being drawn — then both models are
            // in use, and both are listed. Off, the hand isn't in use, so it isn't shown.
            if settings.drawsThirdFrame {
                // Name the hand actually selected, not a hardcoded one — a second drawer would
                // otherwise mislabel here (2026-07-30). Falls back to sd-turbo only if the id is
                // somehow unknown to the catalog.
                loadedRow(role: "Hand",
                          name: selectedDrawerModel?.displayName ?? ModelCatalog.sdTurbo.displayName,
                          downloaded: DrawerLoader.isAvailable(settings.selectedDrawer))
                    .id(storeSignal.version)
            }
            // Kept from the old section — the one thing the library can't say, because it's
            // about the eye you're *currently* shooting with. Three distinct reasons need
            // three distinct messages; see NEXT.md on `UnavailableReason`.
            if !settings.seer.isAvailable {
                Text(unavailableReason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            NavigationLink {
                ModelLibraryView()
            } label: {
                Label("Browse Model Library", systemImage: "square.grid.2x2")
            }
            .foregroundStyle(.primary)
        } header: {
            Text("Models")
        } footer: {
            Text("Download the machines the camera runs on, and choose which eye is loaded. Models are shared with Hal and Posey — anything they've already fetched is here for free.")
        }
    }

    /// One "in use" row: a role label ("Eye" / "Hand"), the shared status dot, and the model
    /// name. The row only appears for a model that IS in use, so within it the model is active
    /// by definition — green when downloaded, no dot when not.
    private func loadedRow(role: String, name: String, downloaded: Bool) -> some View {
        HStack {
            Text(role).font(.subheadline)
            Spacer()
            HStack(spacing: 6) {
                ModelStatusDot(isDownloaded: downloaded, isActive: true)
                Text(name).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private var unavailableReason: String {
        switch settings.seer {
        case .apple: return Readiness.current.explanation
        // Was: "Download it in Hal or Posey and it appears here." That stopped being true
        // the moment the library existed, and it was the app admitting it was a parasite on
        // two apps that aren't released.
        case .mlx:   return "Not downloaded yet — get it in the Model Library."
        }
    }

    // MARK: - The eye — how it looks

    /// Mark, 2026-07-16, on the metaphors: *"let's use eye and hand as the metaphors for
    /// now."* So the section is "The eye" (metaphor for the object) and the control inside is
    /// a system prompt (honest terminology for the control) — Principle 2 exactly: metaphor
    /// for the thing, real name for the knob.
    private var eyeSection: some View {
        Section {
            // The eye on/off — the silent-loop switch. Off means the hand reads the photograph
            // directly (a CoreML-hand feature). The toggle stays usable regardless of the hand, so
            // you're never stranded; but the silent loop only PRODUCES a drawing with the
            // Neural-Engine hand, so we say so plainly when it can't.
            Toggle("Use the eye", isOn: $settings.useEye)
            if !settings.useEye && selectedDrawerEngine != .coreML {
                Text("The silent loop only works with the SD-2.1 (Core ML) hand. Download it in the Model Library to use the silent loop; until then, this shot keeps just the photo and your words.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            if !settings.useEye {
                Text("Silent loop: the eye is off. The hand reads your photograph directly and paints it again — no words in between. Set the instruction and how far it strays below.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
            // Layer 1 — locked, but SHOWN. Principle 2 done honestly: we don't hide the line
            // the app depends on, we display it and lock it. The ⓘ says why. Everything below
            // is Layer 2, fully the user's. It shows the CURRENT eye's Layer 1 (per-model now,
            // 2026-07-26), so switching to Smol honestly shows its stricter line. See `PromptLayers`.
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 3)
                Text(PromptLayers.layerOne(forRepo: settings.seer.token))
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button {
                    promptFocused = false
                    showingLayerOneInfo = true
                } label: {
                    Image(systemName: "info.circle").foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
            }

            // Principle 2: this is a system prompt, it is called a system prompt, and you
            // can read and change every word of it. (This is Layer 2 — the locked brevity line
            // above is Layer 1.)
            TextEditor(text: $settings.systemPrompt)
                .font(.system(.footnote, design: .monospaced))
                .frame(minHeight: 160)
                .focused($promptFocused)

            HStack {
                Text("Temperature")
                Spacer()
                Text(String(format: "%.2f", settings.temperature))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $settings.temperature, in: 0...1.5, step: 0.05)

            // What FRAME 2 prints — the eye's full words, or the (possibly condensed) words the hand
            // actually received. It lives HERE, in the eye section, because it controls frame 2, the
            // eye's own panel (Mark, 2026-07-27). The distinction only bites when a long description
            // was shortened to fit the hand; otherwise both show the same words.
            Picker("Frame 2 shows", selection: $settings.frameTwoShows) {
                ForEach(FrameTwoWords.allCases, id: \.self) { choice in
                    Text(choice.name).tag(choice)
                }
            }

            // Button("Presets…") { showingPresets = true }   // ⏸️ hidden 2026-07-27 — see the sheet note on the Form
            Button("Reset defaults") {
                promptFocused = false
                settings.resetPromptToDefault()
            }
            }   // end `if settings.useEye`
        } header: {
            Text("Frame 2 · The Eye — how it sees")
        } footer: {
            Text("The system prompt tells the eye how to describe what it sees. Higher temperature makes it reach for less likely words. At 1.0 it describes the same scene differently every time; at 0.6 it is steadier and, in our testing, more specific — not less imaginative. Qwen's own documentation recommends 0.6 for looking at pictures.")
        }
        // NOTE: the `.sheet` for presets is on the Form (see `body`), NOT here — attaching it
        // to this Section made it dismiss itself on every re-render.
    }

    // MARK: - The hand — how it draws

    /// The toggle that turns frame 3 on, and — once it's on — the one choice that only matters
    /// when the hand is drawing: what frame 2 shows.
    ///
    /// The hand takes **only the eye's words**, clean. A hand *style* prompt was built and then
    /// deactivated (2026-07-16): styling the drawing inserts a human's aesthetic into a
    /// machine→machine chain. The editor is commented out below (not deleted) — it's a real
    /// future feature, an opt-in "art direction" mode outside the pure chain. See NEXT.
    /// The catalog record for the currently selected hand, and its engine — small helpers so the
    /// hand's sections don't each re-derive them.
    private var selectedDrawerModel: CameraModel? { ModelCatalog.model(id: settings.selectedDrawer) }
    private var selectedDrawerEngine: DrawEngine { selectedDrawerModel?.engine ?? .mlx }

    /// Short cap on the hand prompt — art direction, not a description. The drawer's text encoder
    /// only reads ~75 tokens, and this leaves plenty of room while keeping the instruction terse.
    private static let handPromptMaxChars = 80

    /// The silent-loop controls — a short instruction for the hand, and how far it transforms the
    /// photo. Only when the eye is off AND the hand can actually do it (CoreML).
    @ViewBuilder
    private var silentLoopSection: some View {
        if !settings.useEye && selectedDrawerEngine == .coreML {
            Section {
                TextField("e.g. an oil painting · a charcoal sketch · leave blank",
                          text: Binding(
                            get: { settings.handPrompt },
                            set: { settings.handPrompt = String($0.prefix(Self.handPromptMaxChars)) }),
                          axis: .vertical)
                    .lineLimit(1...3)
                    .font(.system(.footnote, design: .monospaced))
                HStack {
                    Spacer()
                    Text("\(settings.handPrompt.count)/\(Self.handPromptMaxChars)")
                        .font(.caption2).foregroundStyle(.tertiary)
                }

                HStack {
                    Text("Transform")
                    Spacer()
                    Text(String(format: "%.2f", settings.handStrength))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.handStrength, in: 0.2...0.9, step: 0.05)
            } header: {
                Text("Frame 3 · Silent loop — how the hand re-imagines")
            } footer: {
                Text("The instruction nudges the style; the hand still reads your photograph for its shapes and colors. Transform sets how far it strays — low keeps the photo's forms, high reinvents them. Blank instruction is fine — the image alone will steer it.")
            }
        }
    }

    private var handSection: some View {
        Section {
            // Which hand is chosen in the Model Library, not here (2026-07-27) — one selection home.
            Toggle("Draw the third frame", isOn: $settings.drawsThirdFrame)
                .disabled(!DrawerLoader.isAvailable(settings.selectedDrawer))

            if !DrawerLoader.isAvailable(settings.selectedDrawer) {
                Text("\(selectedDrawerModel?.displayName ?? "This hand") isn't downloaded — get it in the Model Library above.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if settings.drawsThirdFrame {
                // ── The step knob, per drawer. ──
                // Honest terminology (Principle 2): these are denoising *steps*, the same word the
                // model uses. More steps, more detail, more time. Per-drawer because the useful
                // range is the model's own — turbo draws in a handful, SD-2.1 wants ~20 — so
                // `currentDrawerSteps` reads and writes the selected hand's slot, clamped to its
                // range. Modelled on the eye's temperature slider above.
                if let spec = selectedDrawerModel?.drawSteps {
                    HStack {
                        Text("Steps")
                        Spacer()
                        Text("\(settings.currentDrawerSteps)")
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(settings.currentDrawerSteps) },
                            set: { settings.currentDrawerSteps = Int($0.rounded()) }
                        ),
                        in: Double(spec.range.lowerBound)...Double(spec.range.upperBound),
                        step: 1
                    )
                    // The hand's reset — identical in look and wording to the eye's (Mark, 2026-07-27).
                    Button("Reset defaults") {
                        settings.setDrawSteps(spec.default, for: settings.selectedDrawer)
                    }
                }
            }

            // ── PARKED: the hand's system prompt (art-direction mode). ──
            // Deactivated 2026-07-16 — see the `handSection` note and Settings. The hand draws
            // the eye's words, clean. Kept commented so reviving it is trivial:
            //
            // if DrawerLoader.isAvailable(settings.selectedDrawer) {
            //     TextEditor(text: $settings.handPrompt)
            //         .font(.system(.footnote, design: .monospaced))
            //         .frame(minHeight: 90)
            //         .focused($promptFocused)
            //         .overlay(alignment: .topLeading) {
            //             if settings.handPrompt.isEmpty {
            //                 Text("e.g. oil painting · charcoal sketch · leave blank to draw the words as they are")
            //                     .font(.footnote).foregroundStyle(.tertiary)
            //                     .padding(.top, 8).allowsHitTesting(false)
            //             }
            //         }
            //     Button("Clear the hand's prompt") { promptFocused = false; settings.handPrompt = "" }
            //         .disabled(settings.handPrompt.isEmpty)
            // }
        } header: {
            Text("Frame 3 · The Hand — how it draws")
        } footer: {
            Text("The hand draws the scene again from the eye's words — it never sees your photograph. When a description runs long, the same eye first shortens it to fit; frame 2 can show either the eye's full words or that shorter version. More steps mean more detail and a little more time; drawing adds several seconds to a shot.")
        }
    }

    // MARK: - Factory reset

    private var resetSection: some View {
        Section {
            Button("Reset everything to factory settings", role: .destructive) {
                confirmingReset = true
            }
        } footer: {
            Text("Every setting here is remembered when you put the camera down. This puts all of them back.")
        }
        .confirmationDialog("Reset everything to factory settings?",
                            isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Reset everything", role: .destructive) {
                promptFocused = false
                settings.resetEverything()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The eye's system prompt, the temperature, the layout, and the drawing settings all go back to how the camera shipped. Your photographs are untouched.")
        }
    }

    // MARK: - About

    /// The studio's shared About screen (`AboutView`, LEGO 33). Pushed like the Model
    /// Library — a sibling destination, not a modal — so the back-swipe is consistent.
    /// Carries Thomas's identity and version, our own MIT license, and the licenses of
    /// every open-source component that ships inside the binary.
    private var aboutSection: some View {
        Section {
            NavigationLink {
                AboutView.thomas
            } label: {
                Label("About Thomas", systemImage: "info.circle")
            }
        }
    }

    #if DEBUG
    // MARK: - Antenna (DEBUG-only local API address + token)
    //
    // Surfaces the local HTTP API's base URL and bearer token, each with a copy button,
    // so reaching the antenna from a host (Claude Code's harness) is two taps instead of
    // grepping a redacted console log or digging into the throwaway ContentView
    // scaffolding, which is where the only other on-screen copy lived. DEBUG-only in
    // every sense: LocalAPIServer itself doesn't compile in Release, so neither does this
    // section. (Mark, 2026-07-25 — "ridiculous we struggle every time.")

    /// The antenna's base URL, recomputed each read so a changed Wi-Fi address shows live.
    private var antennaBaseURL: String {
        "http://\(LocalAPIServer.localIPAddress()):\(LocalAPIServer.port)"
    }

    /// Copy `value` to the clipboard and flash the checkmark on `field` for a beat.
    private func copyAntennaField(_ value: String, field: String) {
        UIPasteboard.general.string = value
        copiedAntennaField = field
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if copiedAntennaField == field { copiedAntennaField = nil }
        }
    }

    private func antennaRow(label: String, value: String, field: String) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button {
                copyAntennaField(value, field: field)
            } label: {
                Image(systemName: copiedAntennaField == field ? "checkmark.circle.fill" : "doc.on.doc")
                    .imageScale(.large)
                    .foregroundStyle(copiedAntennaField == field ? Color.green : Color.accentColor)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Copy \(label)")
        }
    }

    private var antennaSection: some View {
        Section {
            if LocalAPIServer.shared.isRunning {
                antennaRow(label: "Base URL", value: antennaBaseURL, field: "url")
                antennaRow(label: "Token", value: LocalAPIServer.apiToken, field: "token")
            } else {
                Text("Antenna is off. Turn it on with the antenna button on the camera screen, then reopen this to see its address.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Antenna (Debug)")
        } footer: {
            Text("The local HTTP API for host-side testing over Wi-Fi. DEBUG builds only, Release ships no server. Tap the icon to copy a value.")
        }
    }
    #endif

    // MARK: - How the words meet the picture

    // MARK: - Developing the drawing, and how big it's saved

    /// Which developer finishes the drawing — Detailed (full VAE) or Fast (TAESD). Only in "The
    /// hand"'s world, so it hides when the drawing model isn't downloaded. The footer carries the
    /// one promise that makes two choices honest instead of three: whatever you pick, we override
    /// toward safety and will not let a shot crash.
    @ViewBuilder
    private var decoderSection: some View {
        // MLX-only: the Detailed/Fast (full-VAE vs TAESD) choice is a property of the MLX draw
        // pipeline. The CoreML hand decodes inside its own package, so this section hides for it.
        if DrawerLoader.isAvailable(settings.selectedDrawer), selectedDrawerEngine == .mlx {
            Section {
                Picker("Developer", selection: $settings.decoderChoice) {
                    ForEach(DecoderChoice.allCases, id: \.self) { c in
                        Text(c.name).tag(c)
                    }
                }
            } header: {
                Text("Frame 3 · Developing the drawing")
            } footer: {
                Text(settings.decoderChoice == .detailed
                     ? "Detailed uses the full decoder — sharper, and truer to what the model drew. If your device is low on memory for a shot, Thomas quietly switches that one to Fast so the drawing still finishes instead of failing."
                     : "Fast uses a tiny, low-memory decoder — softer and less detailed, but it draws in almost any conditions. On a dreamy re-imagining, the softness can read as intentional.")
            }
        }
    }

    /// The drawing's size, and which upscaler enlarges it. Only in "The hand"'s world — it's
    /// about frame 3, so it hides when the drawing model isn't downloaded.
    ///
    /// The model draws at 512²; larger sizes upscale AFTER the draw, where it's cheap and
    /// never touches the memory spike (Mark: *"I really don't wanna push our luck"* on
    /// generating bigger). Native is the honest baseline. The upscaler picker only matters
    /// when a larger size is chosen, so it's tucked below and its choice explained.
    @ViewBuilder
    private var sizeSection: some View {
        if DrawerLoader.isAvailable(settings.selectedDrawer) {
            Section {
                Picker("Size", selection: $settings.drawingSize) {
                    ForEach(DrawingSize.allCases, id: \.self) { size in
                        Text(size.name).tag(size)
                    }
                }
                if settings.drawingSize != .native {
                    Picker("Upscaler", selection: $settings.upscaler) {
                        ForEach(UpscaleMethod.allCases, id: \.self) { m in
                            Text(m.name).tag(m)
                        }
                    }
                }
            } header: {
                Text("Frame 3 · The drawing's size")
            } footer: {
                Text(settings.drawingSize == .native
                     ? "The hand draws at 512 pixels — small next to your photograph. Larger sizes enlarge the drawing after it's made, which is quick and doesn't strain memory."
                     : "MetalFX is Apple's GPU upscaler — sharper, and it falls back to Core Image on any device that doesn't support it. Core Image is softer; on a dreamy re-imagining that can read as intentional. The enlarging happens after the draw, so it costs no extra memory.")
            }
        }
    }

    /// What the current eye/hand switches can produce — the two facts the layout list filters by.
    /// `hasEye` = the eye is on (words exist); `hasHand` = the third frame is on AND a drawer is
    /// installed (a drawing exists). See `Layout.isAvailable`.
    private var layoutHasEye: Bool { settings.useEye }
    private var layoutHasHand: Bool {
        settings.drawsThirdFrame && DrawerLoader.isAvailable(settings.selectedDrawer)
    }

    /// If the selected layout can no longer be produced (a toggle flipped), snap to the richest
    /// available one. This is what retires the "triptych stuck on when the hand's off" bug — you can
    /// never be left holding a layout the current state can't make. Called from the toggles' onChange.
    private func snapLayoutIfNeeded() {
        if !settings.layout.isAvailable(hasEye: layoutHasEye, hasHand: layoutHasHand) {
            settings.layout = Layout.fallback(hasEye: layoutHasEye, hasHand: layoutHasHand)
        }
    }

    private var layoutSection: some View {
        Section {
            // Grouped by family, and — the point of the rebuild (Mark, 2026-07-27) — each family
            // shows ONLY the variants the current eye/hand switches can actually produce, so no
            // selectable layout ever conflicts with the toggles. Short names inside the sections
            // (the header carries the family) so the menu reads cleanly instead of wrapping.
            Menu {
                ForEach(LayoutCategory.allCases, id: \.self) { category in
                    let items = Layout.allCases.filter {
                        $0.category == category
                            && $0.isAvailable(hasEye: layoutHasEye, hasHand: layoutHasHand)
                    }
                    if !items.isEmpty {
                        Section(category.title) {
                            ForEach(items, id: \.self) { layout in
                                Button {
                                    settings.layout = layout
                                } label: {
                                    if settings.layout == layout {
                                        Label(layout.shortName, systemImage: "checkmark")
                                    } else {
                                        Text(layout.shortName)
                                    }
                                }
                            }
                        }
                    }
                }
            } label: {
                HStack {
                    Text("Layout")
                    Spacer()
                    Text(settings.layout.name).foregroundStyle(.secondary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.footnote).foregroundStyle(.tertiary)
                }
            }
            .tint(.primary)
        } header: {
            Text("Layout")
        } footer: {
            Text("Only the layouts your current eye and hand can make are shown. Superimposed lays the words over the photo — or over the drawing. Single keeps just one panel: the words, the drawing, or the photo. Diptych sets two side by side. Triptych stitches all three frames into one plate. Separate saves each as its own file. The square layouts show a square guide in the viewfinder, so you frame for the crop.")
        }
    }
}

/// The preset list. Each one states what it's for in plain language, and selecting it
/// **fills the editor** rather than hiding a configuration.
private struct PresetPicker: View {
    @Environment(\.dismiss) private var dismiss
    let choose: (Preset) -> Void

    var body: some View {
        NavigationStack {
            List(Preset.all) { preset in
                Button {
                    choose(preset)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(preset.name).font(.headline)
                        Text(preset.note)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("temperature \(String(format: "%.2f", preset.temperature))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Presets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// ==== LEGO END: 21 PreferencesView (The Film Drawer) ====
