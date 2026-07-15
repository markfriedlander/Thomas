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

// ==== LEGO START: 22 Settings (What The Camera Is Loaded With) ====

/// What the camera is loaded with. Set before you raise it; never per-shot.
///
/// `@AppStorage` because a camera remembers its settings when you put it down. The shot
/// stays atomic: nothing here is asked at the moment of the press.
@MainActor
@Observable
final class Settings {
    static let shared = Settings()

    var seer: Seer {
        didSet { store(seer.rawValue, "seer") }
    }
    var layout: Layout {
        didSet { store(layout.rawValue, "layout") }
    }
    var systemPrompt: String {
        didSet { store(systemPrompt, "systemPrompt") }
    }
    var temperature: Double {
        didSet { store(temperature, "temperature") }
    }

    private init() {
        let d = UserDefaults.standard
        seer = Seer(rawValue: d.string(forKey: "seer") ?? "") ?? .apple
        layout = Layout(rawValue: d.string(forKey: "layout") ?? "") ?? .superimposed
        systemPrompt = d.string(forKey: "systemPrompt") ?? Eye.plain.systemPrompt
        temperature = d.object(forKey: "temperature") as? Double ?? Eye.plain.temperature
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
        systemPrompt = Eye.plain.systemPrompt
        temperature = Eye.plain.temperature
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

// ==== LEGO END: 22 Settings (What The Camera Is Loaded With) ====

// ==== LEGO START: 23 PreferencesView (The Film Drawer) ====

struct PreferencesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = Settings.shared
    @State private var showingPresets = false
    @State private var confirmingReset = false
    @FocusState private var promptFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                eyeSection
                promptSection
                layoutSection
                resetSection
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

    private var eyeSection: some View {
        Section {
            Picker("Model", selection: $settings.seer) {
                ForEach([Seer.apple, Seer.qwen], id: \.self) { seer in
                    Text(seer.name).tag(seer)
                }
            }
            if !settings.seer.isAvailable {
                Text(unavailableReason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("The eye")
        } footer: {
            // Said plainly, with the real trade-offs. Not marketing, and not a verdict —
            // which is better is not ours to say (Principle 3).
            Text(settings.seer == .apple
                 ? "Apple Intelligence. On the phone already, nothing to download. A filter stops some images before the model sees them; when that happens the camera asks again with the filter relaxed, and records both answers."
                 : "Qwen3.5-2B, \(String(format: "%.1f", Double(qwenSize) / 1e9)) GB, shared with Hal and Posey — already downloaded, so nothing to fetch. No filter of any kind. Sees more, and largely ignores instructions about how to speak. First look after launch takes ~9s while it loads; after that ~3s.")
        }
    }

    private var qwenSize: Int64 { SharedModelStore.sizeOnDisk(Qwen.repo) }

    private var unavailableReason: String {
        switch settings.seer {
        case .apple: return Readiness.current.explanation
        case .qwen:  return "Not in the shared store. Download it in Hal or Posey and it appears here."
        }
    }

    // MARK: - How it's told to look

    private var promptSection: some View {
        Section {
            // Principle 2: this is a system prompt, it is called a system prompt, and you
            // can read and change every word of it.
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
            Button("Reset system prompt and temperature") {
                promptFocused = false
                settings.resetPromptToDefault()
            }
        } header: {
            Text("System prompt")
        } footer: {
            Text("Higher temperature makes the machine reach for less likely words. At 1.0 it describes the same scene differently every time; at 0.6 it is steadier and, in our testing, more specific — not less imaginative. Qwen's own documentation recommends 0.6 for looking at pictures.")
        }
        .sheet(isPresented: $showingPresets) {
            PresetPicker { preset in
                // Show your work: the preset writes into the visible fields. Nothing is
                // configured behind your back, and you can see exactly what it did.
                settings.systemPrompt = preset.systemPrompt
                settings.temperature = preset.temperature
            }
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
            Text("The eye, the system prompt, the temperature, and the layout all go back to how the camera shipped. Your photographs are untouched.")
        }
    }

    // MARK: - How the words meet the picture

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

// ==== LEGO END: 23 PreferencesView (The Film Drawer) ====
