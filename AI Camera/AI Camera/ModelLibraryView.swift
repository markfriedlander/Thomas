//
//  ModelLibraryView.swift
//  AI Camera
//
//  The door on the downloader.
//
//  Mark, 2026-07-15, having opened Settings and found nothing: *"I open settings on the app
//  and noticed that the downloader I had asked to be installed is not. Please look at Hal,
//  and Posey and see what their model libraries look like for the user and what they're
//  actually doing. That's what I envisioned in the settings for the camera."*
//
//  He was right, and the gap was total: the 2026-07-15 port brought 1,968 lines of
//  downloader across and connected them to a table-of-contents comment. No button, no
//  screen, no call site. The app went on telling users *"Download it in Hal or Posey and it
//  appears here"* while HISTORY recorded that it had been made standalone. It had not.
//
//  ── The pattern is Hal's, deliberately ──
//
//  Hal: Settings → an "AI Model" section showing the active model with a status dot, and a
//  "Browse Model Library" row → a list, grouped, each row name + size + dot, tapping
//  expands to a description and Download / Delete / Use, and a progress bar with Cancel
//  while it runs. Posey copied it verbatim — its own comment reads *"Hal's exact row +
//  icon."* Mark's standing instruction is that Hal is the reference and copies flow one
//  way. This is the third tenant taking the same shape.
//
//  ── Where it deviates, and why ──
//
//  Hal groups by trust ("Hal's Picks" vs. untested "Community Models") because Hal has a
//  live HuggingFace catalog of hundreds. **The camera has three models and will never have
//  many** — a camera has a lens fitted, not a lens store. So the grouping that carries
//  meaning here is not trust, it is *which frame the model serves*: the eye that reads the
//  photograph, and the hand that draws from its words. That is the app's actual subject.
//

import SwiftUI
import SharedModelStoreKit

// ==== LEGO START: 25 ModelLibraryView (The Model Library) ====

struct ModelLibraryView: View {
    @State private var settings = Settings.shared
    @ObservedObject private var downloader = MLXModelDownloader.shared
    /// The one catalog every screen reads (Hal's pattern). Its `availableModels` carry the
    /// centrally-refreshed download state, so these rows and Preferences' dots always agree and a
    /// delete/download updates both at once. Replaces the old per-view `refreshToken` that only this
    /// screen could see — the split that let Preferences show a stale "active" dot after a removal.
    @State private var catalog = ModelCatalogService.shared
    @State private var confirmingDelete: CameraModel?
    @State private var showingClearFamilyAlert = false   // Clear all family models (last resort)
    /// The model whose license sheet is open. Set when the user taps Download; the actual
    /// download only starts once they accept — the studio's surface-the-license-before-you-
    /// -take-it pattern, ported from Hal/Posey (`ModelLicenseSheet` below).
    @State private var modelForLicense: CameraModel?
    /// How many queued shots still need each model (by model id), so the delete confirmation can
    /// warn that deleting will pause them. Loaded from the dark room store on appear and refreshed
    /// when a model lands.
    @State private var queuedUsage: [String: Int] = [:]

    var body: some View {
        List {
            ForEach([ModelJob.seeing, ModelJob.drawing], id: \.self) { job in
                Section {
                    ForEach(catalog.models(for: job)) { model in
                        ModelLibraryRow(
                            model: model,
                            isActive: isActive(model),
                            isSelected: isSelected(model),
                            downloader: downloader,
                            onUse:      { use(model) },
                            onDownload: { requestDownload(model) },
                            onCancel:   { downloader.cancelDownload(modelID: model.id) },
                            onDelete:   { confirmingDelete = model }
                        )
                    }
                } header: {
                    Label(job.title, systemImage: job == .seeing ? "eye" : "hand.draw")
                } footer: {
                    Text(job == .seeing
                         ? "The machine that reads your photograph and says what it sees. One is loaded at a time, chosen before you raise the camera."
                         : "The machine that draws the third frame from the words the eye produced. It never sees your photograph.")
                    .font(.caption2)
                }
            }

            Section {
                DiskRow()
                // Last-resort family-wide clear, matching Hal's Maintenance screen.
                // Distinct from the per-model Delete above (which gives up only this
                // camera's claim): this removes EVERY shared model for the whole family
                // at once and resets the manifest. Manifest-aware
                // (SharedModelStore.clearEntireSharedStore) so it leaves no ghost entries.
                Button {
                    showingClearFamilyAlert = true
                } label: {
                    HStack(alignment: .top) {
                        Image(systemName: "trash.fill")
                            .foregroundColor(.red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Clear all family models")
                                .foregroundColor(.red)
                            Text("Removes every shared model for Hal, Posey, and AI Camera at once. Each app re-downloads as needed. Last resort.")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                }
            } footer: {
                // The store is shared, so "delete" does not always mean "free space", and
                // saying so up front is cheaper than a user wondering where their gigabytes
                // went. Mark's rule for the store, verbatim: "Deleting a model from an app
                // does not delete it from the repository. Deleting it from the last
                // remaining app to have it in use deletes it from the repository."
                Text("Models are shared with Hal and Posey. Deleting one here gives up this camera's claim on it — the files are removed only when no other app is still using them.")
                    .font(.caption2)
            }
        }
        .navigationTitle("Model Library")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadQueuedUsage() }
        // Leaving the library is a natural moment to let the queue re-check: a model the user just
        // downloaded can unblock the shots that were waiting for it.
        .onDisappear { DarkRoomWorker.shared.kick() }
        // A model landing is a filesystem change SwiftUI can't see. `ModelCatalogService` already
        // catches `.mlxModelDidDownload` and refreshes every screen's dots (these rows read its
        // `availableModels`), so here we keep only the library-specific follow-ups: unblock the queue
        // that was waiting on the new model, and refresh the "shots still use this" delete-warning counts.
        .onReceive(NotificationCenter.default.publisher(for: .mlxModelDidDownload)) { _ in
            DarkRoomWorker.shared.kick()
            Task { await loadQueuedUsage() }
        }
        .confirmationDialog(
            confirmingDelete.map { "Delete \($0.displayName)?" } ?? "",
            isPresented: Binding(get: { confirmingDelete != nil },
                                 set: { if !$0 { confirmingDelete = nil } }),
            titleVisibility: .visible
        ) {
            if let model = confirmingDelete {
                Button("Delete", role: .destructive) { delete(model) }
            }
            Button("Cancel", role: .cancel) { confirmingDelete = nil }
        } message: {
            if let model = confirmingDelete {
                Text(deleteMessage(for: model))
            }
        }
        .alert("Clear all family models?", isPresented: $showingClearFamilyAlert) {
            Button("Clear all family models", role: .destructive) {
                let removed = SharedModelStore.clearEntireSharedStore()
                catalog.refresh()   // store changed with no notification — poke the one source
                print("AICAMERA: cleared entire shared store: \(removed) repos removed")
            }
            Button("Cancel", role: .cancel) { showingClearFamilyAlert = false }
        } message: {
            Text("Removes every downloaded AI model shared across Hal, Posey, and AI Camera to reclaim all model storage at once. Each app re-downloads what it needs the next time you use it. Your photos and settings are not affected.")
        }
        // Surface the model's license before the download begins. Hangs off the stable List,
        // not a row (rows come and go as the catalog refreshes, which would tear the sheet down).
        .sheet(item: $modelForLicense) { model in
            ModelLicenseSheet(
                model: model,
                onAccept: { modelForLicense = nil; download(model) },
                onCancel: { modelForLicense = nil }
            )
        }
    }

    // MARK: - What the buttons do

    /// "Active" is role-aware here, because this app has TWO active roles at once — where Hal
    /// had one. A **seeing** model is active when it's the selected eye. A **drawing** model is
    /// active when the third frame is being drawn (`drawsThirdFrame`) — it's enlisted for the
    /// next shot, exactly as the eye is. So SD-Turbo goes green the moment you turn drawing on.
    /// Whether this model is the CHOSEN one for its role — the selected eye, or the selected hand.
    /// Distinct from `isActive` for a hand: a hand can be selected while the third frame is off
    /// (chosen for the next shot, but not currently drawing). For an eye the two coincide (there is
    /// no eye on/off — the selected eye is always the one that looks).
    private func isSelected(_ model: CameraModel) -> Bool {
        switch model.job {
        case .seeing:  return settings.seer.modelID == model.id
        case .drawing: return settings.selectedDrawer == model.id
        }
    }

    /// "Active" = enlisted for the next shot. The selected eye is always active; a drawing model is
    /// active only when it is the SELECTED hand AND the third frame is on. That second clause is the
    /// fix for the "both hands green" bug (2026-07-27): before, any installed hand went green the
    /// moment drawing turned on, so two installed hands both looked active at once.
    private func isActive(_ model: CameraModel) -> Bool {
        switch model.job {
        case .seeing:  return settings.seer.modelID == model.id
        case .drawing: return settings.selectedDrawer == model.id && settings.drawsThirdFrame
        }
    }

    /// Records which model the next press uses — for EITHER role. The Model Library is the one place
    /// you pick both the eye and the hand (2026-07-27), so tapping "Select" on a hand records it as
    /// the drawer, exactly as tapping an eye records the seer. No load/unload here: under the
    /// model-ownership rule the dark room worker owns all loading; the live setting is a template.
    private func use(_ model: CameraModel) {
        switch model.job {
        case .seeing:
            // The built-in is the one special case; every other seeing model is an MLX eye named by
            // its repo id, so selecting one is generic — no per-model branch, the whole point of the
            // generalization.
            if model.id == ModelCatalog.apple.id {
                settings.seer = .apple
            } else {
                settings.seer = .mlx(repoID: model.id)
            }
        case .drawing:
            settings.selectedDrawer = model.id
        }
    }

    /// Tapping Download doesn't download — it opens the license first. A model with no
    /// license string (only the built-in, which is never downloaded anyway) would go
    /// straight through, but in practice every downloadable model names its terms.
    private func requestDownload(_ model: CameraModel) {
        if model.licence == nil {
            download(model)
        } else {
            modelForLicense = model
        }
    }

    // The Download button and the antenna's license-accept verb both call this ONE function, so the
    // two take the identical path (Principle 7 / antenna human-parity — the antenna exercises what a
    // human does, never a parallel copy that could pass while the real one is broken).
    private func download(_ model: CameraModel) { startModelDownload(model) }

    /// Mark's semantics: give up our claim; the files go only if we were the last to hold
    /// them.
    ///
    /// `deleteModel` already does exactly that — releases the claim first and removes the
    /// directory only when `releaseClaim` says no sibling is left. It came across with the
    /// port and is correct; reimplementing it here would be a second copy of a rule that
    /// must never disagree with itself.
    ///
    /// The one thing added: drop the model out of memory first if it's the eye currently
    /// loaded. Deleting weights out from under a live `mmap` is survivable on a Unix
    /// filesystem — the inode outlives the unlink — but leaving 1.6 GB resident for a model
    /// the user just deleted is its own bug, and the seer would still be pointing at it.
    // Both the Delete button and the antenna's /delete verb call `deleteModelEverywhere` (below), the
    // one copy of the release-and-remove rule (antenna human-parity).
    private func delete(_ model: CameraModel) {
        confirmingDelete = nil
        Task {
            // `deleteModelEverywhere` refreshes the shared catalog at its end, so every screen's dots
            // re-derive — no per-view refresh needed here anymore (that split was the original bug).
            await deleteModelEverywhere(model)
        }
    }

    private func deleteMessage(for model: CameraModel) -> String {
        var message: String
        let others = model.claimants.filter { $0 != SharedModelStore.thisAppID }
        if others.isEmpty {
            message = "The files will be removed from the phone, freeing \(formatted(model.bytesOnDisk)). You can download it again."
        } else {
            let names = others.map { SharedModelStore.displayName(forAppID: $0) }
            message = "\(model.displayName) is also used by \(names.joined(separator: " and ")). This camera gives up its claim, but the files stay on the phone and no space is freed."
        }
        // Warn if shots in the dark room still need this model — they aren't lost, they pause.
        if let n = queuedUsage[model.id], n > 0 {
            message += "\n\n\(n) shot\(n == 1 ? "" : "s") still waiting to develop use this. "
                + "\(n == 1 ? "It" : "They") will pause — shown as \u{201C}Needs \(model.displayName)\u{201D} in the Dark Room — until you download it again."
        }
        return message
    }

    /// Count, per model id, how many queued shots still need it. A shot needs its eye always, and
    /// the drawer too when it draws the third frame.
    private func loadQueuedUsage() async {
        let records = await DarkRoomStore.shared.pending()
        var counts: [String: Int] = [:]
        for r in records {
            counts[ModelCatalog.model(for: r.config.seer).id, default: 0] += 1
            if r.config.drawsThirdFrame {
                counts[ModelCatalog.sdTurbo.id, default: 0] += 1
            }
        }
        queuedUsage = counts
    }

    private func formatted(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useGB, .useMB]
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}

// MARK: - One model

private struct ModelLibraryRow: View {
    let model: CameraModel
    let isActive: Bool
    let isSelected: Bool
    @ObservedObject var downloader: MLXModelDownloader
    let onUse: () -> Void
    let onDownload: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    @State private var isExpanded = false

    private var state: MLXModelDownloader.DownloadState? { downloader.downloadStates[model.id] }
    private var isDownloading: Bool { state?.isDownloading == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Text(model.displayName)
                        .font(.subheadline).fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let gb = model.sizeGB {
                        Text("\(String(format: "%.1f", gb)) GB")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    statusDot
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider().padding(.vertical, 8)
                if isDownloading, let state {
                    progress(state)
                } else {
                    Text(model.blurb)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 8)
                    if let licence = model.licence {
                        // Named, not hidden behind an "i". Principle 2 — a user about to
                        // spend 2 GB is entitled to know what they're accepting.
                        Text(licence)
                            .font(.caption2).foregroundStyle(.tertiary)
                            .padding(.bottom, 8)
                    }
                    if let err = state?.error {
                        Text(err)
                            .font(.caption).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 8)
                    }
                    actions
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// The three-state model dot, from the one shared source (`ModelStatusDot`): green =
    /// downloaded and active, grey = downloaded and inactive, no dot = not here. A model
    /// mid-download shows no dot — the progress bar below is already saying so.
    private var statusDot: some View {
        ModelStatusDot(isDownloaded: model.isDownloaded, isActive: isActive)
    }

    private func progress(_ state: MLXModelDownloader.DownloadState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: state.progress)
            HStack {
                Text(state.message)
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text("\(Int(state.progress * 100))%")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                Button("Cancel", action: onCancel)
                    .font(.caption2)
                    .buttonStyle(.borderless)
            }
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 12) {
            if !model.isDownloaded {
                // Plain accent text+icon, identical to Hal (Hal.swift) and Posey
                // (AskPoseyModelRow) so the studio reads the same everywhere. NOT a filled
                // .borderedProminent pill: that capsule got stretched wide by the row and
                // rendered strangely (Mark, 2026-07-28). A plain button hugs its content and
                // can't stretch.
                Button(action: onDownload) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Download")
                    }
                    .font(.subheadline)
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            } else {
                // The Select / Active control, in Hal's language and style so the studio reads the
                // same everywhere (Mark, 2026-07-18 — "same language everywhere possible so people
                // don't have to figure anything out"). BOTH roles are chosen here now (2026-07-27):
                // the Model Library is the one place you pick the eye AND the hand. Label is a pure
                // function of two facts, so no per-role branch:
                //   not chosen        → "Select"   (tappable)
                //   chosen + active   → "Active"   (the selected eye; the selected hand with drawing on)
                //   chosen, not active→ "Selected" (only a hand: picked, but the third frame is off)
                Button(action: onUse) {
                    HStack(spacing: 4) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        Text(!isSelected ? "Select" : (isActive ? "Active" : "Selected"))
                    }
                    .foregroundColor(isSelected ? .secondary : .accentColor)
                }
                .buttonStyle(.plain)
                .disabled(isSelected)
                Spacer()
                if !model.isBuiltIn {
                    Button(role: .destructive, action: onDelete) {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
            if !model.isDownloaded { Spacer() }
        }
        .font(.caption)
    }
}

// MARK: - What's left on the phone

/// Free space, said the way iOS actually means it.
///
/// **Two numbers, because iOS has two and they disagree by gigabytes.** Measured on Mark's
/// iPhone 16 Plus, 2026-07-15: `volumeAvailableCapacityForImportantUsage` said 5,759 MB
/// while `volumeAvailableCapacity` said 2,983 MB — a 2.8 GB gap. The larger one is real
/// (iOS will purge other apps' caches to honour it) and is the one the downloader's
/// pre-flight uses, so it is the one that decides whether a download starts. The smaller
/// one is closer to what Settings shows the user.
///
/// Showing the honest number and calling it "available" would look like a lie to anyone who
/// just read Settings. So: show the one that governs, and don't pretend the other isn't
/// there.
private struct DiskRow: View {
    private var important: Int64? {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    private var storeBytes: Int64 {
        SharedModelStore.installedRepos().reduce(0) { $0 + SharedModelStore.sizeOnDisk($1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Models on this phone", systemImage: "internaldrive")
                    .font(.subheadline)
                Spacer()
                Text(format(storeBytes))
                    .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
            if let important {
                Text("\(format(important)) available for downloads")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func format(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useGB, .useMB]
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}

/// The model-status dot — **the one place the three-state metaphor lives**, so it cannot
/// drift again. It already had: a blue "installed" dot crept into the Model Library while
/// the same logic sat, subtly different, in Preferences. Preferences.swift itself warns
/// *"two places to change a thing is how they drift"* — this is that lesson applied to the
/// dot (Principle 7: enforce the constraint in code, don't just document it).
///
/// Adopted verbatim from Hal's `modelStatusDot` and its dot-language directive:
///
///   • **GREEN** — downloaded and active
///   • **GREY**  — downloaded but not active
///   • **(no dot)** — not downloaded
///
/// No blue, no orange-downloading, no red-error. Download progress and errors have their own
/// UI (the progress bar and the red error row in the model card). When the model isn't
/// downloaded this renders nothing at all — the **absence of a dot IS the state**, exactly as
/// Hal does it.
struct ModelStatusDot: View {
    let isDownloaded: Bool
    let isActive: Bool

    var body: some View {
        if isDownloaded {
            Circle()
                .fill(isActive ? Color.green : Color.gray.opacity(0.5))
                .frame(width: 8, height: 8)
                .accessibilityLabel(isActive ? "Downloaded and active" : "Downloaded")
        }
        // No dot when not downloaded.
    }
}

// MARK: - The license, before you take it

/// Shown before a model download begins — the studio's model-license surface, ported from
/// Hal's `ModelLicenseSheet` (via Posey's `AskPoseyModelLicenseSheet`). It names the license,
/// states the download size, and links to the full terms on Hugging Face, then asks the user
/// to accept before anything is fetched.
///
/// Simpler than Posey's here for one honest reason: Thomas's `CameraModel.licence` is already
/// a display-ready string (Principle 2 — "Stability AI Community License — free under $1M
/// revenue", not a code), so there's no code-to-name switch to maintain. The important terms
/// live in the catalog, next to the model.
/// The responsible-use restrictions surfaced in the acceptance sheet (Mark, 2026-07-27): the actual
/// prohibited-uses clause from a model's license, shown before download so the user accepts the
/// specific terms, not just a link. This is how we pass OpenRAIL's use-restrictions downstream (its
/// core obligation). Text is verbatim from each license's use-restriction section, not paraphrased.
nonisolated enum ResponsibleUse {
    /// CreativeML OpenRAIL-M / ++-M — Attachment A "Use Restrictions", verbatim (fetched from the
    /// license 2026-07-27). Applies to the SD-2.1 (Core ML) hand.
    static let openRAIL = """
    By downloading and using this model you agree NOT to use it, per its CreativeML OpenRAIL license:

    1. In any way that violates any applicable national, federal, state, local or international law or regulation.
    2. For the purpose of exploiting, harming or attempting to exploit or harm minors in any way.
    3. To generate or disseminate verifiably false information and/or content with the purpose of harming others.
    4. To generate or disseminate personal identifiable information that can be used to harm an individual.
    5. To defame, disparage or otherwise harass others.
    6. For fully automated decision making that adversely impacts an individual's legal rights or otherwise creates or modifies a binding, enforceable obligation.
    7. For any use intended to or which has the effect of discriminating against or harming individuals or groups based on online or offline social behavior or known or predicted personal or personality characteristics.
    8. To exploit any of the vulnerabilities of a specific group of persons based on their age, social, physical or mental characteristics, in order to materially distort the behavior of a person pertaining to that group in a manner that causes or is likely to cause that person or another person physical or psychological harm.
    9. For any use intended to or which has the effect of discriminating against individuals or groups based on legally protected characteristics or categories.
    10. To provide medical advice and medical results interpretation.
    11. To generate or disseminate information for the purpose to be used for administration of justice, law enforcement, immigration or asylum processes, such as predicting an individual will commit fraud/crime commitment.
    """

    /// sd-turbo is under the Stability AI Community License, which requires compliance with Stability's
    /// Acceptable Use Policy. Reproduced VERBATIM below — the prohibited-use list from
    /// stability.ai/use-policy (effective 2025-07-31), fetched 2026-07-28 — to match the OpenRAIL
    /// treatment for SD-2.1 (Mark, 2026-07-28: surface the actual restrictions, not a paraphrase). The
    /// model-page link below the sheet carries the complete, current policy.
    static let stabilityAUP = """
    By downloading and using this model you agree to the Stability AI Community License and its Acceptable Use Policy (effective July 31, 2025). Stability prohibits using the technology to facilitate:

    Violations of law or others' rights:
    • violations of law or others' rights, including intellectual property and privacy rights.
    • violations of AI laws, such as: using subliminal, manipulative, or deceptive techniques that can distort a person's ability to make informed decisions and is likely to cause harm; exploiting vulnerabilities due to age, disability, or socio-economic situations; evaluating or classifying persons based on their social behavior, personal characteristics, or the use of social scoring leading to detrimental or unfavorable treatment; assessing or predicting the risk of a person committing a crime, based solely on profiling or personal traits; creating or expanding facial recognition databases without consent; inferring emotions in the workplace or education institution, except for medical or safety reasons; categorizing people based on their biometric data to infer their race, political opinion, trade union membership, religious or philosophical beliefs, sex life or sexual orientation; and using real-time biometric identification systems in public spaces for law enforcement purposes.
    • sharing of personal information without consent.
    • provision of advice on essential services, including in the medical or health field, without review by a qualified professional and disclosure of the use of AI assistance and its potential limitations.

    Harm to or exploitation against children:
    • child sexual abuse material (CSAM), sexual exploitation, grooming, or trafficking of minors.
    • exploiting or abusing minors, including sextortion or any impersonation or enticement of minors for exploitative purposes.
    • pedophilic behavior, such as through suggestive depictions of minors.

    Sexually explicit content:
    • non-consensual intimate imagery (NCII).
    • illegal pornographic content.
    • content relating to sexual intercourse, sexual acts, or sexual violence.

    Emotional or physical harm to others or self:
    • encouragement or instructions related to self harm or harm to others.
    • discrimination, threats, or promotion of violence or hateful content based on protected attributes.
    • support for organizations or individuals associated with terrorism or hate.
    • content relating to human trafficking or exploitation.
    • extreme gore, such as content involving bodily destruction, mutilation, torture or animal abuse.
    • the development or manufacturing of any illegal or regulated weapons.

    Circumvention of safeguards:
    • intentional bypassing of product safeguards or restrictions established within Stability Technology.
    • intentional bypassing of an account ban, such as by creating new accounts.
    • malicious code, malware, computer viruses, or any activity that could interfere with the integrity of a website or system.

    Deceiving or misleading others:
    • misinformation or disinformation.
    • impersonation of others without consent or legal right, including defamatory content.
    • misleading end users about the nature of outputs from Stability AI Technology (such as pretending it was made by a human) or failing to appropriately disclose when someone is interacting with AI where it is not apparent.
    • content that may disrupt democratic or judicial processes, including content that discourages participation in elections.
    """

    /// The responsible-use text to surface for a model, or nil (Apache-2.0 models — Qwen, Smol — are
    /// permissive and carry no use-restrictions).
    static func restrictions(for model: CameraModel) -> String? {
        switch model.id {
        case ModelCatalog.coreMLSD21.id: return openRAIL
        case ModelCatalog.sdTurbo.id:    return stabilityAUP
        default:                          return nil
        }
    }
}

struct ModelLicenseSheet: View {
    let model: CameraModel
    let onAccept: () -> Void
    let onCancel: () -> Void

    private var useRestrictions: String? { ResponsibleUse.restrictions(for: model) }

    /// The model card / full terms on Hugging Face. `model.id` is the repo id for both
    /// downloadable models (`stabilityai/sd-turbo`, and Qwen's repo).
    private var licenseURL: URL? {
        guard !model.isBuiltIn else { return nil }
        return URL(string: "https://huggingface.co/\(model.id)")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.licence ?? "License Agreement")
                            .font(.title3).fontWeight(.bold)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("By downloading \(model.displayName), you agree to its license terms.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }

                    // The actual use-restrictions, surfaced in-app (not just linked) so acceptance is
                    // of the specific terms — how OpenRAIL's "pass the restrictions downstream" duty
                    // is met (Mark, 2026-07-27). Only for models that carry such restrictions.
                    if let restrictions = useRestrictions {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Responsible use", systemImage: "hand.raised.fill")
                                .font(.subheadline).fontWeight(.semibold)
                            Text(restrictions)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }

                    if let gb = model.sizeGB {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text("Download: \(String(format: "%.1f", gb)) GB")
                                    .fontWeight(.semibold)
                            }
                            Text("Requires \(String(format: "%.1f", gb)) GB of storage and bandwidth. Wi-Fi recommended.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    if let url = licenseURL {
                        Link(destination: url) {
                            HStack {
                                Image(systemName: "link")
                                Text("View full license on Hugging Face")
                                Spacer()
                                Image(systemName: "arrow.up.right")
                            }
                            .font(.subheadline)
                        }
                        .padding()
                        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }

                    VStack(spacing: 12) {
                        Button(action: onAccept) {
                            Text("Accept & Download")
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        Button(action: onCancel) {
                            Text("Cancel").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding()
            }
            .navigationTitle(model.displayName)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Shared model actions (one path for the buttons AND the antenna)

/// Start a model download: resolve the exact files, then hand off to the downloader. Called by the
/// Model Library's Download button (via its license sheet's Accept) and by the antenna's license
/// verb, so a human and the antenna take the SAME path — the antenna must never exercise a parallel
/// copy that could pass while the real one is broken (antenna human-parity, Mark 2026-07-20).
@MainActor func startModelDownload(_ model: CameraModel) {
    Task {
        // `.files` returns its named list; a `.folder` model (the CoreML drawer) fetches the repo
        // tree and takes its subtree. A resolution failure surfaces as a download error the row
        // shows, rather than a silent no-op.
        let files: [String]?
        do {
            files = try await model.downloadFileList()
        } catch {
            cameraLog("DOWNLOAD: could not resolve file list for \(model.id) — \(error.localizedDescription)")
            MLXModelDownloader.shared.reportDownloadFailure(
                modelID: model.id,
                message: "Couldn't start \(model.displayName): \(error.localizedDescription)")
            return
        }
        await MLXModelDownloader.shared.startDownload(
            modelID: model.id,
            repoID: model.id,
            // Measured, not estimated. Without a size the downloader's pre-flight refuses outright.
            sizeGB: model.sizeGB,
            // The whole reason a diffusion model is downloadable at all (sd-turbo: 2.40 GB, not 12.07).
            files: files
        )
    }
}

/// Give up this camera's claim on a model and remove the files if we were the last to hold them
/// (`deleteModel` enforces exactly that). If the model is the resident eye, drop it from memory and
/// fall back to the built-in seer first, so nothing points at weights that are gone. The one copy of
/// the rule, shared by the Delete button and the antenna's /release verb (which delegates here rather
/// than reimplementing release-and-remove — 2026-07-30 parity fix).
@MainActor func deleteModelEverywhere(_ model: CameraModel) async {
    guard !model.isBuiltIn else { return }
    if model.job == .seeing {
        if await MLXEyeLoader.shared.isLoadedRepo(model.id) {
            await MLXEyeLoader.shared.unload()
        }
        if Settings.shared.seer.modelID == model.id { Settings.shared.seer = .apple }
    }
    await MLXModelDownloader.shared.deleteModel(modelID: model.id)
    // Refresh the one shared catalog at the deletion SOURCE, so every path that deletes — the Delete
    // button AND the antenna's /release — updates every screen's dots identically. (A delete posts no
    // notification, unlike a download.) Putting it here, not in the button's handler, is what keeps the
    // antenna faithful to the human path and mirrors Hal calling refreshDownloadStates after deleteModel.
    ModelCatalogService.shared.refresh()
}

#if DEBUG
/// A tiny bridge the antenna uses to drive UI a human reaches by tapping. It NEVER presents a parallel
/// copy of a screen; each field is a request that the view OWNING the real control observes and mirrors
/// into the SAME state a finger sets, so what the antenna opens is byte-for-byte what a tap opens (Mark,
/// 2026-07-28: "why aren't there verbs to tap what a human would?"). Driven by `handleOpen` / `handleLicense`.
///
/// DEBUG-ONLY (gated 2026-07-27): this is antenna plumbing (its own docs say so) and is set only by the
/// DEBUG-only `LocalAPIServer`. It used to compile into Release along with its `CameraView` consumers,
/// which shipped antenna test scaffolding into the production binary. It is now `#if DEBUG` so it exists
/// in no shipping build. Real users' license flow is independent (Model Library's `$modelForLicense`).
@MainActor @Observable final class AntennaUIBridge {
    static let shared = AntennaUIBridge()
    private init() {}
    /// When non-nil, `CameraView` presents `ModelLicenseSheet` for this model. Cleared on accept/cancel.
    var licenseModel: CameraModel?

    // Tap-the-real-control requests (one-shot). The antenna sets one true; the view that owns that
    // control flips its own real @State exactly as the gear, the pill, and the "Browse Model Library"
    // row do — no parallel presenter — then the flag is cleared. See `POST /open`.

    /// = tapping the Preferences gear. `CameraView` mirrors this into its real `showingPreferences`.
    var tapPreferences = false
    /// = tapping the dark-room pill. `StatusFeedView` mirrors this into its real `showingDarkRoom`.
    var tapDarkRoom = false
    /// = opening Preferences and pushing "Browse Model Library" (the library lives inside Preferences).
    /// `CameraView` opens Preferences; `PreferencesView` pushes the library onto its own nav stack while
    /// this stays true, and clears it when the library is popped.
    var tapModelLibrary = false
}
#endif

// ==== LEGO END: 25 ModelLibraryView (The Model Library) ====
