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

/// The Dark Room's colors (design pass 2026-11-14, Mark chose the "mix"): a warm near-black, tiles on one
/// dark band, and a safelight red on what is still developing. The reds are light enough to read on the
/// dark ground (systemRed's dark tint and a lighter coral for text).
enum Safelight {
    static let ground = Color(red: 0.07, green: 0.027, blue: 0.027)
    static let band = Color(red: 0.11, green: 0.07, blue: 0.063)
    static let bandDeveloped = Color(red: 0.10, green: 0.08, blue: 0.07)
    static let empty = Color(red: 0.055, green: 0.035, blue: 0.03)
    static let tileDark = Color(red: 0.165, green: 0.09, blue: 0.082)
    static let red = Color(red: 1, green: 0.27, blue: 0.23)
    static let text = Color(red: 1, green: 0.54, blue: 0.5)
    static let paper = Color(red: 0.957, green: 0.945, blue: 0.918)
}

struct DarkRoomView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var worker = DarkRoomWorker.shared
    @State private var settings = Settings.shared
    @State private var records: [ShotRecord] = []
    @State private var thumbnails: [UUID: UIImage] = [:]
    /// Developed shots' drawings, for the third tile of their rows.
    @State private var drawings: [UUID: UIImage] = [:]
    /// Developed shots whose negatives the dark room still keeps (NegativeStore), newest first.
    @State private var negatives: [NegativeMeta] = []
    /// The pictures chosen from the library, in the order picked; they join the queue in that order.
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var confirmingPurgeAll = false
    @State private var confirmingClearNegatives = false
    @State private var negativesBytes = 0
    @State private var help: PrefHelp?
    /// The shot whose development the Developer Tray is showing (pushed by its row's Watch button).
    @State private var watching: WatchTarget?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controlBar
                content
            }
            .background(backdrop)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text("THE DARK ROOM").font(.headline.weight(.heavy)).tracking(2)
                        if worker.developingCount > 0 {
                            Text("\(worker.developingCount) in the bath").font(.caption.weight(.semibold)).foregroundStyle(Safelight.text)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                    // The top bar limits how large its title grows (item 71); a long press shows it large, as
                    // Apple's own bar titles do.
                    .accessibilityShowsLargeContentViewer()
                }
                ToolbarItem(placement: .topBarLeading) { Button(role: .close) { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { if !records.isEmpty || !negatives.isEmpty { EditButton() } }
                // Mark, 2026-11-14: the Dark Room had no "?" like the tray and Preferences.
                ToolbarItem(placement: .topBarTrailing) {
                    Button { help = Self.roomHelp } label: { Image(systemName: "questionmark") }
                        .accessibilityLabel("About the Dark Room")
                }
            }
            // The bar floats at the bottom, except in an empty room at the accessibility text sizes, where it
            // follows the message instead (see `content`).
            .safeAreaInset(edge: .bottom) { if !loadBarFollowsMessage { loadBar } }
            // Full screen, not pushed inside this sheet: the tray's picture is the whole canvas.
            .fullScreenCover(item: $watching) { target in DeveloperTrayView(shotID: target.id, followsQueue: target.followsQueue) }
        }
        .overlay { if let help { PrefHelpCard(help: help) { self.help = nil }.transition(.opacity) } }
        .animation(.easeInOut(duration: 0.2), value: help)
        .preferredColorScheme(.dark)
        .tint(.white)
        .task { await reload() }
        // Reload the list whenever a shot is added (count changes) or one lands in Photos (arrivals bumps).
        // The live row updates on its own (it reads the worker and the trace).
        .onChange(of: worker.developingCount) { _, _ in Task { await reload() } }
        .onChange(of: worker.arrivals) { _, _ in Task { await reload() } }
        .onChange(of: pickerItems) { _, items in load(items) }
        #if DEBUG
        // Human parity: the antenna taps the developing shot's Watch button (`POST /open` X-Screen: tray).
        .onChange(of: AntennaUIBridge.shared.tapWatch) { _, tap in
            guard tap else { return }
            if let id = worker.currentShotID { watching = WatchTarget(id: id) }
            AntennaUIBridge.shared.tapWatch = false
        }
        // The antenna taps "Watch the queue" (`POST /open` X-Screen: tray, X-Follow: queue).
        .onChange(of: AntennaUIBridge.shared.tapWatchAll) { _, tap in
            guard tap else { return }
            watchAll()
            AntennaUIBridge.shared.tapWatchAll = false
        }
        .onAppear {
            if AntennaUIBridge.shared.tapWatchAll {
                watchAll()
                AntennaUIBridge.shared.tapWatchAll = false
            }
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
        .confirmationDialog("Clear every kept negative? The Developer Tray can no longer open those shots. Their photos, words and drawings stay in Photos.",
                            isPresented: $confirmingClearNegatives, titleVisibility: .visible) {
            Button("Clear Negatives", role: .destructive) {
                Task { await NegativeStore.shared.removeAll(); negativesBytes = 0; await reload() }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    static let roomHelp = PrefHelp(id: "darkroom", kicker: "THE DARK ROOM", title: "Where shots develop",
        body: "A shot takes real seconds to develop, so you can keep shooting while it does. Every shot waits here in the bath, then lands in Photos.\n\nEach row is one shot: the photo, then the eye's words, then the hand's drawing, filling in as it develops. The one glowing red is developing now; Watch opens it in the Developer Tray. With more than one shot waiting, Watch the queue follows them one after another.\n\nPause holds the queue; Purge empties it. Swipe a row to delete it, or tap Edit to reorder. If the \(ThisDevice.deviceKind) gets hot, developing waits until it cools; nothing is lost.\n\nAfter a shot lands in Photos, its negative stays here for a while: the machine's workings, so the Developer Tray can open it again.")

    /// The safelight: a red glow from the top of the room, over a warm near-black.
    private var backdrop: some View {
        ZStack(alignment: .top) {
            Safelight.ground
            RadialGradient(colors: [Safelight.red.opacity(worker.developingCount > 0 ? 0.42 : 0.2), Safelight.red.opacity(0.08), .clear],
                           center: .top, startRadius: 0, endRadius: 360)
                .frame(height: 380)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    // MARK: - The top controls (Mark: pause + purge, at the top)

    private var controlBar: some View {
        // Side by side while they fit on one line each; stacked when they don't, so the words grow with the
        // reader's text size all the way. Before, they stopped growing past the largest standard size (capped,
        // with a long-press magnifier), which Apple's audit rightly reported as text that doesn't grow (phone
        // audit, 2026-11-15, items 72 and 74). At ordinary sizes nothing changes.
        ViewThatFits(in: .horizontal) {
            // No line limit: ViewThatFits already picks the stack before a word would wrap, and a one-line limit
            // read to Apple's audit as text that will clip (re-audit, 2026-11-15).
            HStack(spacing: 10) { controlButtons }
            VStack(alignment: .leading, spacing: 0) { controlButtons }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
        .buttonStyle(.plain)
        .padding(.horizontal)
        .padding(.vertical, 5)   // was 10; the buttons' taller touch areas took the other 5
    }

    @ViewBuilder private var controlButtons: some View {
        Button {
            worker.isPaused ? worker.resume() : worker.pause()
        } label: {
            Label(worker.isPaused ? "Resume" : "Pause", systemImage: worker.isPaused ? "play.fill" : "pause.fill")
                .padding(.horizontal, 14).padding(.vertical, 8)
                .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
                .padding(.vertical, 5).contentShape(Rectangle())   // 44 pt to press (audit walk, 2026-11-15)
        }
        .accessibilityShowsLargeContentViewer()
        // More than one shot in the bath: watch them develop one after another (Mark, 2026-11-14).
        // Watch on a row still watches just that shot.
        // "The queue", not "all" (Mark): it follows the shots still developing, not the ones already done.
        if worker.currentShotID != nil && worker.developingCount > 1 {
            Button(action: watchAll) {
                Label("Watch the queue", systemImage: "play.fill")
                    .fontWeight(.bold)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Safelight.red, in: Capsule())
                    .padding(.vertical, 5).contentShape(Rectangle())
            }
            .accessibilityShowsLargeContentViewer()
        }
        Button(role: .destructive) {
            confirmingPurgeAll = true
        } label: {
            Label("Purge", systemImage: "trash")
                .padding(.horizontal, 14).padding(.vertical, 8)
                .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
                .padding(.vertical, 5).contentShape(Rectangle())   // 44 pt to press (audit walk, 2026-11-15)
        }
        .disabled(records.isEmpty)
        .accessibilityShowsLargeContentViewer()
    }

    // MARK: - The list (or the empty state)

    /// An empty room at an accessibility text size: the "Load pictures" button follows the message, inside the
    /// scroll, instead of floating over it. Everywhere else it floats at the bottom, as designed.
    private var loadBarFollowsMessage: Bool {
        records.isEmpty && negatives.isEmpty && typeSize.isAccessibilitySize
    }

    private var emptyRoom: some View {
        ContentUnavailableView {
            Label("The dark room is empty", systemImage: "tray")
        } description: {
            Text("Shots you take appear here while they develop, then land in Photos. You can also load pictures to develop below.")
        }
    }

    @ViewBuilder private var content: some View {
        if records.isEmpty && negatives.isEmpty {
            // Always in a scroll area at least as tall as the space: centred when it fits (as before), scrolling
            // when it doesn't, and never under the "Load pictures" bar. The earlier "fits, or scrolls" choice
            // (ViewThatFits) picked "fits" at the largest text size because the empty-state view reports a height
            // it then overflows, and the words ran under the bar (phone audit at the largest size, 2026-11-15,
            // items 73 and 75).
            GeometryReader { space in
                ScrollView {
                    if loadBarFollowsMessage {
                        // At the accessibility sizes the floating bar covered the message even when it scrolled
                        // (seen on the phone at the largest size, 2026-11-15), so the button comes after it.
                        VStack(spacing: 0) { emptyRoom; loadBar }
                    } else {
                        emptyRoom.frame(maxWidth: .infinity, minHeight: space.size.height)
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        } else {
            List {
                // Why nothing may be moving: the phone is too hot, or the user paused. (Blocked
                // shots say so on their own row.) The pill shows the same condition from outside.
                if worker.photosRefused {
                    VStack(alignment: .leading, spacing: 4) {
                        // Says shots are waiting only when some are (review, 2026-11-15).
                        Label(worker.developingCount + worker.blockedCount > 0
                              ? "Thomas isn't allowed to add to Photos, so shots are waiting here."
                              : "Thomas isn't allowed to add to Photos, so a shot would wait here.",
                              systemImage: "photo.badge.exclamationmark")
                            .font(.footnote).foregroundStyle(.orange)
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            Link("Allow it in Settings", destination: url).font(.footnote.weight(.semibold))
                        }
                    }
                    .darkRoomRow()
                }
                if worker.isCoolingDown {
                    Label("Cooling down - the \(ThisDevice.deviceKind) is too hot to develop. Shots resume automatically when it cools.",
                          systemImage: "thermometer.high")   // one heat symbol across Thomas
                        .font(.footnote).foregroundStyle(.orange)
                        .darkRoomRow()
                }
                if worker.isPaused {
                    Text("Paused - nothing new develops until you resume.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .darkRoomRow()
                }
                if !records.isEmpty {
                    Section {
                        ForEach(records) { record in
                            DarkRoomRow(record: record, worker: worker, photo: thumbnails[record.id],
                                        onWatch: { watching = WatchTarget(id: record.id) })
                                .darkRoomRow()
                        }
                        .onDelete { delete($0) }
                        .onMove { move($0, $1) }
                    } header: {
                        sectionHeader("IN THE BATH · \(records.count)", color: Safelight.text)
                    }
                }
                // Developed: the prints are in Photos; the negatives hang here for a while so the
                // Developer Tray can open them again. Swiping one away deletes only the negative.
                if !negatives.isEmpty {
                    Section {
                        ForEach(negatives) { n in
                            NegativeRow(negative: n, photo: thumbnails[n.id], drawing: drawings[n.id],
                                        onWatch: { watching = WatchTarget(id: n.id) })
                                .darkRoomRow()
                        }
                        .onDelete { deleteNegatives($0) }
                    } header: {
                        sectionHeader("DEVELOPED · IN PHOTOS", color: .secondary)
                    }
                }
                negativesCard.darkRoomRow()
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func sectionHeader(_ text: String, color: Color) -> some View {
        Text(text).font(.caption.weight(.heavy)).tracking(1.6).foregroundStyle(color)
            .frame(maxWidth: 600, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .accessibilityAddTraits(.isHeader)
    }

    /// The negatives' settings live here now, in the room that keeps them (design pass 2026-11-14).
    private var negativesCard: some View {
        PrefCard {
            HStack {
                Text("Keep negatives for").font(.headline)
                Spacer(minLength: 8)
                Picker("Keep negatives for", selection: $settings.negativesToKeep) {
                    ForEach(Settings.negativeChoices, id: \.self) { Text("the last \($0) shots").tag($0) }
                }
                .labelsHidden().pickerStyle(.menu)
            }
            PrefLine("The machine's workings, so the Developer Tray can open a shot again. Now using \(NegativeStore.formatBytes(negativesBytes)).",
                     help: PrefHelp(id: "negatives", kicker: "THE DARK ROOM", title: "Negatives",
                                    body: "After a shot lands in Photos, the Dark Room keeps its negative: whatever of the machine's workings the Developer Tray can show for that shot, so you can open it again. What that is depends on the eye and hand (each Model Library card says).\n\nThe oldest are removed as new ones arrive. They stay on this \(ThisDevice.deviceKind) and are not backed up. Clearing them leaves your photos, words and drawings in Photos untouched."),
                     open: $help)
            Button("Clear kept negatives", role: .destructive) { confirmingClearNegatives = true }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Safelight.text)
                .disabled(negatives.isEmpty)
        }
        .padding(.top, 8)
        .task { negativesBytes = await NegativeStore.shared.totalBytes() }
    }

    // MARK: - The library door (second home for "load a picture")

    private var loadBar: some View {
        // As many as the person likes, no cap (Mark: never limit what a user can do; Thomas cleans up after).
        // Styled like Pause and Purge above (Mark, 2026-11-14), on a dark capsule so the list behind it doesn't show through.
        PhotosPicker(selection: $pickerItems, maxSelectionCount: nil, selectionBehavior: .ordered, matching: .images) {
            Label("Load pictures to develop", systemImage: "photo.on.rectangle.angled")
                .font(.headline).foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Safelight.ground.opacity(0.92), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    // MARK: - Data + actions

    private func reload() async {
        let recs = await DarkRoomStore.shared.pending()
        let negs = await NegativeStore.shared.list()
        var thumbs: [UUID: UIImage] = [:]
        var draws: [UUID: UIImage] = [:]
        for r in recs {
            if let cg = await DarkRoomStore.shared.thumbnail(for: r, maxPixel: 240) {
                thumbs[r.id] = UIImage(cgImage: cg)
            }
        }
        for n in negs where thumbs[n.id] == nil {
            if let cg = await NegativeStore.shared.thumbnail(n.id, maxPixel: 240) {
                thumbs[n.id] = UIImage(cgImage: cg)
            }
            if n.hasDrawing, let cg = await NegativeStore.shared.drawingThumbnail(n.id, maxPixel: 240) {
                draws[n.id] = UIImage(cgImage: cg)
            }
        }
        records = recs
        negatives = negs
        thumbnails = thumbs
        drawings = draws
        negativesBytes = await NegativeStore.shared.totalBytes()
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

    /// The picture's own "taken" date, from its EXIF (with its time-zone offset when it has one).
    static func dateTaken(_ props: [CFString: Any]?) -> Date? {
        guard let exif = props?[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        if let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String {
            f.dateFormat = "yyyy:MM:dd HH:mm:ssxxx"
            if let d = f.date(from: text + offset) { return d }
        }
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.date(from: text)
    }

    private func watchAll() {
        if let id = worker.currentShotID { watching = WatchTarget(id: id, followsQueue: true) }
    }

    /// Each chosen picture joins the queue in the order picked, one at a time (only one full-size picture
    /// is in memory at once), and its row appears as it lands. The worker develops them in turn, with the
    /// same heat protection as shots from the shutter.
    private func load(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        pickerItems = []
        Task {
            var added = 0
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let src = CGImageSourceCreateWithData(data as CFData, nil),
                      let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                    cameraLog("INTAKE: a library picture could not be read; skipped")
                    continue
                }
                // Upright before it goes anywhere — same rule the shutter and the old library door used.
                let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
                let raw = props?[kCGImagePropertyOrientation] as? UInt32 ?? 1
                let orientation = CGImagePropertyOrientation(rawValue: raw) ?? .up
                // A picture imported from the library has no capture location, so no place stamp. Its
                // footer date is when it was taken (its EXIF), not when it was loaded.
                if await DarkRoomWorker.shared.enqueue(cg.uprighted(orientation), place: nil,
                                                       takenAt: Self.dateTaken(props)) != nil { added += 1 }
                await reload()
            }
            cameraLog("INTAKE: \(added) of \(items.count) library pictures joined the queue")
        }
    }
}

private extension View {
    /// A Dark Room list row: no system background or separator, the room's own spacing.
    func darkRoomRow() -> some View {
        // A phone-like width on iPad and Mac, centered, so the tiles stay tile-sized in a wide window.
        self.frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 10, trailing: 16))
    }
}

// MARK: - The three tiles

/// Photo | words | drawing, filling in as the shot develops (Mark, 2026-11-14: "those that have been
/// completely developed show all three steps, or however many steps were assigned to that photo").
private struct ShotTiles<Words: View, Drawing: View>: View {
    let photo: UIImage?
    let showsWords: Bool
    let showsDrawing: Bool
    let band: Color
    let glowing: Bool
    @ViewBuilder let words: Words
    @ViewBuilder let drawing: Drawing

    var body: some View {
        HStack(spacing: 4) {
            tile { if let photo { Image(uiImage: photo).resizable().scaledToFill() } else { Safelight.empty } }
            if showsWords { tile { words } } else { Color.clear.aspectRatio(1, contentMode: .fit) }
            if showsDrawing { tile { drawing } } else { Color.clear.aspectRatio(1, contentMode: .fit) }
        }
        .padding(4)
        .background(band, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            if glowing {
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Safelight.red.opacity(0.55), lineWidth: 1)
            }
        }
        .shadow(color: glowing ? Safelight.red.opacity(0.4) : .clear, radius: 12)
    }

    private func tile<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        Color.clear.aspectRatio(1, contentMode: .fit)
            .overlay { c() }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// The words on a tile: paper once developed, a dark safelit card while the eye is still writing.
/// The words on a tile: a dark safelit card while the eye is still writing; once done, the print's own
/// words panel (`WordsCard`), so the tile shows what landed in Photos.
private struct WordsTile: View {
    let text: String
    let developing: Bool
    var style: WordsCard = .whiteOnBlack
    var photo: UIImage? = nil

    var body: some View {
        if developing {
            Text(text + " ▍")
                .font(.system(size: 11)).lineSpacing(1)
                .foregroundStyle(Color(red: 1, green: 0.85, blue: 0.83))
                .padding(7)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Safelight.tileDark)
        } else {
            WordsPanel(text: text, style: style, photo: photo, fontSize: 11)
        }
    }
}

// MARK: - One shot in the bath

private struct DarkRoomRow: View {
    let record: ShotRecord
    /// Read (not owned) so the row can show the live stage of the one shot developing. `DarkRoomWorker`
    /// is `@Observable`, so reading `currentShotID` / `currentStage` here tracks their changes.
    let worker: DarkRoomWorker
    let photo: UIImage?
    /// Opens the Developer Tray for this shot. Offered only on the shot that is developing now.
    let onWatch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isDeveloping {
                LiveTiles(photo: photo, showsWords: record.config.makesWords, drawsThird: record.config.makesDrawing,
                          wordsCard: record.config.effectiveWordsCard)
            } else {
                ShotTiles(photo: photo, showsWords: record.config.makesWords, showsDrawing: record.config.makesDrawing,
                          band: Safelight.band, glowing: false) {
                    Safelight.empty
                } drawing: {
                    Safelight.empty
                }
                .opacity(0.85)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(record.status == .blocked ? "Needs a model" : "Waiting to develop")
            }
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(statusText).font(.subheadline.weight(.bold)).foregroundStyle(statusColor)
                    if let subText {
                        Text(subText).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isDeveloping {
                    Button("Watch", action: onWatch)
                        .font(.subheadline.weight(.bold))
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .overlay(Capsule().strokeBorder(Safelight.text.opacity(0.8), lineWidth: 0.5))
                        .buttonStyle(.plain)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var isDeveloping: Bool { worker.currentShotID == record.id }

    private var statusText: String {
        if record.status == .blocked {
            return "Needs \(record.blockedModel ?? "a model")"
        }
        guard isDeveloping else { return "Waiting" }
        switch worker.currentStage {
        case .seeing?:  return "The eye is looking"
        case .mixing?:  return "Mixing the developer"
        case .drawing?: return "The hand is drawing"
        case .saving?:  return "Saving to Photos"
        case .none:     return "Developing"
        }
    }

    private var statusColor: Color {
        if record.status == .blocked { return .orange }
        return isDeveloping ? Safelight.text : .secondary
    }

    private var subText: String? {
        if record.status == .blocked {
            if record.blockedModel == DarkRoomWorker.appleIntelligenceName {
                return Readiness.current.explanation + " It develops on its own once Apple Intelligence is ready."
            }
            return "Download it in the Model Library to continue."
        }
        var parts: [String] = []
        if let place = record.place { parts.append(place) }
        parts.append(record.capturedAt.formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: " · ")
    }
}

/// The developing shot's tiles, live: the eye's words as they arrive, then the drawing coming up out of the
/// noise. Reads the same trace the Developer Tray reads (real data only). The drawing tile shows the newest
/// step, decoded with the small preview decoder at most every 1.5 s and one at a time, only while the Dark
/// Room is open; released when it closes.
private struct LiveTiles: View {
    let photo: UIImage?
    let showsWords: Bool
    let drawsThird: Bool
    let wordsCard: WordsCard
    @State private var words = ""
    @State private var step: UIImage?
    @State private var finished: UIImage?
    @State private var stepsDone = 0
    @State private var stepsPlanned = 0
    @State private var decoder = TrayPreviewDecoder()

    var body: some View {
        ShotTiles(photo: photo, showsWords: showsWords, showsDrawing: drawsThird, band: Safelight.band, glowing: true) {
            if words.isEmpty { Safelight.tileDark } else { WordsTile(text: words, developing: finished == nil, style: wordsCard, photo: photo) }
        } drawing: {
            ZStack {
                Safelight.tileDark
                if let finished {
                    Image(uiImage: finished).resizable().scaledToFill()
                } else if let step {
                    Image(uiImage: step).resizable().scaledToFill()
                    Safelight.red.opacity(0.22)
                }
                if finished == nil && stepsPlanned > 0 {
                    Text("\(stepsDone) of \(stepsPlanned)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.5), in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(5)
                }
            }
        }
        .task { await follow() }
        .onDisappear { Task { await decoder.release() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var s = words.isEmpty ? "Developing." : "The eye says: \(words)."
        if finished != nil { s += " The drawing is done." }
        else if stepsPlanned > 0 { s += " The hand has drawn \(stepsDone) of \(stepsPlanned) steps." }
        return s
    }

    private func follow() async {
        var lastVersion = -1
        var lastDecode = Date.distantPast
        while !Task.isCancelled {
            let v = DevelopTrace.shared.currentVersion()
            if v != lastVersion, let snap = DevelopTrace.shared.snapshot() {
                lastVersion = v
                if !snap.wordsFromEye {
                    words = ""   // the silent loop: no eye, so no words tile
                } else if let w = snap.eyeWords, !w.isEmpty {
                    words = w
                } else if let pieces = snap.eye?.pieces, !pieces.isEmpty {
                    words = pieces.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                }
                stepsPlanned = snap.steps
                stepsDone = snap.latents.count
                if let f = snap.final, finished == nil { finished = UIImage(cgImage: f) }
                // Only beside the Neural-Engine hand (the tray's rule): the MLX hand is using the GPU itself,
                // so its steps show once its drawing is done.
                if finished == nil, !snap.channelsLast, snap.steps > 0,
                   DarkRoomWorker.shared.currentStage == .drawing, let latest = snap.latents.last,
                   Date().timeIntervalSince(lastDecode) > 1.5 {
                    lastDecode = Date()
                    let decoder = self.decoder, shape = snap.shape
                    if let pic = await ModelLane.shared.runBeside({ await decoder.decode(latest, shape: shape, channelsLast: false) }) {
                        step = UIImage(cgImage: pic.image)
                    }
                }
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
    }
}

// MARK: - One developed shot

/// A developed shot whose negative is kept: its photo, words and drawing (as many as the shot made), when
/// it was taken and by which eye and hand, and Watch, which opens it in the Developer Tray.
private struct NegativeRow: View {
    let negative: NegativeMeta
    let photo: UIImage?
    let drawing: UIImage?
    let onWatch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ShotTiles(photo: photo, showsWords: hasWords, showsDrawing: negative.hasDrawing,
                      band: Safelight.bandDeveloped, glowing: false) {
                WordsTile(text: negative.eyeWords ?? "", developing: false,
                          style: negative.wordsCard ?? .whiteOnBlack, photo: photo)
            } drawing: {
                if let drawing { Image(uiImage: drawing).resizable().scaledToFill() } else { Safelight.empty }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(hasWords ? "The eye said: \(negative.firstWords)" : "A developed shot")
            HStack {
                Text(caption).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 8)
                Button("Watch", action: onWatch)
                    .font(.subheadline.weight(.bold))
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
                    .buttonStyle(.plain)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var hasWords: Bool {
        negative.wordsFromEye && !(negative.eyeWords ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var caption: String {
        var parts = [negative.capturedAt.formatted(date: .abbreviated, time: .shortened)]
        let makers = [negative.eyeName, negative.hasDrawing ? negative.hand : nil].compactMap { $0 }.filter { !$0.isEmpty }
        if !makers.isEmpty { parts.append(makers.joined(separator: " + ")) }
        return parts.joined(separator: " · ")
    }
}

/// A shot to watch in the Developer Tray (`navigationDestination(item:)` needs Identifiable + Hashable).
private struct WatchTarget: Identifiable, Hashable { let id: UUID; var followsQueue = false }

// ==== LEGO END: 35 The Dark Room Screen (The Developing Queue) ====
