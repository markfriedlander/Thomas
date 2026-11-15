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
        didSet {
            store(drawsThirdFrame, "drawsThirdFrame")
            snapLayoutIfNeeded()
            adoptDrawingLayoutIfNeeded(couldDrawBefore: oldValue && DrawerLoader.isAvailable(selectedDrawer))
        }
    }
    /// Which hand draws the third frame — the drawer's shared-store repo id. The counterpart to
    /// `seer` for the eye: `drawsThirdFrame` is the on/off, this is the which. Only sd-turbo
    /// exists today, so it is effectively constant until a second drawer (and a picker) arrive;
    /// it is stored now so each shot can freeze the drawer it was taken with (see `ShotConfig`).
    var selectedDrawer: String {
        didSet {
            store(selectedDrawer, "selectedDrawer")
            snapLayoutIfNeeded()
            adoptDrawingLayoutIfNeeded(couldDrawBefore: drawsThirdFrame && DrawerLoader.isAvailable(oldValue))
        }
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
            snapLayoutIfNeeded()
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
    /// The photograph's shape (item 17): 4:3, the whole sensor (default), or 16:9, taller and narrower.
    var pictureShape: PictureShape {
        didSet { store(pictureShape.rawValue, "pictureShape") }
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
    /// Developer Tray: which real view of the drawing a shot records, the working image or the
    /// engine's best guess (Mark, 2026-11-05: a switch, never both at once). Frozen per shot.
    var developView: DevelopView {
        didSet { store(developView.rawValue, "developView") }
    }
    /// Developer Tray: what a shot also saves to Photos about its own development. Default off, so a
    /// shot does no extra work unless asked (Mark's rule: no needless processing, all options).
    var developmentKeepsake: DevelopmentKeepsake {
        didSet { store(developmentKeepsake.rawValue, "developmentKeepsake") }
    }
    /// Also save each frame as its own file, beside the print (2026-11-14; see `SeparateFiles`).
    var separateFiles: SeparateFiles {
        didSet { store(separateFiles.rawValue, "separateFiles") }
    }
    /// The Dark Room's negatives: how many recent shots keep their workings for the Developer Tray
    /// (NegativeStore). Mark, 2026-11-05: 20 by default, people may keep more. Lowering it prunes.
    var negativesToKeep: Int {
        didSet {
            store(negativesToKeep, "negativesToKeep")
            let n = negativesToKeep
            Task { await NegativeStore.shared.prune(to: n) }
        }
    }
    static let negativeChoices = [20, 50, 100, 200]

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
        pictureShape = PictureShape(rawValue: d.string(forKey: "pictureShape") ?? "") ?? .fourThree
        decoderChoice = DecoderChoice(rawValue: d.string(forKey: "decoderChoice") ?? "") ?? .detailed
        stampRawCoordinates = d.bool(forKey: "stampRawCoordinates")   // default false
        developView = DevelopView(rawValue: d.string(forKey: "developView") ?? "") ?? .working
        developmentKeepsake = DevelopmentKeepsake(rawValue: d.string(forKey: "developmentKeepsake") ?? "") ?? .off
        negativesToKeep = (d.object(forKey: "negativesToKeep") as? Int) ?? 20
        separateFiles = SeparateFiles(rawValue: d.string(forKey: "separateFiles") ?? "") ?? .off
        // Someone who had chosen a Separate layout keeps their separate files, now as the add-on, with
        // the richest combined print their eye and hand can make (2026-11-14).
        if layout == .separateNative || layout == .separateSquare {
            separateFiles = layout == .separateSquare ? .square : .native
            layout = Layout.fallback(hasEye: useEye, hasHand: handWillDraw)
            // didSet doesn't run inside init, so store the move by hand (once).
            d.set(layout.rawValue, forKey: "layout")
            d.set(separateFiles.rawValue, forKey: "separateFiles")
        }
    }

    /// Keep the selected layout producible. Whenever the eye/hand availability changes (`useEye`,
    /// `drawsThirdFrame`, `selectedDrawer`), a layout that can no longer be made snaps to the richest
    /// one that can. This used to live in Preferences' `.onChange`, so any non-UI mutation (the
    /// antenna's /settings, a future preset) bypassed it and could leave a greyed-out, un-drawable
    /// layout selected. Enforced HERE in the model (Principle 7, matching `useEye`'s own enforcement),
    /// so it holds however those are changed and can't be bypassed. This is the invariant that retires
    /// the "triptych stuck on with the hand off" bug (2026-07-30 antenna-parity fix).
    /// Whether a shot taken now would really get a drawing: drawing on, the hand installed, and, with the
    /// eye off (the silent loop), a hand that can read a photo (only the Core ML hand can). One truth for
    /// every screen and the layout rules (independent review, 2026-11-14: the screens treated SD-Turbo in
    /// the silent loop as drawing, and offered layouts that then had nothing to show).
    var handWillDraw: Bool {
        drawsThirdFrame && DrawerLoader.isAvailable(selectedDrawer)
            && (useEye || ModelCatalog.model(id: selectedDrawer)?.engine == .coreML)
    }

    private func snapLayoutIfNeeded() {
        let hasEye = useEye
        let hasHand = handWillDraw
        if !layout.isAvailable(hasEye: hasEye, hasHand: hasHand) {
            layout = Layout.fallback(hasEye: hasEye, hasHand: hasHand)
        }
    }

    /// The other half of `snapLayoutIfNeeded`. Snapping moves DOWN when content disappears; this
    /// moves UP once, at the moment drawing becomes possible (the toggle turned on, or the selected
    /// hand became a downloaded one), if the current layout has no place for a drawing. Without it a
    /// fresh install stays on `.superimposed` forever: the user downloads a hand, turns drawing on,
    /// and never sees a drawing (Mark approved the fix 2026-11-05). Only on that transition, so a
    /// user who later picks a no-drawing layout on purpose keeps it. In the model, not the screen
    /// (Principle 7), so the antenna and the silent-loop switch get it too.
    private func adoptDrawingLayoutIfNeeded(couldDrawBefore: Bool) {
        let canDrawNow = handWillDraw
        guard canDrawNow, !couldDrawBefore, !layout.usesDrawing else { return }
        layout = Layout.drawingLayout(hasEye: useEye)
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
        pictureShape = .fourThree
        decoderChoice = .detailed
        stampRawCoordinates = false
        developView = .working
        developmentKeepsake = .off
        separateFiles = .off
        negativesToKeep = 20
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
            note: "Pushes for detail - texture, edges, small things. Where naming breaks down.",
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

/// The four rooms behind Preferences' front door, in the order a shot travels (Mark, 2026-11-14: the tray's
/// LENS / EYE / HAND pills across the top, so nobody learns a new system and the path runs left to right).
enum PrefsPage: String, CaseIterable, Identifiable, Hashable {
    case lens, eye, hand, print
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
    var kicker: String {
        switch self {
        case .lens:  return "FRAME 1 · THE LENS"
        case .eye:   return "FRAME 2 · THE EYE"
        case .hand:  return "FRAME 3 · THE HAND"
        case .print: return "THE PRINT"
        }
    }
    var heading: String {
        switch self {
        case .lens:  return "What the camera takes"
        case .eye:   return "How it sees"
        case .hand:  return "How it draws"
        case .print: return "What lands in Photos"
        }
    }
    var spokenName: String {
        switch self {
        case .lens: return "Lens"
        case .eye: return "Eye"
        case .hand: return "Hand"
        case .print: return "Print"
        }
    }
}

/// The deeper story behind a setting's "?" (design pass 2026-11-14, Mark: one plain line on the page, the
/// rest a tap away, as the tray's "?" does). Nothing is hidden; it is one tap further in.
struct PrefHelp: Identifiable, Equatable {
    let id: String
    let kicker: String
    let title: String
    let body: String
}

/// The last shot the Dark Room still keeps, for the front door's three frames and the blurred backdrop.
struct PrefsLastShot {
    var photo: UIImage?
    var words: String?
    var drawing: UIImage?
}

struct PreferencesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = Settings.shared
    /// The one shared catalog (Hal's pattern): reading its refreshed models is what makes the names and
    /// availability here re-derive when a model is downloaded or deleted anywhere.
    @State private var catalog = ModelCatalogService.shared
    /// The front door is the root; a page is pushed on top. The pills change `page` without pushing again.
    @State private var path: [PrefsPage] = []
    @State private var page: PrefsPage = .eye
    @State private var help: PrefHelp?
    @State private var lastShot: PrefsLastShot?
    @State private var confirmingReset = false
    @State private var showingLayerOneInfo = false
    @State private var showingDarkRoom = false
    @FocusState private var promptFocused: Bool
    #if DEBUG
    /// Which antenna field last flashed "copied" (nil = none). See antennaCard.
    @State private var copiedAntennaField: String?
    #endif

    var body: some View {
        NavigationStack(path: $path) {
            frontDoor
                .navigationDestination(for: PrefsPage.self) { _ in PrefsPageHost(page: $page) { pageScreen($0) } }
            #if DEBUG
                // Human parity: push the SAME screens the rows push, driven by the antenna's bridge flags.
                .navigationDestination(isPresented: Binding(
                    get: { AntennaUIBridge.shared.tapModelLibrary },
                    set: { AntennaUIBridge.shared.tapModelLibrary = $0 }
                )) { ModelLibraryView() }
                .navigationDestination(isPresented: Binding(
                    get: { AntennaUIBridge.shared.tapAbout },
                    set: { AntennaUIBridge.shared.tapAbout = $0 }
                )) { AboutView.thomas }
            #endif
        }
        .overlay { if let help { PrefHelpCard(help: help) { self.help = nil }.transition(.opacity) } }
        .animation(.easeInOut(duration: 0.2), value: help)
        // Thomas's own look (Mark: "colorful, artistic, and celebratory"), the tray's dark ground.
        .preferredColorScheme(.dark)
        .tint(.white)
        .macResizablePresentation(isPresented: $showingDarkRoom) { DarkRoomView() }
        // Alerts hang off a stable parent, never a view that re-renders as `settings` changes (a sheet or
        // alert bound to a rebuilt view dismisses itself; learned with the old presets sheet, 2026-07-16).
        .alert("Why can't I change this line?", isPresented: $showingLayerOneInfo) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This keeps the eye's description short enough for the hand to draw from - the drawing model can only read about fifty words, and a longer description used to crash the camera. It's locked so it can't be removed by accident. Everything below it is yours.")
        }
        .task { lastShot = await Self.loadLastShot() }
        #if DEBUG
        .onAppear { openForAntenna() }
        .onChange(of: AntennaUIBridge.shared.scrollPreferencesTo) { openForAntenna() }
        .onChange(of: AntennaUIBridge.shared.prefsHelp) { _, key in
            guard let key else { return }
            help = helpTopic(key)
            AntennaUIBridge.shared.prefsHelp = nil
        }
        #endif
        // ⏸️ PRESETS hidden since 2026-07-27 (Mark); on the after-2.0 list to reconsider as a whole-camera
        // preset (Mark, 2026-11-14 night: "I can see where I would put it"). `Preset`/`PresetPicker` are kept.
    }

    // MARK: - The front door

    private var frontDoor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(lastShot == nil ? "YOUR NEXT SHOT WILL APPEAR HERE" : "YOUR LAST SHOT")
                    .font(.caption.weight(.bold)).tracking(1.4).foregroundStyle(.secondary)
                    .padding(.top, 4)
                lastShotFrames
                Text("YOUR CAMERA, AS IT IS SET NOW")
                    .font(.caption.weight(.bold)).tracking(1.4).foregroundStyle(.secondary)
                    .padding(.top, 4)
                PrefCard(padding: false) {
                    ForEach(Array(PrefsPage.allCases.enumerated()), id: \.element) { i, p in
                        if i > 0 { Divider().overlay(Color.white.opacity(0.12)) }
                        summaryRow(p)
                    }
                }
                PrefCard(padding: false) {
                    NavigationLink { ModelLibraryView() } label: {
                        doorRow(title: "Model Library", subtitle: "Every eye and hand: what each shows, how long each takes")
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(Color.white.opacity(0.12))
                    // Reachable even when nothing is developing: the only door to shots waiting on a model.
                    Button { showingDarkRoom = true } label: {
                        doorRow(title: "The Dark Room", subtitle: "What's developing, and the negatives it keeps")
                    }
                    .buttonStyle(.plain)
                }
                Text("Tap a frame or a row to change how that part of a shot is made.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).multilineTextAlignment(.center)
                HStack(spacing: 28) {
                    NavigationLink("About Thomas") { AboutView.thomas }
                        .foregroundStyle(.white.opacity(0.8))
                    Button("Reset everything", role: .destructive) { confirmingReset = true }
                        .foregroundStyle(Color(red: 1, green: 0.41, blue: 0.38))
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity)
                #if DEBUG
                antennaCard
                #endif
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }
        .background(backdrop)
        .navigationTitle("Preferences")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The same title treatment as the Dark Room (Mark, 2026-11-14): heavy capitals, tracked.
            ToolbarItem(placement: .principal) {
                Text("PREFERENCES").font(.headline.weight(.heavy)).tracking(2)
                    .accessibilityLabel("Preferences")
                    .accessibilityAddTraits(.isHeader)
            }
            ToolbarItem(placement: .cancellationAction) {
                Button(role: .close) { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { help = helpTopic("preferences") } label: { Image(systemName: "questionmark") }
                    .accessibilityLabel("About Preferences")
            }
        }
        .confirmationDialog("Reset everything to factory settings?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Reset everything", role: .destructive) {
                promptFocused = false
                settings.resetEverything()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The eye's system prompt, the temperature, the layout, and the drawing settings all go back to how the camera shipped. Your photographs are untouched.")
        }
    }

    /// The last shot's photo, words and drawing, each a door to the frame it came from. Before any shot is
    /// kept: empty outlines, never a sample picture (everything shown is real).
    private var lastShotFrames: some View {
        HStack(spacing: 6) {
            frameDoor(.lens) { pictureTile(lastShot?.photo) }
            frameDoor(.eye) { wordsTile(lastShot?.words) }
            frameDoor(.hand) { pictureTile(lastShot?.drawing) }
        }
    }

    private func frameDoor<Tile: View>(_ p: PrefsPage, @ViewBuilder tile: () -> Tile) -> some View {
        Button { open(p) } label: {
            VStack(spacing: 6) {
                tile()
                Text(p.label).font(.caption.weight(.heavy)).tracking(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(p.spokenName) settings")
        .accessibilityValue(p == .eye ? (lastShot?.words.map { "Your last shot's words: \($0)" } ?? "") : "")
        .accessibilityAddTraits(.isButton)
    }

    private func pictureTile(_ image: UIImage?) -> some View {
        Color.clear.aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func wordsTile(_ words: String?) -> some View {
        Color.clear.aspectRatio(1, contentMode: .fit)
            .overlay(alignment: .topLeading) {
                if let words {
                    Text(words)
                        .font(.system(size: 9.5)).foregroundStyle(Color(white: 0.08))
                        .padding(7)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(Color(red: 0.957, green: 0.945, blue: 0.918))
                } else {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func summaryRow(_ p: PrefsPage) -> some View {
        Button { open(p) } label: {
            HStack(spacing: 12) {
                Text(p.label).font(.caption.weight(.heavy)).tracking(1).foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize()
                    .frame(minWidth: 58, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary(p)).font(.callout.weight(.semibold))
                    Text(summaryNote(p)).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(p.spokenName): \(summary(p))")
    }

    private func doorRow(title: String, subtitle: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(subtitle).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    /// The settings at a glance, the way an SLR's info screen reads.
    private func summary(_ p: PrefsPage) -> String {
        switch p {
        case .lens:
            let place = settings.stampRawCoordinates ? "raw coordinates" : "place names"
            return Lens.offersSixteenNine ? "\(settings.pictureShape.name) · \(place)" : place.prefix(1).uppercased() + place.dropFirst()
        case .eye:
            guard settings.useEye else { return "Off · the silent loop" }
            let model = catalog.model(for: settings.seer)
            return model.controls.contains(.temperature)
                ? "\(settings.seer.name) · temperature \(String(format: "%.2f", settings.temperature))" : settings.seer.name
        case .hand:
            guard handDraws, let model = selectedDrawerModel else { return "Off" }
            var s = model.displayName
            if model.controls.contains(.steps) { s += " · \(settings.currentDrawerSteps) steps" }
            return s + " · \(settings.drawingSize.pixels) px"
        case .print:
            var extras = 0
            if settings.separateFiles != .off { extras += 1 }
            if handDraws, settings.developmentKeepsake != .off { extras += settings.developmentKeepsake == .both ? 2 : 1 }
            return extras == 0 ? settings.layout.name : "\(settings.layout.name) · +\(extras)"
        }
    }

    private func summaryNote(_ p: PrefsPage) -> String {
        switch p {
        case .lens:  return Lens.offersSixteenNine ? "Picture shape, place stamp" : "Place stamp"
        case .eye:   return "Which eye, its system prompt, temperature"
        case .hand:  return "Which hand, steps, size"
        case .print: return "Layout, and what's saved beside it"
        }
    }

    private func open(_ p: PrefsPage) {
        page = p
        if path.isEmpty { path = [p] }
    }

    // MARK: - The pages (the tray's pills across the top)

    /// One page, drawn for `current`, the live choice passed in through `PrefsPageHost`'s binding. (Reading the
    /// `page` state directly inside a navigation destination drew the page from a stale copy: tapping LENS on the
    /// front door opened EYE, found 2026-11-14 on the phone and by a click on the Mac.)
    private func pageScreen(_ current: PrefsPage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(current.kicker).font(.caption.weight(.bold)).tracking(1.4).foregroundStyle(.secondary)
                    Text(current.heading).font(.title.weight(.heavy))
                }
                .padding(.horizontal, 4).padding(.top, 4)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                switch current {
                case .lens:  lensPage
                case .eye:   eyePage
                case .hand:  handPage
                case .print: printPage
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
            .id(current)
            .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.2), value: current)
        .background(backdrop)
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .principal) { pills(current) }
                .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .primaryAction) {
                Button { help = helpTopic("frame.\(current.rawValue)") } label: { Image(systemName: "questionmark") }
                    .accessibilityLabel("About \(current.spokenName.lowercased())")
            }
            // The system prompt is a multi-line editor with no Return key to escape with. This is the way out.
            ToolbarItem(placement: .keyboard) {
                HStack { Spacer(); Button("Done") { promptFocused = false } }
            }
        }
    }

    private func pills(_ current: PrefsPage) -> some View {
        HStack(spacing: 2) {
            ForEach(PrefsPage.allCases) { p in
                let on = current == p
                Button { promptFocused = false; page = p } label: {
                    Text(p.label).font(.caption.weight(.bold)).tracking(0.6)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .foregroundStyle(on ? Color.black : Color.white.opacity(0.85))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(on ? Color.white : Color.clear, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(p.spokenName)
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityShowsLargeContentViewer { Text(p.label) }
            }
        }
        .padding(3)
        .background(.ultraThinMaterial.opacity(0.85), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        // The pills grow with text size up to the largest standard size; past that a long press shows
        // the label large (as the tray's do).
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    // MARK: Lens

    @ViewBuilder private var lensPage: some View {
        if Lens.offersSixteenNine {
            PrefCard {
                Text("Picture shape").font(.headline)
                Picker("Picture shape", selection: $settings.pictureShape) {
                    ForEach(PictureShape.allCases, id: \.self) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                // Light, so the choice reads clearly on the dark card (the dark style was faint on the phone).
                .environment(\.colorScheme, .light)
                PrefLine(settings.pictureShape == .fourThree
                         ? "The whole sensor: the widest view."
                         : "Taller and narrower, like a video frame; fills more of the screen.",
                         help: helpTopic("shape"), open: $help)
            }
        }
        PrefCard {
            // Without Location permission there is no place to stamp at all; say so rather than offer a
            // choice that does nothing (independent review, 2026-11-14).
            if !PrivacyMonitor.shared.isLocationAuthorized {
                Label("Location is off for Thomas, so the footer has no place stamp.", systemImage: "location.slash")
                    .font(.subheadline).foregroundStyle(.orange)
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    Link("Turn it on in Settings", destination: url).font(.subheadline.weight(.semibold))
                }
                Divider().overlay(Color.white.opacity(0.12))
            }
            Toggle("Stamp raw coordinates", isOn: $settings.stampRawCoordinates).font(.headline).tint(.green)
            // Only a downloaded eye keeps the whole shot on the device; Apple's eye may use Apple's servers
            // when online (as the privacy lock says), so the promise is made only when it is true.
            PrefLine(settings.stampRawCoordinates
                     ? (settings.seer.token == "apple"
                        ? "Latitude and longitude, with no lookup."
                        : "Latitude and longitude, with no lookup: with this eye, nothing about the shot leaves your \(ThisDevice.deviceKind).")
                     : "The footer names the place, looked up by Apple's mapping service.",
                     help: helpTopic("location"), open: $help)
        }
    }

    // MARK: Eye

    @ViewBuilder private var eyePage: some View {
        PrefCard {
            Toggle("Use the eye", isOn: $settings.useEye).font(.headline).tint(.green)
            if settings.useEye {
                Divider().overlay(Color.white.opacity(0.12))
                modelRow(catalog.model(for: settings.seer), verb: "to look")
                if !settings.seer.isAvailable {
                    Text(unavailableReason).font(.footnote).foregroundStyle(.orange)
                }
                PrefLine("The eye looks at your photo and says what it sees.", help: helpTopic("eye"), open: $help)
            } else {
                PrefLine("The silent loop: the hand reads your photo directly, with no words in between. Set it up under HAND.",
                         help: helpTopic("silentloop"), open: $help)
                if selectedDrawerEngine != .coreML {
                    Text("The silent loop only draws with the SD-2.1 (Core ML) hand. Download and choose it in the Model Library; until then a shot keeps the photo and your instruction.")
                        .font(.footnote).foregroundStyle(.orange)
                }
            }
        }
        if settings.useEye {
            PrefCard {
                Text("System prompt").font(.headline)
                // Layer 1: locked, but SHOWN (Principle 2): the line the app depends on, displayed and locked.
                // It is the CURRENT eye's Layer 1, so switching eyes honestly shows its own line.
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.tertiary).padding(.top, 3)
                    Text(PromptLayers.layerOne(forRepo: settings.seer.token))
                        .font(.system(.footnote, design: .monospaced)).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button { promptFocused = false; showingLayerOneInfo = true } label: {
                        Image(systemName: "info.circle").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Why this line is locked")
                }
                // A system prompt, called a system prompt, every word readable and changeable (Layer 2).
                TextEditor(text: $settings.systemPrompt)
                    .font(.system(.footnote, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 150)
                    .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .focused($promptFocused)
                    .accessibilityLabel("System prompt")
                PrefLine("The eye's standing instructions, sent with every photo.", help: helpTopic("prompt"), open: $help)
            }
            // Only for an eye that truly takes it (its record's `controls`; item 11).
            if ModelCatalog.model(for: settings.seer).controls.contains(.temperature) {
                PrefCard {
                    valueHeader("Temperature", String(format: "%.2f", settings.temperature))
                    Slider(value: $settings.temperature, in: 0...1.5, step: 0.05)
                        .accessibilityLabel("Temperature")
                    PrefLine("Higher reaches for less likely words.", help: helpTopic("temperature"), open: $help)
                }
            }
            // Only matters when the hand draws: with no drawing, nothing is shortened for it.
            if handDraws {
                PrefCard {
                    pickerRow("Frame 2 shows", selection: $settings.frameTwoShows, options: FrameTwoWords.allCases) { $0.name }
                    PrefLine("Only differs when a long description was shortened for the hand.", help: helpTopic("frametwo"), open: $help)
                }
            }
            Button("Reset the eye's defaults") {
                promptFocused = false
                settings.resetPromptToDefault()
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 4)
        }
    }

    // MARK: Hand

    @ViewBuilder private var handPage: some View {
        PrefCard {
            // Which hand is chosen in the Model Library, not here (2026-07-27): one selection home.
            Toggle("Draw the third frame", isOn: $settings.drawsThirdFrame).font(.headline).tint(.green)
                .disabled(!DrawerLoader.isAvailable(settings.selectedDrawer))
            Divider().overlay(Color.white.opacity(0.12))
            if let model = selectedDrawerModel { modelRow(model, verb: "to draw") }
            if !DrawerLoader.isAvailable(settings.selectedDrawer) {
                Text("\(selectedDrawerModel?.displayName ?? "This hand") isn't downloaded - get it in the Model Library.")
                    .font(.footnote).foregroundStyle(.orange)
            }
            PrefLine(settings.useEye
                     ? "The hand draws the scene again from the eye's words. It never sees your photo."
                     : (selectedDrawerEngine == .coreML
                        ? "With the eye off, the hand reads your photo directly."
                        : "With the eye off, only the SD-2.1 hand can draw, so nothing is drawn now."),
                     help: helpTopic("hand"), open: $help)
        }
        // The silent loop's own controls: only with the eye off AND a hand that can do it (Core ML).
        if !settings.useEye {
            PrefCard {
                Text("Silent loop").font(.headline)
                TextField("e.g. an oil painting · a charcoal sketch · leave blank",
                          text: Binding(get: { settings.handPrompt },
                                        set: { settings.handPrompt = String($0.prefix(Self.handPromptMaxChars)) }),
                          axis: .vertical)
                    .lineLimit(1...3)
                    .font(.system(.footnote, design: .monospaced))
                    .padding(8)
                    .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityLabel("The hand's instruction")
                HStack { Spacer(); Text("\(settings.handPrompt.count)/\(Self.handPromptMaxChars)").font(.caption2).foregroundStyle(.tertiary) }
                if selectedDrawerEngine == .coreML {
                    valueHeader("Transform", String(format: "%.2f", settings.handStrength))
                    Slider(value: $settings.handStrength, in: 0.2...0.9, step: 0.05).accessibilityLabel("Transform")
                    PrefLine("Low keeps the photo's forms; high reinvents them.", help: helpTopic("silentloop"), open: $help)
                } else {
                    PrefLine("Your instruction is kept as the words beside your photo.", help: helpTopic("silentloop"), open: $help)
                }
            }
        }
        if handDraws {
            // Honest terminology (Principle 2): denoising steps, the model's own word. Per hand, because the
            // useful range is the model's own (turbo a handful, SD-2.1 about twenty).
            if let model = selectedDrawerModel, model.controls.contains(.steps), let spec = model.drawSteps {
                PrefCard {
                    valueHeader("Steps", "\(settings.currentDrawerSteps)")
                    Slider(value: Binding(get: { Double(settings.currentDrawerSteps) },
                                          set: { settings.currentDrawerSteps = Int($0.rounded()) }),
                           in: Double(spec.range.lowerBound)...Double(spec.range.upperBound), step: 1)
                        .accessibilityLabel("Steps")
                    PrefLine("More steps, more detail, and more time.", help: helpTopic("steps"), open: $help)
                    Button("Reset the hand's defaults") { settings.setDrawSteps(spec.default, for: settings.selectedDrawer) }
                        .font(.subheadline.weight(.semibold))
                }
            }
            // MLX only: the full decoder or TAESD. The Core ML hand decodes inside its own package.
            if selectedDrawerEngine == .mlx {
                PrefCard {
                    pickerRow("Decoder", selection: $settings.decoderChoice, options: DecoderChoice.allCases) { $0.name }
                    PrefLine(settings.decoderChoice == .detailed ? "The full decoder: sharper, truer to what the model drew."
                                                                 : "A tiny decoder: softer, and it draws in almost any conditions.",
                             help: helpTopic("decoder"), open: $help)
                }
            }
            PrefCard {
                pickerRow("Size", selection: $settings.drawingSize, options: DrawingSize.allCases) { $0.name }
                if settings.drawingSize != .native {
                    pickerRow("Upscaler", selection: $settings.upscaler, options: UpscaleMethod.allCases) { $0.name }
                }
                PrefLine(settings.drawingSize == .native ? "The hand draws at 512 pixels, small next to your photo."
                                                         : "Enlarged after the drawing is made, without straining memory.",
                         help: helpTopic("size"), open: $help)
            }
            PrefCard {
                pickerRow("Watch the drawing as", selection: $settings.developView, options: DevelopView.allCases) { $0.name }
                PrefLine(settings.developView == .working ? "What the hand holds at each step: static becoming a picture."
                                                          : "Its prediction of the finished drawing at each step.",
                         help: helpTopic("developview"), open: $help)
            }
        }
    }

    // MARK: Print

    @ViewBuilder private var printPage: some View {
        PrefCard {
            Text("Layout").font(.headline)
            // Only combined prints, grouped by family and named, and only those the current eye and hand
            // can make (Mark, 2026-07-27), so no choice ever conflicts with the switches. Drawn with the
            // last shot's own pictures where there is one.
            ForEach(layoutFamilies, id: \.self) { family in
                let items = availableLayouts.filter { $0.category == family }
                if !items.isEmpty {
                    Text(family.title.uppercased()).font(.caption2.weight(.bold)).tracking(1).foregroundStyle(.secondary)
                        .padding(.top, 2)
                        .accessibilityAddTraits(.isHeader)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 4), spacing: 10) {
                        ForEach(items, id: \.self) { layout in
                            Button { settings.layout = layout } label: {
                                VStack(spacing: 4) {
                                    LayoutThumb(layout: layout, photo: lastShot?.photo, drawing: lastShot?.drawing,
                                                selected: settings.layout == layout)
                                    Text(layout.shortName).font(.caption2)
                                        .foregroundStyle(settings.layout == layout ? .white : .secondary)
                                        .multilineTextAlignment(.center).lineLimit(2)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(layout.name.replacingOccurrences(of: " · ", with: ", "))
                            .accessibilityAddTraits(settings.layout == layout ? [.isButton, .isSelected] : .isButton)
                        }
                    }
                }
            }
            PrefLine(layoutLine(settings.layout), help: helpTopic("layout"), open: $help)
        }
        // What comes along with the print, each on or off (Mark, 2026-11-14).
        PrefCard {
            Text("Also save to Photos").font(.headline)
            Toggle("Each frame as its own file", isOn: Binding(
                get: { settings.separateFiles != .off },
                set: { settings.separateFiles = $0 ? .native : .off }))
                .tint(.green)
            if settings.separateFiles != .off {
                Picker("Shape of the separate files", selection: $settings.separateFiles) {
                    Text(SeparateFiles.native.name).tag(SeparateFiles.native)
                    Text(SeparateFiles.square.name).tag(SeparateFiles.square)
                }
                .pickerStyle(.segmented)
                .environment(\.colorScheme, .light)
            }
            if handDraws {
                Toggle("A contact sheet of the drawing's steps", isOn: keepsakeBinding(sheet: true)).tint(.green)
                Toggle("A flipbook of the drawing's steps", isOn: keepsakeBinding(sheet: false)).tint(.green)
            }
            PrefLine(alsoSaveLine, help: helpTopic("keepsake"), open: $help)
        }
    }

    private var layoutFamilies: [LayoutCategory] { [.superimposed, .single, .diptych, .triptych] }

    /// The contact sheet and flipbook as two switches over the one stored choice (off, either, or both).
    private func keepsakeBinding(sheet: Bool) -> Binding<Bool> {
        Binding(
            get: {
                let k = settings.developmentKeepsake
                return sheet ? (k == .contactSheet || k == .both) : (k == .flipbook || k == .both)
            },
            set: { on in
                let k = settings.developmentKeepsake
                var hasSheet = k == .contactSheet || k == .both
                var hasFlip = k == .flipbook || k == .both
                if sheet { hasSheet = on } else { hasFlip = on }
                settings.developmentKeepsake = hasSheet && hasFlip ? .both : hasSheet ? .contactSheet : hasFlip ? .flipbook : .off
            })
    }

    private var alsoSaveLine: String {
        var extras: [String] = []
        if settings.separateFiles != .off { extras.append(settings.separateFiles == .square ? "each frame as a square file" : "each frame as its own file") }
        if handDraws {
            switch settings.developmentKeepsake {
            case .contactSheet: extras.append("a contact sheet")
            case .flipbook:     extras.append("a flipbook")
            case .both:         extras.append("a contact sheet and a flipbook")
            case .off:          break
            }
        }
        guard !extras.isEmpty else { return "Just the print. Anything switched on here is saved beside it." }
        return "Beside the print: " + ListFormatter.localizedString(byJoining: extras) + "."
    }

    private var availableLayouts: [Layout] {
        Layout.allCases.filter { $0.category != .separate && $0.isAvailable(hasEye: settings.useEye, hasHand: handDraws) }
    }

    private func layoutLine(_ l: Layout) -> String {
        switch l {
        case .superimposed:          return "The eye's words laid over your photo."
        case .superimposedOnDrawing: return "The eye's words laid over the drawing."
        case .textOnly:              return "Just the words, on their own card."
        case .singleDrawing:         return "Just the drawing."
        case .singlePhoto:           return "Just your photo."
        case .diptychTextLeft:       return "The words, then your photo, side by side."
        case .diptychTextRight:      return "Your photo, then the words, side by side."
        case .diptychDrawingLeft:    return "The drawing, then your photo, side by side."
        case .diptychDrawingRight:   return "Your photo, then the drawing, side by side."
        case .triptychVertical:      return "Photo, words and drawing stacked on one plate."
        case .triptychHorizontal:    return "Photo, words and drawing side by side on one plate."
        case .separateNative, .separateSquare: return "Each frame as its own file."
        }
    }

    // MARK: - Pieces

    private func modelRow(_ model: CameraModel, verb: String) -> some View {
        NavigationLink { ModelLibraryView() } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName).font(.headline)
                    if let t = timeLine(model, verb: verb) {
                        Text(t).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                Text("Model Library").font(.subheadline).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The same honest timing the Model Library card shows (item 16): this device's own, else measured.
    private func timeLine(_ model: CameraModel, verb: String) -> String? {
        if let own = ModelTimings.typical(for: model.id) {
            return "About \(ModelTimingView.format(own.seconds)) \(verb) on this \(ThisDevice.deviceKind)"
        }
        if let measured = model.measuredSeconds {
            return "About \(ModelTimingView.format(measured)) \(verb) on an iPhone 16 Plus"
        }
        return nil
    }

    private func valueHeader(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline)
            Spacer()
            Text(value).font(.body.monospacedDigit()).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// A title and its menu on one line when they fit; stacked when they don't (large text, a long choice).
    /// Side by side at Mark's text size, "Frame 2 shows" and "What the hand received" overlapped the line
    /// below them (2026-11-14).
    private func pickerRow<T: Hashable>(_ title: String, selection: Binding<T>, options: [T], name: @escaping (T) -> String) -> some View {
        let menu = Picker(title, selection: selection) {
            ForEach(options, id: \.self) { Text(name($0)).tag($0) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        return ViewThatFits(in: .horizontal) {
            HStack {
                Text(title).font(.headline).lineLimit(1).fixedSize()
                Spacer(minLength: 8)
                menu.fixedSize()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).fixedSize(horizontal: false, vertical: true)
                menu.fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A soft, blurred copy of the last shot's drawing (or photo) behind everything, as the tray does.
    private var backdrop: some View {
        ZStack {
            Color.black
            if let image = lastShot?.drawing ?? lastShot?.photo {
                Image(uiImage: image).resizable().scaledToFill()
                    .blur(radius: 40).saturation(1.3).opacity(0.55)
            }
            LinearGradient(colors: [.black.opacity(0.35), .black.opacity(0.72), .black.opacity(0.88)],
                           startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    // MARK: - Model helpers

    private var selectedDrawerModel: CameraModel? { ModelCatalog.model(id: settings.selectedDrawer) }
    private var selectedDrawerEngine: DrawEngine { selectedDrawerModel?.engine ?? .mlx }
    private var handDraws: Bool { settings.handWillDraw }

    /// Short cap on the silent loop's instruction: art direction, not a description (the drawer's text
    /// encoder reads about 75 tokens).
    private static let handPromptMaxChars = 80

    private var unavailableReason: String {
        switch settings.seer {
        case .apple: return Readiness.current.explanation
        case .mlx:   return "Not downloaded yet - get it in the Model Library."
        }
    }

    static func loadLastShot() async -> PrefsLastShot? {
        guard let m = await NegativeStore.shared.list().first else { return nil }
        let photo = await NegativeStore.shared.thumbnail(m.id, maxPixel: 480)
        let drawing = m.hasDrawing ? await NegativeStore.shared.drawingThumbnail(m.id, maxPixel: 480) : nil
        let words = (m.eyeWords ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return PrefsLastShot(photo: photo.map { UIImage(cgImage: $0) },
                             words: m.wordsFromEye && !words.isEmpty ? words : nil,
                             drawing: drawing.map { UIImage(cgImage: $0) })
    }

    // MARK: - The deeper story behind each "?"

    private func helpTopic(_ key: String) -> PrefHelp {
        let device = ThisDevice.deviceKind
        switch key {
        case "preferences":
            return PrefHelp(id: key, kicker: "PREFERENCES", title: "Your camera, as it is set",
                            body: "A shot travels left to right: the lens takes the photo, the eye says what it sees, the hand draws the scene again from those words, and the print puts them together in Photos.\n\nThe three pictures at the top are your last shot. Tap one, or a row, to change how that part is made. Every setting is remembered when you put the camera down.")
        case "frame.lens":
            return PrefHelp(id: key, kicker: "FRAME 1", title: "The lens",
                            body: "The first frame is the photograph itself: what the camera's sensor actually caught, with no AI involved. It is the evidence beside the machine's claim, so it stays exactly as it was taken.")
        case "frame.eye":
            return PrefHelp(id: key, kicker: "FRAME 2", title: "The eye",
                            body: "The eye is a vision model: one part turns your photo into numbers, the other turns those numbers into words. It reports what it sees, plainly, without hedging. Whether you agree doesn't matter: this is what it sees.")
        case "frame.hand":
            return PrefHelp(id: key, kicker: "FRAME 3", title: "The hand",
                            body: "The hand is a drawing model. It reads only the eye's words and draws the scene again from them; it never sees your photograph. The distance between the photo and the drawing is the point.")
        case "frame.print":
            return PrefHelp(id: key, kicker: "THE PRINT", title: "What lands in Photos",
                            body: "How the frames are put together when a shot finishes developing: on one plate, side by side, the words over a picture, or each as its own file. Photos keeps the print; the Dark Room keeps the machine's workings for a while so the Developer Tray can open the shot again.")
        case "shape":
            return PrefHelp(id: key, kicker: "THE LENS", title: "Picture shape",
                            body: "4:3 is the camera's whole sensor: the widest view. In the square layouts the square sees the most of the scene. On a tall screen the viewfinder has black bands above and below.\n\n16:9 is taller and narrower, like a video frame, and fills more of the screen. In the square layouts the square sees about a quarter less of the scene, as if zoomed in a little.")
        case "location":
            return PrefHelp(id: key, kicker: "THE LENS", title: "The place stamp",
                            body: "The footer stamps where a shot was taken. Normally that's a place name (\"Los Angeles, CA\"), looked up by sending the coordinate to Apple's mapping service. Turn on raw coordinates to stamp latitude and longitude instead - no lookup, no network call - so with a downloaded local eye and hand, nothing about the shot leaves your \(device).")
        case "eye":
            return PrefHelp(id: key, kicker: "THE EYE", title: "Which eye",
                            body: "Apple's eye is built in and needs no download. The others are downloaded in the Model Library and shared with Hal and Posey, so anything they already have is here for free. Each sees differently; the Model Library says how each works and what the Developer Tray can show of it.")
        case "silentloop":
            return PrefHelp(id: key, kicker: "THE SILENT LOOP", title: "The eye switched off",
                            body: "With the eye off there are no words: the hand reads your photograph directly and paints it again. It works only with the SD-2.1 (Core ML) hand.\n\nThe instruction nudges the style; the hand still reads your photograph for its shapes and colors, and a blank instruction is fine. Transform sets how far it strays - low keeps the photo's forms, high reinvents them.")
        case "prompt":
            return PrefHelp(id: key, kicker: "THE EYE", title: "System prompt",
                            body: "The system prompt tells the eye how to describe what it sees. It is sent with every photo, and every word below the locked line is yours to change.\n\nThe locked first line keeps the description short enough for the hand: the drawing model reads only about fifty words (seventy-five word pieces), and Thomas shortens anything longer than forty-five. \"Reset the eye's defaults\" brings back the prompt and temperature the camera shipped with.")
        case "temperature":
            return PrefHelp(id: key, kicker: "THE EYE", title: "Temperature",
                            body: "Each time the eye picks its next word, it has a list of likely ones. Temperature decides how far down that list it is willing to reach.\n\nAt 1.0 it describes the same scene differently every time; at 0.6 it is steadier and, in our testing, more specific - not less imaginative. Qwen's own documentation recommends 0.6 for looking at pictures.")
        case "frametwo":
            return PrefHelp(id: key, kicker: "THE EYE", title: "What frame 2 shows",
                            body: "When a description runs too long for the hand, the same eye first shortens it to fit. Frame 2 can show what the hand received (the chain with no hidden step: the drawing was made from exactly these words) or the eye's full words, even the part the hand didn't get. On most shots they are the same.")
        case "hand":
            return PrefHelp(id: key, kicker: "THE HAND", title: "Which hand",
                            body: "The hand reads only the eye's words and never sees your photograph, except in the silent loop, where SD-2.1 reads the photo itself.\n\nSD-2.1 draws on the Neural Engine through Core ML; SD-Turbo draws through MLX in a handful of steps. Both are downloaded in the Model Library. Drawing takes about 10 to 12 seconds on an iPhone 16 Plus; each Model Library card says how long on this \(device).")
        case "steps":
            return PrefHelp(id: key, kicker: "THE HAND", title: "Steps",
                            body: "The hand draws by starting from static and removing a little of it at each step. More steps mean more detail and a little more time. The useful range belongs to the model: SD-Turbo draws in a handful, SD-2.1 wants about twenty.")
        case "decoder":
            return PrefHelp(id: key, kicker: "THE HAND", title: "Decoder",
                            body: "The last part of a drawing turns the model's numbers into a picture. Detailed uses the full decoder - sharper, and truer to what the model drew. If your \(device) is low on memory for a shot, Thomas quietly switches that one to Fast so the drawing still finishes instead of failing.\n\nFast uses a tiny, low-memory decoder - softer and less detailed, but it draws in almost any conditions. On a dreamy re-imagining, the softness can read as intentional.")
        case "size":
            return PrefHelp(id: key, kicker: "THE HAND", title: "Size",
                            body: "The hand draws at 512 pixels - small next to your photograph. Larger sizes enlarge the drawing after it's made, which is quick and doesn't strain memory.\n\nMetalFX is Apple's GPU upscaler - sharper, and it falls back to Core Image on any device that doesn't support it. Core Image is softer; on a dreamy re-imagining that can read as intentional.")
        case "developview":
            return PrefHelp(id: key, kicker: "THE HAND", title: "Watching the drawing",
                            body: "The hand draws in steps, and the Developer Tray can show each one. \"The working image\" is what it actually holds at each step: static slowly becoming a picture. \"Its best guess\" is its prediction of the finished drawing at each step: blurry at first, sharpening. Both are real; one is recorded per shot.")
        case "layout":
            return PrefHelp(id: key, kicker: "THE PRINT", title: "Layout",
                            body: "The layout is how the finished print is put together; you choose one. Only the layouts your current eye and hand can make are shown. Superimposed lays the words over the photo, or over the drawing. Single keeps just one panel: the words, the drawing, or the photo. Diptych sets two side by side. Triptych puts all three frames on one plate.\n\nThe layouts with a drawing beside the photo are square (the hand draws squares), so the viewfinder shows a square guide and you frame for the crop.\n\nWhat else is saved beside the print is a separate choice, under Also save to Photos.")
        case "keepsake":
            return PrefHelp(id: key, kicker: "THE PRINT", title: "Also save to Photos",
                            body: "Beside the print you chose, a shot can also save:\n\nEach frame as its own file: the photo, the words and the drawing as separate pictures. Their own shapes keeps each as it is; all square crops the photo to the square the hand draws, so the three pair.\n\nA contact sheet: every step of the drawing on one page. A flipbook: a short video of the steps. The steps are quick previews; the last frame is the finished drawing. These two appear when the hand is drawing.\n\nAll of these are off by default, so a shot does no extra work unless you ask.")
        default:
            return PrefHelp(id: key, kicker: "", title: key, body: "")
        }
    }

    #if DEBUG
    /// Human parity: the antenna names a section (`POST /open` X-Screen: preferences, X-Section: <id>) and
    /// Preferences opens the page that holds it, the way tapping its door does.
    private func openForAntenna() {
        guard let target = AntennaUIBridge.shared.scrollPreferencesTo else { return }
        AntennaUIBridge.shared.scrollPreferencesTo = nil
        let pages: [String: PrefsPage] = [
            "lens": .lens, "shape": .lens, "location": .lens,
            "eye": .eye, "prompt": .eye, "temperature": .eye,
            "hand": .hand, "silentloop": .hand, "decoder": .hand, "size": .hand, "developing": .hand, "steps": .hand,
            "print": .print, "layout": .print, "keepsake": .print,
        ]
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)   // let the sheet finish presenting
            if let p = pages[target] {
                page = p
                path = [p]
            } else {
                path = []   // "front", "models", "reset", "about", "antenna": the front door
                if target == "darkroom" { showingDarkRoom = true }
            }
        }
    }

    // MARK: - Antenna (DEBUG-only local API address + token)
    //
    // The local HTTP API's base URL and token, each with a copy button (Mark, 2026-07-25: "ridiculous we
    // struggle every time"). LocalAPIServer doesn't compile in Release, so neither does this card.

    private var antennaBaseURL: String { "http://\(LocalAPIServer.localIPAddress()):\(LocalAPIServer.port)" }

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
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.footnote.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button { copyAntennaField(value, field: field) } label: {
                Image(systemName: copiedAntennaField == field ? "checkmark.circle.fill" : "doc.on.doc")
                    .imageScale(.large)
                    .foregroundStyle(copiedAntennaField == field ? Color.green : Color.white)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Copy \(label)")
        }
    }

    private var antennaCard: some View {
        PrefCard {
            Text("Antenna (Debug)").font(.headline)
            if LocalAPIServer.shared.isRunning {
                antennaRow(label: "Base URL", value: antennaBaseURL, field: "url")
                antennaRow(label: "Token", value: LocalAPIServer.apiToken, field: "token")
            } else {
                Text("Antenna is off. Turn it on with the antenna button on the camera screen, then reopen this to see its address.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Text("The local HTTP API for host-side testing over Wi-Fi. DEBUG builds only; Release ships no server.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
    #endif
}

/// The deeper story, over the screen (the tray's help card). Shared by Preferences and the Dark Room.
struct PrefHelpCard: View {
    let help: PrefHelp
    let done: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea().onTapGesture { done() }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 12) {
                Text(help.kicker).font(.caption.weight(.bold)).tracking(1.4).foregroundStyle(.secondary)
                Text(help.title).font(.title3.weight(.bold)).accessibilityAddTraits(.isHeader)
                ScrollView {
                    Text(help.body).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 420)
                .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Done", action: done)
                        .font(.subheadline.weight(.bold)).foregroundStyle(.black)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(.white, in: Capsule())
                }
            }
            .padding(18)
            .frame(maxWidth: 560)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .environment(\.colorScheme, .dark)
            .padding(20)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
    }
}

/// Hands a page its live choice through a binding (see `pageScreen`).
struct PrefsPageHost<Content: View>: View {
    @Binding var page: PrefsPage
    @ViewBuilder let content: (PrefsPage) -> Content
    var body: some View { content(page) }
}

/// One card on Preferences' dark ground, the tray's material.
struct PrefCard<Content: View>: View {
    var padding = true
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: padding ? 10 : 0) { content }
            .padding(.horizontal, padding ? 16 : 0)
            .padding(.vertical, padding ? 12 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(white: 0.12).opacity(0.74), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
    }
}

/// A setting's one plain line, and its "?" (the deeper story opens over the screen).
struct PrefLine: View {
    let text: String
    let help: PrefHelp
    @Binding var open: PrefHelp?

    init(_ text: String, help: PrefHelp, open: Binding<PrefHelp?>) {
        self.text = text; self.help = help; self._open = open
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(text).font(.subheadline).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { open = help } label: {
                Image(systemName: "questionmark").font(.caption.weight(.bold))
                    .frame(width: 26, height: 26)
                    .overlay(Circle().strokeBorder(.white.opacity(0.45), lineWidth: 1))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("More about \(help.title.lowercased())")
        }
    }
}

/// A layout drawn small, with the last shot's own pictures where there is one (colors otherwise).
struct LayoutThumb: View {
    let layout: Layout
    let photo: UIImage?
    let drawing: UIImage?
    let selected: Bool

    private enum Panel { case photo, words, drawing }

    var body: some View {
        content
            .padding(5)
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .background(selected ? Color.white.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.white : Color.white.opacity(0.25), lineWidth: selected ? 2 : 1))
            .clipped()
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder private var content: some View {
        switch layout {
        case .superimposed:          overlayPanel(.photo)
        case .superimposedOnDrawing: overlayPanel(.drawing)
        case .textOnly:              panel(.words)
        case .singleDrawing:         panel(.drawing)
        case .singlePhoto:           panel(.photo)
        case .diptychTextLeft:       HStack(spacing: 3) { panel(.words); panel(.photo) }
        case .diptychTextRight:      HStack(spacing: 3) { panel(.photo); panel(.words) }
        case .diptychDrawingLeft:    HStack(spacing: 3) { square(.drawing); square(.photo) }
        case .diptychDrawingRight:   HStack(spacing: 3) { square(.photo); square(.drawing) }
        case .triptychVertical:      VStack(spacing: 2) { square(.photo); square(.words); square(.drawing) }
        case .triptychHorizontal:    HStack(spacing: 3) { square(.photo); square(.words); square(.drawing) }
        case .separateNative:        HStack(spacing: 5) { panel(.photo).frame(height: 30); panel(.words).frame(height: 40); panel(.drawing).frame(height: 36) }
        case .separateSquare:        HStack(spacing: 5) { panel(.photo).aspectRatio(1, contentMode: .fit); panel(.words).aspectRatio(1, contentMode: .fit); panel(.drawing).aspectRatio(1, contentMode: .fit) }
        }
    }

    /// The panels that are square in the real print (the hand draws squares).
    private func square(_ p: Panel) -> some View { panel(p).aspectRatio(1, contentMode: .fit) }

    /// Words laid over a picture: two lines of "text", so it reads differently from the picture alone.
    private func overlayPanel(_ p: Panel) -> some View {
        panel(p).overlay(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 2) {
                Capsule().fill(.white).frame(height: 3)
                Capsule().fill(.white).frame(width: 18, height: 3)
            }
            .padding(.horizontal, 6).padding(.bottom, 6)
            .shadow(color: .black.opacity(0.6), radius: 1)
        }
    }

    @ViewBuilder private func panel(_ p: Panel) -> some View {
        switch p {
        case .words:
            RoundedRectangle(cornerRadius: 2).fill(Color(red: 0.957, green: 0.945, blue: 0.918))
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(0..<3, id: \.self) { i in
                            Capsule().fill(Color.black.opacity(0.35)).frame(height: 1.5).frame(maxWidth: i == 2 ? 10 : .infinity)
                        }
                    }
                    .padding(3)
                }
        case .photo:   picture(photo, fallback: Color(red: 0.42, green: 0.56, blue: 0.71))
        case .drawing: picture(drawing, fallback: Color(red: 0.76, green: 0.37, blue: 0.66))
        }
    }

    private func picture(_ image: UIImage?, fallback: Color) -> some View {
        Color.clear.overlay {
            if let image { Image(uiImage: image).resizable().scaledToFill() } else { fallback }
        }
        .clipShape(RoundedRectangle(cornerRadius: 2))
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
