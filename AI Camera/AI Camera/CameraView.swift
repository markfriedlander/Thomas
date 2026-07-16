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
    @State private var developing = 0
    @State private var lastFrame: UIImage?
    @State private var pickerItem: PhotosPickerItem?
    @State private var showPicker = false

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

            VStack {
                developingIndicator
                Spacer()
                zoomReadout
                shutterRow
            }
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

    private var shutterRow: some View {
        ZStack {
            // The shutter. Centred, alone, unlabelled — you already know what it does.
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

            // Preferences and the picker: deliberately small, pushed to the edges, both
            // losing every fight with the shutter. This screen is a viewfinder and a
            // button; these are doors out of it, not part of it.
            HStack {
                Button { showingPreferences = true } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.65))
                        .frame(width: 44, height: 44)
                }
                .padding(.leading, 28)

                Spacer()

                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.65))
                        .frame(width: 44, height: 44)
                }
                .padding(.trailing, 28)
            }
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
        if developing > 0 {
            HStack(spacing: 7) {
                ProgressView().tint(.white).scaleEffect(0.7)
                Text(developing == 1 ? "Developing" : "Developing \(developing)")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.black.opacity(0.35), in: Capsule())
            .padding(.top, 12)
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

    /// Reality -> perception -> re-imagining -> Photos.
    ///
    /// **All three frames, in one press.** This is the whole thesis of the app, and until
    /// 2026-07-16 two thirds of it were a document.
    ///
    /// Deliberately NOT blocking the shutter: press it again while this runs and you get a
    /// second frame in the bath. Serialization is `ModelLane`'s job, not the user's problem —
    /// they should be shooting, not waiting — and it is what keeps two shots' models from
    /// running at once and jetsamming the app.
    private func develop(_ photograph: CGImage) async {
        developing += 1
        defer { developing -= 1 }

        // The whole heavy pipeline of one shot — frame 2 (see) then frame 3 (draw) — runs in
        // the ModelLane: **one shot at a time across the entire app, each torn down and the
        // phone let to settle before the next.**
        //
        // ⭐ Mark's rule, 2026-07-16: *"we should be drawing one at a time in sequence...
        // one operation has its own world and all its resources from scratch."* The shutter
        // is fire-and-forget by design (press again, keep shooting), which is exactly what
        // crashed it: a second press ran a second 2.7 GB draw on top of the first and iOS
        // jetsammed the app (measured, signal 9). Now a second press just queues another shot
        // behind this one. The lane returns only Sendable values; the cheap work — the
        // compositor and the save — stays out here on the main actor.
        // Frame 2 (see) then frame 3 (draw) — the shared pipeline, so the antenna's /shoot
        // measures exactly this. See `Shot`.
        let seer = settings.seer
        let drawThird = settings.drawsThirdFrame
        let result: (perception: Perception, drawn: UIImage?) =
            await ModelLane.shared.run("shot") { @MainActor in
                await Shot.seeThenDraw(photograph, seer: seer, drawThird: drawThird)
            }

        // A shot yields one frame — or two, for "Separate images". Still one press.
        var frames = Darkroom.develop(photograph: photograph,
                                      words: result.perception.wireText,
                                      place: place.name,
                                      layout: settings.layout)
        if let drawn = result.drawn {
            frames.append(drawn)
        }

        lastFrame = frames.last
        await Shot.save(frames)
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
enum Seer: String, CaseIterable, Hashable, Sendable {
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
    func look(at image: CGImage) async -> Perception {
        switch self {
        case .apple:
            // Retry-on-block: the filter never saw the picture, so there's no perception
            // to respect — only a bouncer to get past. See `lookWithRetry`.
            let eye = Settings.shared.eye
            return await eye.lookWithRetry(at: image).best
        case .qwen:
            // No retry: there is no filter to get past.
            let qwen = Settings.shared.qwen
            return await qwen.look(at: image)
        }
    }
}

// ==== LEGO END: 22 Seer (Which Eye Is Loaded) ====
