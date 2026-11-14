//
//  DarkRoomView.swift
//  Thomas / AI Camera
//
//  The Dark Room screen — the one place you can watch and manage the developing queue.
//
//  The capture screen stays sacred and dumb: viewfinder + shutter, nothing else. Everything about
//  the QUEUE lives here instead, reached from the "Developing N" status (tap it) or from a button in
//  Preferences. It is a passive-plus-management view: it shows each waiting shot and its stage, and
//  it gives exactly the controls Mark asked for (2026-07-21) — pause, purge, swipe-to-delete one,
//  drag-to-reorder — plus the second home for "load a picture to develop" (the library door that
//  used to sit on the capture screen and was kept dormant precisely so it could plug in here).
//
//  It owns no pipeline logic. The worker (`DarkRoomWorker`) develops; the store (`DarkRoomStore`)
//  persists. This view reads the store for the list and the worker's observable state for the live
//  stage of the one shot developing, and calls store/worker methods for the user's actions.
//

import SwiftUI
import PhotosUI
import ImageIO
import UIKit

// ==== LEGO START: 35 The Dark Room Screen (The Developing Queue) ====

struct DarkRoomView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var worker = DarkRoomWorker.shared
    @State private var records: [ShotRecord] = []
    @State private var thumbnails: [UUID: Image] = [:]
    /// Developed shots whose negatives the dark room still keeps (NegativeStore), newest first.
    @State private var negatives: [NegativeMeta] = []
    @State private var pickerItem: PhotosPickerItem?
    @State private var confirmingPurgeAll = false
    /// The shot whose development the Developer Tray is showing (pushed by its row's Watch button).
    @State private var watching: WatchTarget?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controlBar
                Divider()
                content
            }
            .navigationTitle("The Dark Room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { if !records.isEmpty || !negatives.isEmpty { EditButton() } }
            }
            .safeAreaInset(edge: .bottom) { loadBar }
            // Full screen, not pushed inside this sheet: the tray's picture is the whole canvas.
            .fullScreenCover(item: $watching) { target in DeveloperTrayView(shotID: target.id) }
        }
        .task { await reload() }
        // Reload the list whenever a shot is added (count changes) or one lands in Photos
        // (arrivals bumps). The live stage of the developing shot updates on its own — each row
        // reads the worker's observable `currentStage`, so no reload is needed for that.
        .onChange(of: worker.developingCount) { _, _ in Task { await reload() } }
        .onChange(of: worker.arrivals) { _, _ in Task { await reload() } }
        .onChange(of: pickerItem) { _, item in load(item) }
        #if DEBUG
        // Human parity: the antenna taps the developing shot's Watch button (`POST /open` X-Screen: tray).
        .onChange(of: AntennaUIBridge.shared.tapWatch) { _, tap in
            guard tap else { return }
            if let id = worker.currentShotID { watching = WatchTarget(id: id) }
            AntennaUIBridge.shared.tapWatch = false
        }
        .onAppear {
            if AntennaUIBridge.shared.tapWatch, let id = worker.currentShotID {
                watching = WatchTarget(id: id)
                AntennaUIBridge.shared.tapWatch = false
            }
            if let id = AntennaUIBridge.shared.tapWatchShot {
                watching = WatchTarget(id: id)
                AntennaUIBridge.shared.tapWatchShot = nil
            }
        }
        .onChange(of: AntennaUIBridge.shared.tapWatchShot) { _, id in
            guard let id else { return }
            watching = WatchTarget(id: id)
            AntennaUIBridge.shared.tapWatchShot = nil
        }
        #endif
        .confirmationDialog("Purge the whole queue? This permanently deletes every shot still waiting to develop.",
                            isPresented: $confirmingPurgeAll, titleVisibility: .visible) {
            Button("Purge All", role: .destructive) { purgeAll() }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - The two top controls (Mark: pause + purge, at the top)

    private var controlBar: some View {
        HStack {
            Button {
                worker.isPaused ? worker.resume() : worker.pause()
            } label: {
                Label(worker.isPaused ? "Resume" : "Pause",
                      systemImage: worker.isPaused ? "play.fill" : "pause.fill")
            }
            Spacer()
            Button(role: .destructive) {
                confirmingPurgeAll = true
            } label: {
                Label("Purge", systemImage: "trash")
            }
            .disabled(records.isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    // MARK: - The list (or the empty state)

    @ViewBuilder private var content: some View {
        if records.isEmpty && negatives.isEmpty {
            ContentUnavailableView {
                Label("The dark room is empty", systemImage: "tray")
            } description: {
                Text("Shots you take appear here while they develop, then land in Photos. You can also load a picture to develop below.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                // Why nothing may be moving: the phone is too hot, or the user paused. (Blocked
                // shots say so on their own row.) The pill shows the same condition from outside.
                if worker.isCoolingDown {
                    Label("Cooling down - the \(ThisDevice.deviceKind) is too hot to develop. Shots resume automatically when it cools.",
                          systemImage: "snowflake")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                if worker.isPaused {
                    Text("Paused - nothing new develops until you resume.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(records) { record in
                    DarkRoomRow(record: record, worker: worker, thumbnail: thumbnails[record.id],
                                onWatch: { watching = WatchTarget(id: record.id) })
                }
                .onDelete { delete($0) }
                .onMove { move($0, $1) }

                // Developed: the prints are in Photos; the negatives hang here for a while so the
                // Developer Tray can open them again. Swiping one away deletes only the negative.
                if !negatives.isEmpty {
                    Section {
                        ForEach(negatives) { n in
                            NegativeRow(negative: n, thumbnail: thumbnails[n.id],
                                        onWatch: { watching = WatchTarget(id: n.id) })
                        }
                        .onDelete { deleteNegatives($0) }
                    } header: {
                        Text("Developed - in Photos; negatives kept here")
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    // MARK: - The library door (second home for "load a picture")

    private var loadBar: some View {
        PhotosPicker(selection: $pickerItem, matching: .images) {
            Label("Load a picture to develop", systemImage: "photo.on.rectangle.angled")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .padding()
        .background(.bar)
    }

    // MARK: - Data + actions

    private func reload() async {
        let recs = await DarkRoomStore.shared.pending()
        let negs = await NegativeStore.shared.list()
        var thumbs: [UUID: Image] = [:]
        for r in recs {
            if let cg = await DarkRoomStore.shared.thumbnail(for: r, maxPixel: 160) {
                thumbs[r.id] = Image(uiImage: UIImage(cgImage: cg))
            }
        }
        for n in negs where thumbs[n.id] == nil {
            if let cg = await NegativeStore.shared.thumbnail(n.id, maxPixel: 160) {
                thumbs[n.id] = Image(uiImage: UIImage(cgImage: cg))
            }
        }
        records = recs
        negatives = negs
        thumbnails = thumbs
    }

    private func deleteNegatives(_ offsets: IndexSet) {
        let ids = offsets.map { negatives[$0].id }
        negatives.remove(atOffsets: offsets)
        Task {
            for id in ids { await NegativeStore.shared.remove(id) }
            await reload()
        }
    }

    private func delete(_ offsets: IndexSet) {
        let ids = offsets.map { records[$0].id }
        records.remove(atOffsets: offsets)                 // optimistic — the store follows
        Task {
            // Through the worker, so its counts (which drive the capture-screen pill) stay in sync.
            await DarkRoomWorker.shared.remove(ids: ids)
            await reload()
        }
    }

    private func move(_ from: IndexSet, _ to: Int) {
        records.move(fromOffsets: from, toOffset: to)      // optimistic
        let ids = records.map(\.id)
        Task { await DarkRoomStore.shared.reorder(ids); await reload() }
    }

    private func purgeAll() {
        records = []
        // Through the worker, so the "Developing N" pill can't survive an emptied queue.
        Task { await DarkRoomWorker.shared.purgeAll(); await reload() }
    }

    private func load(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            defer { pickerItem = nil }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
            // Upright before it goes anywhere — same rule the shutter and the old library door used.
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
            let raw = props?[kCGImagePropertyOrientation] as? UInt32 ?? 1
            let orientation = CGImagePropertyOrientation(rawValue: raw) ?? .up
            // A picture imported from the library has no capture location, so no place stamp.
            await DarkRoomWorker.shared.enqueue(cg.uprighted(orientation), place: nil)
            await reload()
        }
    }
}

// MARK: - One shot's row

private struct DarkRoomRow: View {
    let record: ShotRecord
    /// Read (not owned) so the row can show the live stage of the one shot developing. `DarkRoomWorker`
    /// is `@Observable`, so reading `currentShotID` / `currentStage` here tracks their changes.
    let worker: DarkRoomWorker
    let thumbnail: Image?
    /// Opens the Developer Tray for this shot. Offered only on the shot that is developing now.
    let onWatch: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            thumb
            VStack(alignment: .leading, spacing: 3) {
                Text(statusText)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(statusColor)
                if let subText {
                    Text(subText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isDeveloping {
                Button("Watch", action: onWatch)
                    .buttonStyle(.bordered)
                    .font(.subheadline.weight(.semibold))
            }
        }
        .padding(.vertical, 4)
    }

    private var thumb: some View {
        Group {
            if let thumbnail {
                thumbnail.resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: 54, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var isDeveloping: Bool { worker.currentShotID == record.id }

    private var statusText: String {
        if record.status == .blocked {
            return "Needs \(record.blockedModel ?? "a model")"
        }
        guard isDeveloping else { return "Waiting" }
        switch worker.currentStage {
        case .seeing?:  return "Seeing…"
        case .mixing?:  return "Mixing the developer…"
        case .drawing?: return "Drawing…"
        case .saving?:  return "Saving…"
        case .none:     return "Developing…"
        }
    }

    private var statusColor: Color {
        if record.status == .blocked { return .orange }
        return isDeveloping ? .primary : .secondary
    }

    private var subText: String? {
        if record.status == .blocked {
            return "Re-download it in the Model Library to continue."
        }
        var parts: [String] = []
        if let place = record.place { parts.append(place) }
        parts.append(record.capturedAt.formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: " · ")
    }
}

/// One developed shot whose negative is kept: its photograph, the start of its words, when it was
/// taken, and Watch, which opens it in the Developer Tray.
private struct NegativeRow: View {
    let negative: NegativeMeta
    let thumbnail: Image?
    let onWatch: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Color.gray.opacity(0.2)
                if let thumbnail { thumbnail.resizable().scaledToFill() }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(negative.firstWords)
                    .font(.subheadline)
                    .lineLimit(2)
                Text(negative.capturedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Watch", action: onWatch)
                .buttonStyle(.bordered)
                .font(.caption.weight(.semibold))
        }
        .padding(.vertical, 2)
    }
}

/// A shot to watch in the Developer Tray (`navigationDestination(item:)` needs Identifiable + Hashable).
private struct WatchTarget: Identifiable, Hashable { let id: UUID }

// ==== LEGO END: 35 The Dark Room Screen (The Developing Queue) ====
