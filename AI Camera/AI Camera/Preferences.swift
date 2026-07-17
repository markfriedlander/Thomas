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

// ==== LEGO START: 23 Settings (What The Camera Is Loaded With) ====

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

/// What the camera is loaded with. Set before you raise it; never per-shot.
///
/// `@AppStorage` because a camera remembers its settings when you put it down. The shot
/// stays atomic: nothing here is asked at the moment of the press.
@MainActor
@Observable
final class Settings {
    static let shared = Settings()

    /// Which eye is loaded.
    ///
    /// Switching away from Qwen **unloads it**. Mark's instruction (2026-07-15): the model
    /// should go "when the app is in the background or is about to switch to a different
    /// model." Without this, choosing Apple in Preferences left 1.75 GB of Qwen resident
    /// and unreachable for the rest of the session — paying the full memory price of a
    /// model the camera had stopped using. The teardown is real (GPU drain, cache clear);
    /// see `QwenLoader.unload()`.
    ///
    /// Fire-and-forget because `unload()` is actor-isolated and a setter can't await. The
    /// ordering is safe either way: a look already in flight holds its own container
    /// reference, and the next look re-loads through `container()`, which is the same path
    /// a cold start takes.
    var seer: Seer {
        didSet {
            store(seer.rawValue, "seer")
            if oldValue == .qwen && seer != .qwen {
                cameraLog("MEMORY: seer \(oldValue.rawValue) → \(seer.rawValue) — unloading the eye we just left")
                Task { await QwenLoader.shared.unload() }
            }
        }
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
    var systemPrompt: String {
        didSet { store(systemPrompt, "systemPrompt") }
    }
    var temperature: Double {
        didSet { store(temperature, "temperature") }
    }
    // ── PARKED (2026-07-16): the hand's system prompt. ──
    //
    // A style added to the eye's words ("oil painting", "charcoal sketch") was built and then
    // deliberately DEACTIVATED. Mark's reasoning: the hand's input should be the eye's words,
    // clean — a user style prompt inserts a *human's* aesthetic into a machine→machine chain,
    // and "changes what the drawer perceives the eye to have seen." Hidden from the UI and
    // unread by `Shot`, so it cannot trigger. Commented out rather than deleted because it is a
    // real future feature: an explicitly opt-in "art direction" mode, clearly outside the pure
    // chain (like the silent loop). See NEXT.
    //
    // var handPrompt: String {
    //     didSet { store(handPrompt, "handPrompt") }
    // }

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

    private init() {
        let d = UserDefaults.standard
        seer = Seer(rawValue: d.string(forKey: "seer") ?? "") ?? .apple
        layout = Layout(rawValue: d.string(forKey: "layout") ?? "") ?? .superimposed
        drawsThirdFrame = d.bool(forKey: "drawsThirdFrame")
        systemPrompt = d.string(forKey: "systemPrompt") ?? Eye.plain.systemPrompt
        temperature = d.object(forKey: "temperature") as? Double ?? Eye.plain.temperature
        // handPrompt parked — see the property above.
        frameTwoShows = FrameTwoWords(rawValue: d.string(forKey: "frameTwoShows") ?? "") ?? .sentToHand
        drawingSize = DrawingSize(rawValue: d.string(forKey: "drawingSize") ?? "") ?? .native
        upscaler = UpscaleMethod(rawValue: d.string(forKey: "upscaler") ?? "") ?? .metalFX
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

    var qwen: Qwen {
        Qwen(systemPrompt: systemPrompt, temperature: temperature)
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
        systemPrompt = Eye.plain.systemPrompt
        temperature = Eye.plain.temperature
        // handPrompt parked — see the property above.
        frameTwoShows = .sentToHand
        drawingSize = .native
        upscaler = .metalFX
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

// ==== LEGO END: 23 Settings (What The Camera Is Loaded With) ====

// ==== LEGO START: 24 PreferencesView (The Film Drawer) ====

struct PreferencesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = Settings.shared
    @State private var showingPresets = false
    @State private var confirmingReset = false
    @State private var showingLayerOneInfo = false
    @FocusState private var promptFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                modelSection
                eyeSection
                handSection
                sizeSection
                layoutSection
                resetSection
            }
            // ⚠️ The presets sheet lives HERE, on the Form, not on `promptSection`.
            //
            // It used to hang off the Section, and that is why it "hid itself as soon as you
            // clicked" (Mark, 2026-07-16): `settings` is `@Observable`, the system-prompt
            // TextEditor mutates it on the way in, the Section re-evaluates, and a `.sheet`
            // bound to a view that's being rebuilt gets torn down — it opens and instantly
            // dismisses. A sheet has to hang off a stable parent. The Form is stable; the
            // Section is not.
            .sheet(isPresented: $showingPresets) {
                PresetPicker { preset in
                    // Show your work: the preset writes into the visible fields. Nothing is
                    // configured behind your back, and you can see exactly what it did.
                    settings.systemPrompt = preset.systemPrompt
                    settings.temperature = preset.temperature
                }
            }
            // Same reason as the presets sheet: alerts hang off the stable Form, not a Section
            // that re-renders when `settings` changes.
            .alert("Why can't I change this line?", isPresented: $showingLayerOneInfo) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("This keeps the eye's description short enough for the hand to draw from — the drawing model can only read about seventy-five words, and a longer description used to crash the camera. It's locked so it can't be removed by accident. Everything below it is yours.")
            }
            .navigationTitle("Preferences")
            .navigationBarTitleDisplayMode(.inline)
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

    // MARK: - Which machine is looking

    /// Hal's convention: the loaded model with a status dot, and a row through to the
    /// library. Posey copied it verbatim; this is the third tenant doing the same.
    ///
    /// **This replaced a second, older way of choosing the eye.** Preferences used to carry
    /// its own `Picker` over Apple/Qwen plus a footer spelling out each one's trade-offs —
    /// written when there was nowhere else for that to live. The library now selects models
    /// and describes them (`ModelCatalog`'s blurbs are that footer's text, moved to where
    /// the model is), so the picker was a second control for one setting and the footer was
    /// a second copy of one description. Two places to change a thing is how they drift.
    private var modelSection: some View {
        Section {
            HStack {
                Text("Loaded")
                    .font(.subheadline)
                Spacer()
                HStack(spacing: 6) {
                    // The one shared dot (`ModelStatusDot`). The loaded eye IS the active one,
                    // so it's green when it's ready to shoot and — per the metaphor — no dot at
                    // all when it isn't (the reason text below says why). Grey never appears
                    // here: this row only ever shows the model you're currently shooting with,
                    // and there is no such thing as an inactive loaded eye.
                    ModelStatusDot(isDownloaded: settings.seer.isAvailable, isActive: true)
                    Text(settings.seer.name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
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

    private var unavailableReason: String {
        switch settings.seer {
        case .apple: return Readiness.current.explanation
        // Was: "Download it in Hal or Posey and it appears here." That stopped being true
        // the moment the library existed, and it was the app admitting it was a parasite on
        // two apps that aren't released.
        case .qwen:  return "Not downloaded yet — get it in the Model Library."
        }
    }

    // MARK: - The eye — how it looks

    /// Mark, 2026-07-16, on the metaphors: *"let's use eye and hand as the metaphors for
    /// now."* So the section is "The eye" (metaphor for the object) and the control inside is
    /// a system prompt (honest terminology for the control) — Principle 2 exactly: metaphor
    /// for the thing, real name for the knob.
    private var eyeSection: some View {
        Section {
            // Layer 1 — locked, but SHOWN. Principle 2 done honestly: we don't hide the line
            // the app depends on, we display it and lock it. The ⓘ says why. Everything below
            // is Layer 2, fully the user's. See `PromptLayers`.
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 3)
                Text(PromptLayers.brevity)
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

            Button("Presets…") { showingPresets = true }
            Button("Reset the eye's prompt and temperature") {
                promptFocused = false
                settings.resetPromptToDefault()
            }
        } header: {
            Text("The eye — how it looks")
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
    private var handSection: some View {
        Section {
            Toggle("Draw the third frame", isOn: $settings.drawsThirdFrame)
                .disabled(!DrawerLoader.isAvailable)

            if !DrawerLoader.isAvailable {
                Text("\(ModelCatalog.sdTurbo.displayName) isn't downloaded — get it in the Model Library above.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if settings.drawsThirdFrame {
                // Peekaboo: only once the third frame is on does "what frame 2 shows" mean
                // anything — condensation exists solely to feed the hand. Default is the
                // airtight chain (what the hand received); see `FrameTwoWords`.
                Picker("Frame 2 shows", selection: $settings.frameTwoShows) {
                    ForEach(FrameTwoWords.allCases, id: \.self) { choice in
                        Text(choice.name).tag(choice)
                    }
                }
            }

            // ── PARKED: the hand's system prompt (art-direction mode). ──
            // Deactivated 2026-07-16 — see the `handSection` note and Settings. The hand draws
            // the eye's words, clean. Kept commented so reviving it is trivial:
            //
            // if DrawerLoader.isAvailable {
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
            Text("The hand — how it draws")
        } footer: {
            Text("The hand draws the scene again from the eye's words — it never sees your photograph. When a description runs long, the same eye first shortens it to fit; frame 2 can show either the eye's full words or that shorter version. Drawing adds about ten seconds to a shot.")
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

    // MARK: - How the words meet the picture

    // MARK: - How big the drawing is saved

    /// The drawing's size, and which upscaler enlarges it. Only in "The hand"'s world — it's
    /// about frame 3, so it hides when the drawing model isn't downloaded.
    ///
    /// The model draws at 512²; larger sizes upscale AFTER the draw, where it's cheap and
    /// never touches the memory spike (Mark: *"I really don't wanna push our luck"* on
    /// generating bigger). Native is the honest baseline. The upscaler picker only matters
    /// when a larger size is chosen, so it's tucked below and its choice explained.
    @ViewBuilder
    private var sizeSection: some View {
        if DrawerLoader.isAvailable {
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
                Text("The drawing's size")
            } footer: {
                Text(settings.drawingSize == .native
                     ? "The hand draws at 512 pixels — small next to your photograph. Larger sizes enlarge the drawing after it's made, which is quick and doesn't strain memory."
                     : "MetalFX is Apple's GPU upscaler — sharper, and it falls back to Core Image on any device that doesn't support it. Core Image is softer; on a dreamy re-imagining that can read as intentional. The enlarging happens after the draw, so it costs no extra memory.")
            }
        }
    }

    private var layoutSection: some View {
        Section {
            Picker("Layout", selection: $settings.layout) {
                ForEach(Layout.allCases, id: \.self) { layout in
                    Text(layout.name).tag(layout)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } header: {
            Text("Layout")
        } footer: {
            Text("Superimposed puts the words on the world they describe. A diptych sets them beside it, white on black, giving the words exactly as much room as the photograph. Words only keeps what the machine said and discards the photograph entirely. Separate images saves the photograph and the words as two pictures, and lets you do the comparing.")
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

// ==== LEGO END: 24 PreferencesView (The Film Drawer) ====
