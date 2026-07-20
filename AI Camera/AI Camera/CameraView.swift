//
//  CameraView.swift
//  AI Camera
//
//  The capture screen. Viewfinder, shutter. That is the whole app.
//
//  ⚠️ THIS SCREEN IS SACRED AND DUMB (CLAUDE.md, "The Shape of the App"). A viewfinder
//  and a shutter and nothing else, ever. No prompt field, no model picker, no settings,
//  no results. An SLR in AUTO: everything hectic lives behind Preferences.
//
//  You do not see the outcome here. Press the shutter, keep shooting; the developed
//  frame surfaces in Photos like a print in a chemical bath. On-device inference takes
//  real seconds, and rather than hide that latency — **the latency is the film
//  developing.**
//
//  The shot is atomic: you never prompt per-shot. The interpretation was loaded before
//  you raised the camera, and is out of your hands at the decisive moment. That absence
//  of control is what makes this a camera and not an image editor. Protect it.
//

import AVFoundation
import ImageIO
import Photos
import PhotosUI
import SwiftUI
import UIKit

// ==== LEGO START: 20 Viewfinder ====

/// The live preview. A thin wrapper over AVFoundation's preview layer — SwiftUI has no
/// native equivalent, so this is the one place UIKit shows through.
struct Viewfinder: UIViewRepresentable {
    let lens: Lens

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.layer.session = lens.session
        view.layer.videoGravity = .resizeAspectFill
        // The coordinator needs the layer to compute a preview angle at all — with no
        // layer it reports 0 forever, which is exactly the sideways bug.
        lens.attach(previewLayer: view.layer)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        override var layer: AVCaptureVideoPreviewLayer {
            super.layer as! AVCaptureVideoPreviewLayer
        }
    }
}

// ==== LEGO END: 20 Viewfinder ====

// ==== LEGO START: 21 CameraView (The Sacred Screen) ====

struct CameraView: View {

    @State private var lens = Lens()
    @State private var place = Place()
    @State private var pickerItem: PhotosPickerItem?
    @State private var showPicker = false

    /// The dark room queue's worker. The shutter no longer develops inline — it enqueues and
    /// returns instantly, and this develops in the background, surviving crash/background/call.
    /// Observed here only so the toast and the Photos-glyph pulse can read the queue's depth and
    /// completions; the capture screen knows nothing else about how it works.
    @State private var worker = DarkRoomWorker.shared

    /// What the camera is loaded with. Read at the moment of the press and not before —
    /// but chosen in Preferences, never here. The capture screen stays sacred.
    @State private var settings = Settings.shared
    @State private var showingPreferences = false
    /// The zoom at the instant the pinch began. A gesture reports magnification relative
    /// to its own start, so without an anchor each update would compound the last.
    @State private var zoomAnchor: CGFloat?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if lens.isAuthorized {
                Viewfinder(lens: lens)
                    .ignoresSafeArea()
                    // The square framing guide, only for the square-format layouts (Triptych,
                    // Separate — square). It shows the centred square the shot will be cropped
                    // to, so you frame for it — see `squareGuide`.
                    .overlay { squareGuide }
                    // Pinch to zoom, like every camera. The lens swap is the system's
                    // job, not ours — see `configure()`.
                    .gesture(
                        MagnifyGesture()
                            .onChanged { value in
                                if zoomAnchor == nil { zoomAnchor = lens.zoom }
                                lens.zoom(by: value.magnification, from: zoomAnchor ?? 1)
                            }
                            .onEnded { _ in zoomAnchor = nil }
                    )
            } else {
                Text("The camera needs permission to see.")
                    .foregroundStyle(.white.opacity(0.7))
            }

            // One glyph in each corner (Mark, 2026-07-16), the shutter alone at bottom-centre.
            // Top: Preferences (left), flip (right), the developing toast between them. Bottom:
            // upload a picture to feed IN (left), view what came OUT in Photos (right).
            VStack {
                HStack(alignment: .top) {
                    preferencesButton
                    Spacer()
                    developingIndicator
                    Spacer()
                    flipButton
                }
                Spacer()
                zoomReadout
                HStack(alignment: .bottom) {
                    uploadButton
                    Spacer()
                    shutterButton
                    Spacer()
                    photosButton
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .task {
            await lens.start()
            place.start()
        }
        .onDisappear { lens.stop(); place.stop() }
        .onChange(of: pickerItem) { _, item in
            Task { await shootFromLibrary(item) }
        }
        .statusBarHidden()
        .sheet(isPresented: $showingPreferences) { PreferencesView() }
    }

    // MARK: - The shutter

    /// The shutter. Centred, alone, unlabelled — you already know what it does.
    private var shutterButton: some View {
        Button {
            Task { await shoot() }
        } label: {
            ZStack {
                Circle().stroke(.white, lineWidth: 4).frame(width: 74, height: 74)
                Circle().fill(.white).frame(width: 62, height: 62)
            }
        }
        .buttonStyle(.plain)
        .disabled(!lens.isAuthorized)
    }

    /// The four corner glyphs — small, quiet, one to a corner. They lose every fight with the
    /// shutter; they are doors out of the sacred screen, not part of it. Shared style so they
    /// read as one family.
    private func cornerGlyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.title3)
            .foregroundStyle(.white.opacity(0.65))
            .frame(width: 44, height: 44)
    }

    private var preferencesButton: some View {
        Button { showingPreferences = true } label: { cornerGlyph("slider.horizontal.3") }
    }

    /// Selfie flip — the standard camera-flip loop. ⚠️ Front-camera mirroring is a device-tuning
    /// question (see `Lens.flip`).
    private var flipButton: some View {
        Button { lens.flip() } label: { cornerGlyph("arrow.triangle.2.circlepath.camera") }
    }

    /// Feed a picture IN — the library as an input door. A single photo-on-rectangle, distinct
    /// from the output glyph opposite it.
    private var uploadButton: some View {
        PhotosPicker(selection: $pickerItem, matching: .images) {
            cornerGlyph("photo.on.rectangle")
        }
    }

    /// See what came OUT — opens the Photos app to the shots you've developed. A *stack* of
    /// photos, deliberately different from the single-photo input glyph. It pulses when a shot
    /// lands (`worker.arrivals`), so you learn there's something new to see.
    private var photosButton: some View {
        Button { openPhotos() } label: {
            Image(systemName: "photo.stack")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.65))
                .frame(width: 44, height: 44)
                .symbolEffect(.bounce, value: worker.arrivals)
        }
    }

    /// Open the system Photos app. There is no official API for this; `photos-redirect://` is the
    /// long-standing way apps do it, and it's Mark's explicit call — the shots live in the user's
    /// own Photos, not in an in-app gallery that holds their pictures hostage.
    /// (App Review note: this is an undocumented scheme; widely used, but worth watching at
    /// submission.)
    private func openPhotos() {
        if let url = URL(string: "photos-redirect://") {
            UIApplication.shared.open(url)
        }
    }

    /// The square framing guide — shown only for the square-format layouts (Triptych,
    /// Separate — square), where the photograph is centre-cropped to a square to match the
    /// drawer's shape. It dims everything outside the centred square and outlines it, so you
    /// compose *for the square the crop keeps* rather than being surprised by it later.
    ///
    /// ⚠️ This is a *framing* guide, not a pixel-exact crop preview: the preview layer fills the
    /// screen (`aspectFill`), so the on-screen square and the sensor's centre square line up
    /// closely but not perfectly. `Darkroom.centerCropSquare` takes the sensor's true centre.
    /// Alignment is worth a device check once the phone's free.
    @ViewBuilder
    private var squareGuide: some View {
        if settings.layout.isSquareFormat {
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height)
                let square = CGRect(x: (geo.size.width - side) / 2,
                                    y: (geo.size.height - side) / 2,
                                    width: side, height: side)
                ZStack {
                    // Dim outside the square (even-odd: the whole area minus the square).
                    Path { p in
                        p.addRect(CGRect(origin: .zero, size: geo.size))
                        p.addRect(square)
                    }
                    .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                    // Outline the square itself, quietly.
                    Path { p in p.addRect(square) }
                        .stroke(Color.white.opacity(0.55), lineWidth: 1)
                }
            }
            .allowsHitTesting(false)
            .ignoresSafeArea()
        }
    }

    /// The zoom factor, said plainly. Principle 2: a real number, not five dots.
    /// Only while it's changing — the capture screen owes you nothing at rest.
    @ViewBuilder
    private var zoomReadout: some View {
        if zoomAnchor != nil {
            Text(String(format: "%.1f×", lens.zoom))
                .font(.footnote.monospacedDigit().weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.black.opacity(0.35), in: Capsule())
                .padding(.bottom, 14)
        }
    }

    /// The only feedback the capture screen gives: how many frames are still in the bath.
    /// Not a result, not a preview — just the fact that the camera is busy behind you.
    @ViewBuilder
    private var developingIndicator: some View {
        if worker.developingCount > 0 {
            HStack(spacing: 7) {
                ProgressView().tint(.white).scaleEffect(0.7)
                Text(worker.developingCount == 1 ? "Developing" : "Developing \(worker.developingCount)")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.black.opacity(0.35), in: Capsule())
        }
    }

    // MARK: - Pressing it

    private func shoot() async {
        guard let photograph = await lens.capture() else { return }
        await develop(photograph)
    }

    private func shootFromLibrary(_ item: PhotosPickerItem?) async {
        guard let item,
              let data = try? await item.loadTransferable(type: Data.self),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
        // The library's other door — same rule: upright before it goes anywhere.
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let raw = props?[kCGImagePropertyOrientation] as? UInt32 ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: raw) ?? .up
        await develop(cg.uprighted(orientation))
    }

    /// The shutter's whole job now: **freeze this shot and hand it to the dark room queue.**
    ///
    /// Reality → perception → re-imagining → Photos still happens — but it happens in the
    /// worker (`DarkRoomWorker`), not here. This function only captures the reality frame to
    /// durable disk, along with a frozen copy of every setting that shapes the result, then
    /// returns instantly. That is the whole point:
    ///
    /// ⭐ THE INVARIANT (Mark, 2026-07-19): *once the shutter fires, nothing you shot is lost
    /// until it is safely in Photos.* The moment `enqueue` returns, the shot survives a crash, a
    /// background, a phone call, a thermal backoff, a memory kill — because it is on disk, and
    /// the worker re-develops anything it finds there. A shot's only exit is a successful save.
    ///
    /// The old inline pipeline (see → draw → composite → save, all through `ModelLane`) moved
    /// wholesale into the worker; the serialization and never-two-heavy-ops-at-once guarantee it
    /// gave are unchanged, because the worker runs through the very same lane.
    private func develop(_ photograph: CGImage) async {
        let config = ShotConfig.capture()

        // Encode the reality frame losslessly (PNG) and freeze the shot to disk together with its
        // config and its capture context — the place and (via the record) the moment it was taken,
        // so its footer testifies to reality even if it develops hours later.
        guard let photoData = ShotPhoto.encode(photograph) else {
            cameraLog("SHUTTER: could not encode the captured frame — shot dropped")
            return
        }
        do {
            _ = try await DarkRoomStore.shared.enqueue(photoData: photoData,
                                                       config: config,
                                                       place: place.name)
        } catch {
            cameraLog("SHUTTER: could not enqueue the shot — \(error.localizedDescription)")
            return
        }

        // Wake the worker. Idempotent: if it's already developing, this does nothing and the shot
        // we just wrote is picked up in FIFO order.
        worker.kick()
    }
}

// ==== LEGO END: 21 CameraView (The Sacred Screen) ====

// ==== LEGO START: 22 Seer (Which Eye Is Loaded) ====

/// Which machine is doing the seeing.
///
/// A camera has one film in it at a time. This is that — chosen before you raise the
/// camera, then out of your hands. The two eyes are genuinely different animals: Apple's
/// is obedient but nearly blind and has a filter that stops images at the door; Qwen sees
/// far more, has no filter at all, and largely ignores the system prompt. Preferences
/// will let you load either. Neither is "better" — that's not ours to say (Principle 3).
nonisolated enum Seer: String, CaseIterable, Hashable, Sendable {
    case apple
    case qwen

    var name: String {
        switch self {
        case .apple: return "Apple Intelligence"
        case .qwen:  return "Qwen3.5-2B"
        }
    }

    /// Whether this eye can be loaded right now.
    var isAvailable: Bool {
        switch self {
        case .apple: return Readiness.current.isReady
        case .qwen:  return QwenLoader.isAvailable
        }
    }

    /// The image is already upright — see `uprighted`. No orientation to pass.
    ///
    /// The prompt and temperature come from Settings, so both eyes are handed exactly the
    /// same instructions — the only variable is the machine.
    @MainActor
    func look(at image: CGImage, systemPrompt: String, temperature: Double) async -> Perception {
        switch self {
        case .apple:
            // Retry-on-block: the filter never saw the picture, so there's no perception
            // to respect — only a bouncer to get past. See `lookWithRetry`.
            var eye = Eye.plain
            eye.systemPrompt = systemPrompt
            eye.temperature = temperature
            return await eye.lookWithRetry(at: image).best
        case .qwen:
            // No retry: there is no filter to get past.
            return await Qwen(systemPrompt: systemPrompt, temperature: temperature).look(at: image)
        }
    }

    /// The same eye that saw, restating its words in fewer of them — dispatched to whichever
    /// eye is loaded (purity of the chain: Mark, 2026-07-16, *"model who sees is the same model
    /// who condenses"*). Its own compression instruction, so the user's Layer 2 doesn't apply
    /// here. Returns nil on failure; `Shot` then hands the full words on under the hard cap.
    @MainActor
    func condense(_ text: String, toAtMostWords maxWords: Int, systemPrompt: String, temperature: Double) async -> String? {
        switch self {
        case .apple:
            var eye = Eye.plain
            eye.systemPrompt = systemPrompt
            eye.temperature = temperature
            return await eye.condense(text, toAtMostWords: maxWords)
        case .qwen:
            return await Qwen(systemPrompt: systemPrompt, temperature: temperature).condense(text, toAtMostWords: maxWords)
        }
    }
}

// ==== LEGO END: 22 Seer (Which Eye Is Loaded) ====
