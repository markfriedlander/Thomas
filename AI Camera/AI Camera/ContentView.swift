//
//  ContentView.swift
//  AI Camera
//
//  The steel thread: an image goes in, the machine's perception comes out.
//
//  This is NOT the camera. There is no viewfinder and no shutter here yet — this
//  screen exists only to prove the machine sees, and to let us characterize HOW it
//  sees before we build anything around it. It is scaffolding, and it is meant to be
//  thrown away.
//

import SwiftUI
import PhotosUI
import ImageIO

// ==== LEGO START: 6 ContentView (Steel-Thread Scaffolding) ====
struct ContentView: View {

    @State private var pickerItem: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var perception: Perception?
    @State private var looking = false
    @State private var elapsed: TimeInterval?
    @State private var price: Int?
    /// The form letter, when the filter stopped a shot that the machine later described.
    /// Kept beside the rescue rather than replaced by it — both are true.
    @State private var blockedFirst: Perception?

    #if DEBUG
    @State private var apiRunning = false
    @State private var apiInfo: String?
    #endif

    private let eye = Eye.plain
    private let readiness = Readiness.current

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {

                    if !readiness.isReady {
                        Text(readiness.explanation)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label(image == nil ? "Choose a photograph" : "Choose another",
                              systemImage: "photo.on.rectangle.angled")
                    }
                    .buttonStyle(.borderedProminent)

                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 320)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    if looking {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Looking…").foregroundStyle(.secondary)
                        }
                    }

                    if let blockedFirst {
                        PerceptionView(perception: blockedFirst)
                    }

                    if let perception {
                        PerceptionView(perception: perception)
                    }

                    if let elapsed {
                        // Transparency, not decoration: what the look cost, in time and
                        // in tokens. Principle 2 — say the real numbers.
                        Text(costLine(elapsed: elapsed))
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Spacer(minLength: 0)
                }
                .padding()
            }
            .navigationTitle("AI Camera")
            .navigationBarTitleDisplayMode(.inline)
            #if DEBUG
            .toolbar { ToolbarItem(placement: .topBarTrailing) { antennaToggle } }
            .safeAreaInset(edge: .bottom) { antennaBanner }
            #endif
        }
        .onChange(of: pickerItem) { _, item in
            Task { await load(item) }
        }
        #if DEBUG
        .onAppear { autoStartAntenna() }
        #endif
    }

    #if DEBUG
    /// DEBUG builds bring the antenna up at launch so CC's tooling works on every fresh
    /// install without Mark tapping anything.
    ///
    /// This is **Posey's** pattern (LibraryView.swift ~411), deliberately, and NOT Hal's.
    /// Hal gates the same behavior on a runtime bool (`kLocalAPIEnabledOnLaunch`) that a
    /// human must remember to flip to false before an App Store archive — a SHIP_BLOCKER
    /// comment plus a ⚠️ in NEXT.md doing the work that the compiler should be doing.
    /// That is exactly the constraint-in-behavior trap Principle 7 exists to kill.
    ///
    /// Here, safety is structural: `LocalAPIServer` is inside `#if DEBUG`, so a Release
    /// binary contains no server to start, no token to leak, and no port to bind. There
    /// is nothing to remember, so there is nothing to forget.
    private func autoStartAntenna() {
        guard !LocalAPIServer.shared.isRunning else { return }
        LocalAPIServer.shared.start()
        apiRunning = LocalAPIServer.shared.isRunning
        apiInfo = LocalAPIServer.shared.connectionInfo
    }

    /// The antenna toggle — still here so it can be turned OFF. DEBUG-only in every
    /// sense: the server itself doesn't exist in Release builds, so neither does this.
    private var antennaToggle: some View {
        Button {
            if apiRunning {
                LocalAPIServer.shared.stop()
                apiRunning = false
            } else {
                LocalAPIServer.shared.start()
                apiRunning = LocalAPIServer.shared.isRunning
                apiInfo = LocalAPIServer.shared.connectionInfo
            }
        } label: {
            Image(systemName: apiRunning ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
        }
        .tint(apiRunning ? .green : .secondary)
    }

    @ViewBuilder
    private var antennaBanner: some View {
        if apiRunning, let apiInfo {
            Text(apiInfo)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial)
        }
    }
    #endif

    private func costLine(elapsed: TimeInterval) -> String {
        var parts = [String(format: "%.1fs", elapsed)]
        if let price { parts.append("\(price) tokens to look") }
        if case .spoke(_, let tokens) = perception, let tokens {
            parts.append("\(tokens) tokens total")
        }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: - Pointing the machine at something

    private func load(_ item: PhotosPickerItem?) async {
        guard let item else { return }

        perception = nil
        blockedFirst = nil
        elapsed = nil
        price = nil

        guard let data = try? await item.loadTransferable(type: Data.self),
              let uiImage = UIImage(data: data) else {
            perception = .broke(reason: "Couldn't read that image.")
            return
        }

        image = uiImage

        // ⚠️ There is no UIImage initializer on Attachment — CGImage, CIImage,
        // CVPixelBuffer, or a file URL only. And the orientation must come along
        // separately or the machine sees the world sideways. See Seeing.swift.
        guard let cgImage = uiImage.cgImage else {
            perception = .broke(reason: "That image has no CGImage backing.")
            return
        }
        // Same rule as the shutter: upright at the door, then nobody downstream
        // carries an orientation. See `uprighted` in Camera.swift.
        let photograph = cgImage.uprighted(uiImage.cgOrientation)

        looking = true
        price = await eye.priceOfLooking(at: photograph)
        // Timed around the look alone. The earlier version wrapped the pre-flight
        // tokenCount too and reported ~5s for what is really a ~2s look.
        let started = Date()
        let result = await eye.lookWithRetry(at: photograph)
        elapsed = Date().timeIntervalSince(started)
        looking = false
        perception = result.best
        blockedFirst = result.wasRescued ? result.first : nil
    }
}

// ==== LEGO END: 6 ContentView (Steel-Thread Scaffolding) ====

// ==== LEGO START: 7 PerceptionView (Showing What The Machine Did) ====

/// Every case gets shown. Note there is no "error" styling on `refused` or `blocked`:
/// they are things the machine did, and per Principle 3 they are content. A refusal is
/// arguably the most honest artifact this app can produce — it does not get buried in
/// a red banner.
private struct PerceptionView: View {
    let perception: Perception

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.tertiary)

            Text(body_)
                .font(.title3)
                .fontDesign(.serif)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var label: String {
        switch perception {
        case .spoke:    return "What the machine sees"
        case .refused:  return "The machine declined"
        case .blocked:  return "A filter stopped this before the machine saw it"
        case .broke:    return "Broken"
        }
    }

    private var body_: String {
        switch perception {
        case .spoke(let text, _):       return text
        case .refused(let explanation): return explanation
        case .blocked(let explanation, _): return explanation
        case .broke(let reason):        return reason
        }
    }
}

// ==== LEGO END: 7 PerceptionView (Showing What The Machine Did) ====

// ==== LEGO START: 8 The Orientation Trap ====

extension UIImage {
    /// `UIImage` and `CGImage` disagree about which way is up, and `Attachment` wants
    /// the `CGImage` convention. Getting this wrong doesn't crash — it just makes the
    /// machine describe a world that's lying on its side.
    var cgOrientation: CGImagePropertyOrientation {
        switch imageOrientation {
        case .up:             return .up
        case .down:           return .down
        case .left:           return .left
        case .right:          return .right
        case .upMirrored:     return .upMirrored
        case .downMirrored:   return .downMirrored
        case .leftMirrored:   return .leftMirrored
        case .rightMirrored:  return .rightMirrored
        @unknown default:     return .up
        }
    }
}

#Preview {
    ContentView()
}
// ==== LEGO END: 8 The Orientation Trap ====
