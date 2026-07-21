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

// ==== LEGO START: 28 ModelLibraryView (The Model Library) ====

struct ModelLibraryView: View {
    @State private var settings = Settings.shared
    @ObservedObject private var downloader = MLXModelDownloader.shared
    @State private var confirmingDelete: CameraModel?
    /// The model whose license sheet is open. Set when the user taps Download; the actual
    /// download only starts once they accept — the studio's surface-the-license-before-you-
    /// -take-it pattern, ported from Hal/Posey (`ModelLicenseSheet` below).
    @State private var modelForLicense: CameraModel?
    /// Recomputed on download completion — `isInstalled` reads the disk, which SwiftUI
    /// cannot observe. See `.onReceive` below.
    @State private var refreshToken = 0
    /// How many queued shots still need each model (by model id), so the delete confirmation can
    /// warn that deleting will pause them. Loaded from the dark room store on appear and refreshed
    /// when a model lands.
    @State private var queuedUsage: [String: Int] = [:]

    var body: some View {
        List {
            ForEach([ModelJob.seeing, ModelJob.drawing], id: \.self) { job in
                Section {
                    ForEach(ModelCatalog.models(for: job)) { model in
                        ModelLibraryRow(
                            model: model,
                            isActive: isActive(model),
                            downloader: downloader,
                            onUse:      { use(model) },
                            onDownload: { requestDownload(model) },
                            onCancel:   { downloader.cancelDownload(modelID: model.id) },
                            onDelete:   { confirmingDelete = model }
                        )
                        .id("\(model.id)-\(refreshToken)")
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
        // The row's "installed" state is a question about the filesystem, and SwiftUI has no
        // way to know the answer changed. The downloader posts when a model lands; that's
        // the cue to look again.
        .onReceive(NotificationCenter.default.publisher(for: .mlxModelDidDownload)) { _ in
            refreshToken += 1
            // A model just landed — let the queue develop anything that was blocked waiting for it,
            // and refresh the "shots still use this" counts behind the delete warning.
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
        // Surface the model's license before the download begins. Hangs off the stable List,
        // not a row (rows come and go with `refreshToken`, which would tear the sheet down).
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
    private func isActive(_ model: CameraModel) -> Bool {
        switch model.job {
        case .seeing:  return ModelCatalog.model(for: settings.seer).id == model.id
        case .drawing: return settings.drawsThirdFrame
        }
    }

    private func use(_ model: CameraModel) {
        guard model.job == .seeing else { return }
        // Just records which eye the next press uses — no load/unload. Under the model-ownership
        // rule (see `Settings.seer`), the dark room queue's worker owns all model loading; the
        // live setting is only a recording template.
        switch model.id {
        case ModelCatalog.apple.id: settings.seer = .apple
        case ModelCatalog.qwen.id:  settings.seer = .qwen
        default: break
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

    private func download(_ model: CameraModel) {
        Task {
            await downloader.startDownload(
                modelID: model.id,
                repoID: model.id,
                // Measured, not estimated, and not from a catalog we don't have. Without a
                // size the downloader's pre-flight refuses outright — which is exactly why
                // nothing could ever be downloaded before this file existed.
                sizeGB: model.sizeGB,
                // The whole reason a diffusion model is downloadable at all. Without it,
                // sd-turbo is 12.07 GB rather than 2.40.
                files: model.fileAllowlist
            )
        }
    }

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
    private func delete(_ model: CameraModel) {
        confirmingDelete = nil
        guard !model.isBuiltIn else { return }
        Task {
            if model.id == Qwen.repo, await QwenLoader.shared.isLoaded {
                await QwenLoader.shared.unload()
                await MainActor.run {
                    if settings.seer == .qwen { settings.seer = .apple }
                }
            }
            await downloader.deleteModel(modelID: model.id)
            await MainActor.run { refreshToken += 1 }
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
        ModelStatusDot(isDownloaded: model.isInstalled, isActive: isActive)
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
            if !model.isInstalled {
                Button(action: onDownload) {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else {
                // The Select / Active control, in Hal's language and style so the studio
                // reads the same everywhere (Mark, 2026-07-18 — "same language everywhere
                // possible so people don't have to figure anything out"). Seeing models are
                // chosen here; a drawing model shows "Active" when it's drawing the third
                // frame (its on/off lives in the hand's Preferences, nothing to select).
                if model.job == .seeing {
                    Button(action: onUse) {
                        HStack(spacing: 4) {
                            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                            Text(isActive ? "Active" : "Select")
                        }
                        .foregroundColor(isActive ? .secondary : .accentColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(isActive)
                } else if isActive {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Active")
                    }
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if !model.isBuiltIn {
                    Button(role: .destructive, action: onDelete) {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
            if !model.isInstalled { Spacer() }
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
struct ModelLicenseSheet: View {
    let model: CameraModel
    let onAccept: () -> Void
    let onCancel: () -> Void

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

// ==== LEGO END: 28 ModelLibraryView (The Model Library) ====
