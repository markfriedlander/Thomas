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

// ==== LEGO START: 38 The Dark Room Screen (The Developing Queue) ====

struct DarkRoomView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var worker = DarkRoomWorker.shared
    @State private var records: [ShotRecord] = []
    @State private var thumbnails: [UUID: Image] = [:]
    @State private var pickerItem: PhotosPickerItem?
    @State private var confirmingPurgeAll = false

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
                ToolbarItem(placement: .topBarTrailing) { if !records.isEmpty { EditButton() } }
            }
            .safeAreaInset(edge: .bottom) { loadBar }
        }
        .task { await reload() }
        // Reload the list whenever a shot is added (count changes) or one lands in Photos
        // (arrivals bumps). The live stage of the developing shot updates on its own — each row
        // reads the worker's observable `currentStage`, so no reload is needed for that.
        .onChange(of: worker.developingCount) { _, _ in Task { await reload() } }
        .onChange(of: worker.arrivals) { _, _ in Task { await reload() } }
        .onChange(of: pickerItem) { _, item in load(item) }
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
        if records.isEmpty {
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
                    Label("Cooling down — the phone is too hot to develop. Shots resume automatically when it cools.",
                          systemImage: "snowflake")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                if worker.isPaused {
                    Text("Paused — nothing new develops until you resume.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(records) { record in
                    DarkRoomRow(record: record, worker: worker, thumbnail: thumbnails[record.id])
                }
                .onDelete { delete($0) }
                .onMove { move($0, $1) }
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
        var thumbs: [UUID: Image] = [:]
        for r in recs {
            if let cg = await DarkRoomStore.shared.thumbnail(for: r, maxPixel: 160) {
                thumbs[r.id] = Image(uiImage: UIImage(cgImage: cg))
            }
        }
        records = recs
        thumbnails = thumbs
    }

    private func delete(_ offsets: IndexSet) {
        let ids = offsets.map { records[$0].id }
        records.remove(atOffsets: offsets)                 // optimistic — the store follows
        Task {
            for id in ids { await DarkRoomStore.shared.remove(id: id) }
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
        Task { await DarkRoomStore.shared.removeAll(); await reload() }
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
            if isDeveloping { ProgressView() }
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

// ==== LEGO END: 38 The Dark Room Screen (The Developing Queue) ====
