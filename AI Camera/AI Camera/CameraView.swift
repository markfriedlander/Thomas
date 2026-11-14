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
import Photos
import SwiftUI
import UIKit

// ==== LEGO START: 17 Viewfinder ====

/// The live preview. A thin wrapper over AVFoundation's preview layer — SwiftUI has no
/// native equivalent, so this is the one place UIKit shows through.
struct Viewfinder: UIViewRepresentable {
    let lens: Lens

    func makeUIView(context: Context) -> ViewfinderView {
        let view = ViewfinderView()
        // Hand the layers their session just AFTER this view update, never inside it. On a Mac,
        // setting `session` starts the capture graph synchronously and AVFoundation spins the run
        // loop while it waits; events handled during that spin re-entered SwiftUI's view update
        // until AttributeGraph aborted (Thomas 1.0 crash on launch, MacBook Air M2, 2026-11-06).
        // An iPhone doesn't block there, but the deferred hand-off is just as correct for it.
        DispatchQueue.main.async {
            view.picture.layer.session = lens.session
            // The coordinator needs the layer to compute a preview angle at all — with no
            // layer it reports 0 forever, which is exactly the sideways bug.
            lens.attach(previewLayer: view.picture.layer)
        }
        return view
    }

    func updateUIView(_ uiView: ViewfinderView, context: Context) {}

    /// The viewfinder: the camera's WHOLE picture, fitted, so everything captured is visible (Mark's
    /// rule, 2026-11-13: a full-screen preview hid up to 46% of every photo off the edges). Where the
    /// screen is another shape the bands are plain black (Mark: "if we're just gonna have a backdrop, it
    /// should be black"). A live blur of the scene was tried: a second preview layer on the same session
    /// got no frames on a Mac, and blurring the camera's own frames wasn't worth the cost (Mark: "It's
    /// not worth half an hour").
    final class ViewfinderView: UIView {
        let picture = PreviewView()

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .black
            picture.layer.videoGravity = .resizeAspect
            picture.backgroundColor = .clear
            picture.frame = bounds
            picture.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(picture)
        }
        required init?(coder: NSCoder) { fatalError("Viewfinder is made in code") }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        override var layer: AVCaptureVideoPreviewLayer {
            super.layer as! AVCaptureVideoPreviewLayer
        }
    }
}

// ==== LEGO END: 17 Viewfinder ====

// ==== LEGO START: 18 CameraView (The Sacred Screen) ====

struct CameraView: View {

    @State private var lens = Lens()
    @State private var place = Place()

    /// The dark room queue's worker. The shutter no longer develops inline — it enqueues and
    /// returns instantly, and this develops in the background, surviving crash/background/call.
    /// Observed here only so the toast and the Photos-glyph pulse can read the queue's depth and
    /// completions; the capture screen knows nothing else about how it works.
    @State private var worker = DarkRoomWorker.shared

    /// What the camera is loaded with. Read at the moment of the press and not before —
    /// but chosen in Preferences, never here. The capture screen stays sacred.
    @State private var settings = Settings.shared
    @State private var showingPreferences = false
    /// The one Dark Room sheet: opened by the Dark Room button, the status pill and the antenna alike.
    @State private var showingDarkRoom = false
#if DEBUG
    /// Lets the antenna drive the Download → license → Accept flow: when it sets a model here, this
    /// screen presents that model's license sheet (see `AntennaUIBridge`). DEBUG-only: the bridge is
    /// antenna plumbing that does not exist in Release, so this @State and its sheets below are gated too.
    @State private var bridge = AntennaUIBridge.shared
#endif
    /// The zoom at the instant the pinch began. A gesture reports magnification relative
    /// to its own start, so without an anchor each update would compound the last.
    @State private var zoomAnchor: CGFloat?
    /// The one-finger touch on the viewfinder (Apple's Camera gestures): where it began, whether a
    /// pinch joined it, whether it became a press and hold, and the brightness when a drag began.
    @State private var touchStart: CGPoint?
    @State private var pinching = false
    @State private var held = false
    @State private var holdTask: Task<Void, Never>?
    @State private var biasAtDragStart: Float?
    /// The yellow square shows for a moment after a tap or a drag, and stays while locked.
    @State private var focusSquareVisible = false
    @State private var focusSquareFade: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if lens.isAuthorized {
                Viewfinder(lens: lens)
                    .ignoresSafeArea()
                    // The viewfinder's own points, edge to edge, which are the preview layer's points:
                    // a finger is measured here so the camera focuses exactly under it.
                    .coordinateSpace(.named(Self.viewfinderSpace))
#if DEBUG
                    // Screenshot still (see `AntennaUIBridge.viewfinderStill`). Under the square guide and
                    // all chrome, exactly where the live preview sits, so the screenshot is the real screen.
                    // GeometryReader + ignoresSafeArea so the still fills edge to edge; a bare Image
                    // here stopped short of the top edge and let the live sensor show through.
                    .overlay {
                        if let still = bridge.viewfinderStill {
                            GeometryReader { geo in
                                Image(uiImage: still).resizable().scaledToFit()
                                    .frame(width: geo.size.width, height: geo.size.height)
                                    .clipped()
                            }
                            .ignoresSafeArea()
                        }
                    }
#endif
                    // The square framing guide, only for the square-format layouts (Triptych,
                    // Separate — square). It shows the centred square the shot will be cropped
                    // to, so you frame for it — see `squareGuide`.
                    .overlay { squareGuide }
                    .overlay { focusSquare }
                    // Pinch to zoom, like every camera. The lens swap is the system's
                    // job, not ours — see `configure()`.
                    .gesture(
                        MagnifyGesture()
                            .onChanged { value in
                                pinching = true
                                holdTask?.cancel()
                                if zoomAnchor == nil { zoomAnchor = lens.zoom }
                                lens.zoom(by: value.magnification, from: zoomAnchor ?? 1)
                            }
                            .onEnded { _ in zoomAnchor = nil }
                    )
                    // Tap to focus and expose there; press and hold to lock both; drag up or down
                    // while the square shows for brighter or darker. Apple's Camera gestures (Mark,
                    // 2026-11-13: "Tap to focus and drag for exposure would be awesome"). Gestures,
                    // not buttons: the capture screen stays viewfinder and shutter.
                    .simultaneousGesture(focusGesture)
                    .onChange(of: lens.focusPoint) { _, point in
                        if point != nil { showFocusSquare() } else { focusSquareVisible = false }
                    }
                    .onChange(of: lens.exposureBias) { _, _ in
                        if lens.focusPoint != nil { showFocusSquare() }
                    }
            } else {
                Text("The camera needs permission to see.")
                    .foregroundStyle(.white.opacity(0.7))
            }

            // The corners (Mark, 2026-07-20), the shutter alone at bottom-centre. Top: the status
            // panel (the annunciator) upper-LEFT, where the eye lands first; Preferences
            // upper-RIGHT (Mark's habit across his apps). Bottom: flip the lens lower-LEFT
            // (thumb-reachable from the shutter), view what came OUT in Photos lower-RIGHT.
            //
            // The "feed a picture IN" door is gone from here on purpose: it belongs on the coming
            // Dark Room screen, not the capture screen (its machinery stays intact below, just
            // unhooked from the UI). The developing/cooling toast is gone too: it moved into the
            // status panel as the "developing" and "thermal" messages.
            VStack {
                HStack(alignment: .top) {
                    StatusFeedView(onOpenPreferences: { showingPreferences = true },
                                   onOpenDarkRoom: { showingDarkRoom = true })
                    Spacer()
                    darkRoomButton
                    preferencesButton
                }
                Spacer()
                // Above the shutter, not at the top: the top row carries the status line.
                if lens.focusLocked { focusLockBanner }
                zoomReadout
                HStack(alignment: .bottom) {
                    flipButton
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
            // After an install or update, prepare the Core ML hand once the camera has settled, so
            // the wait is announced up front rather than met mid-shot (HandPreparation).
            Task { await HandPreparation.shared.prepareAfterLaunchIfNeeded() }
        }
        .onDisappear { lens.stop(); place.stop() }
        .statusBarHidden()
        .macResizablePresentation(isPresented: $showingPreferences) { PreferencesView() }
        .macResizablePresentation(isPresented: $showingDarkRoom) { DarkRoomView() }
#if DEBUG
        // Antenna-driven license sheet: the same `ModelLicenseSheet` the Model Library shows, presented
        // from the capture screen so the antenna can walk (and screenshot) the Download → license →
        // Accept flow. Accept takes the identical `startModelDownload` path the button's Accept takes.
        // DEBUG-only: driven solely by the DEBUG antenna via AntennaUIBridge; real users reach the
        // license sheet through the Model Library's own `$modelForLicense` path, so this ships in no build.
        .macResizablePresentation(item: $bridge.licenseModel) { model in
            ModelLicenseSheet(
                model: model,
                onAccept: { bridge.licenseModel = nil; startModelDownload(model) },
                onCancel: { bridge.licenseModel = nil }
            )
        }
        // Human-parity "open a screen": the antenna flips the SAME state a finger flips, never a
        // parallel presenter. The gear = `showingPreferences`. The Model Library lives INSIDE
        // Preferences, so that request opens Preferences and Preferences pushes the library itself
        // (see its `navigationDestination`). The dark-room pill lives on the status panel, so that
        // request is honored by `StatusFeedView`, not here.
        // Human-parity: the antenna's dark-room verb flips the same state the Dark Room button and the
        // status pill flip.
        .onChange(of: bridge.tapDarkRoom) { _, want in
            if want { showingDarkRoom = true; bridge.tapDarkRoom = false }
        }
        .onChange(of: bridge.tapPreferences) { _, want in
            if want { showingPreferences = true; bridge.tapPreferences = false }
        }
        .onChange(of: bridge.tapModelLibrary) { _, want in
            // Open Preferences; leave the flag set so Preferences pushes the library and clears it.
            if want { showingPreferences = true }
        }
        .onChange(of: bridge.tapAbout) { _, want in
            // Open Preferences; leave the flag set so Preferences pushes About and clears it.
            if want { showingPreferences = true }
        }
        // When Preferences closes for ANY reason (Done, or the antenna's return-to-capture), reset the
        // interior-push flags. Dismissing the sheet does NOT pop its nav stack, so the navigationDestination
        // isPresented bindings never clear on their own — a stuck `tapAbout`/`tapModelLibrary` would then
        // re-push the wrong screen the next time Preferences opens (device-found 2026-08-01).
        .onChange(of: showingPreferences) { _, isShowing in
            if !isShowing { bridge.tapModelLibrary = false; bridge.tapAbout = false }
        }
        // Human-parity "return to capture": dropping `showingPreferences` dismisses Preferences and any
        // Model Library pushed inside it, landing on the bare capture screen — exactly what tapping Done
        // does. `StatusFeedView` honors the same flag for the Dark Room. Cleared here (the always-present
        // root); the guarded `want` means the clear can't re-trigger either observer.
        .onChange(of: bridge.dismissToCapture) { _, want in
            if want { showingPreferences = false; showingDarkRoom = false; bridge.dismissToCapture = false }
        }
        // Human-parity: the antenna's photos verb taps the Photos glyph — the same `openPhotos()`.
        .onChange(of: bridge.tapPhotos) { _, want in
            if want { openPhotos(); bridge.tapPhotos = false }
        }
#endif
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
        // Unlabelled to the eye on purpose, but VoiceOver needs a name (it had none, 2026-11-13).
        .accessibilityLabel("Shutter")
    }

    /// The corner glyphs — quiet, one to a corner. They lose every fight with the shutter; they are
    /// doors out of the sacred screen, not part of it. Each wears `CaptureControlCircle` (defined by
    /// the status feed) so the three read as one family — a uniform disc, identical size regardless of
    /// glyph width. (The privacy lock deliberately stays a capsule; it belongs to the status stack.)
    private func cornerGlyph(_ name: String) -> some View {
        Image(systemName: name).modifier(CaptureControlCircle())
    }

    /// The door to the Dark Room, always there (Mark, 2026-11-13: "I keep finding myself wanting to go
    /// into the dark room when I'm on that screen"). Beside Preferences, between it and the status panel's
    /// lock, wearing the tray glyph Preferences uses for the same room. The status pill still opens it
    /// while something is developing; this door is there for every shot, including long-finished ones.
    private var darkRoomButton: some View {
        Button { showingDarkRoom = true } label: { cornerGlyph("tray.full") }
            .accessibilityLabel("Dark Room")
    }

    private var preferencesButton: some View {
        Button { showingPreferences = true } label: { cornerGlyph("slider.horizontal.3") }
            .accessibilityLabel("Preferences")   // the glyph's own name read "Edit"
    }

    /// Selfie flip — the standard camera-flip loop (its preview mirrors, its photo doesn't; see
    /// `Lens.applyMirroring`). Shown only when there is a second camera to flip to.
    ///
    /// (Tried and taken out, 2026-11-13: on a Mac this corner chose a wide or tall picture by switching
    /// the camera's format, and square layouts used the square format, which shows the most of the
    /// room. Switching formats shortly after launch left the preview black, though photos still came;
    /// the same switch triggered later by hand worked. Not understood yet; see NEXT.md.)
    private var flipButton: some View {
        Button { lens.flip() } label: { cornerGlyph("arrow.triangle.2.circlepath.camera") }
            // Only when there is a second camera (a Mac's built-in camera is the only one). Hidden by
            // opacity, not removed, so the shutter stays centred between the corners.
            .opacity(lens.canFlip ? 1 : 0)
            .disabled(!lens.canFlip)
            .accessibilityHidden(!lens.canFlip)
    }

    /// See what came OUT — opens the Photos app to the shots you've developed. A *stack* of
    /// photos, deliberately different from the single-photo input glyph. It pulses when a shot
    /// lands (`worker.arrivals`), so you learn there's something new to see.
    private var photosButton: some View {
        Button { openPhotos() } label: {
            Image(systemName: "photo.stack")
                .symbolEffect(.bounce, value: worker.arrivals)
                .modifier(CaptureControlCircle())
        }
        .accessibilityLabel("Photos")
    }

    /// Open the system Photos app. There is no official API for this; `photos-redirect://` is the
    /// long-standing way apps do it, and it's Mark's explicit call — the shots live in the user's
    /// own Photos, not in an in-app gallery that holds their pictures hostage.
    /// (App Review note: this is an undocumented scheme; widely used, but worth watching at
    /// submission.)
    private func openPhotos() {
        // On a Mac (this same app, "Designed for iPad") photos-redirect:// opens nothing; the Mac's
        // Photos app declares `photos` among its URL schemes (its Info.plist, checked 2026-11-13).
        let scheme = ProcessInfo.processInfo.isiOSAppOnMac ? "photos://" : "photos-redirect://"
        if let url = URL(string: scheme) {
            UIApplication.shared.open(url)
        }
    }

    /// The square framing guide — shown only for the square-format layouts (Triptych,
    /// Separate — square), where the photograph is centre-cropped to a square to match the
    /// drawer's shape. It dims everything outside the centred square and outlines it, so you
    /// compose *for the square the crop keeps* rather than being surprised by it later.
    ///
    /// Exact since 2026-11-13: the preview shows the whole picture (aspect-fit), and the square is
    /// drawn inside that picture, so it is the very centre square `Darkroom.centerCropSquare` keeps.
    /// (Before, the preview filled the screen and the guide only approximated the crop.)
    @ViewBuilder
    private var squareGuide: some View {
        // The picture on screen: the camera's whole frame, fitted (aspect-fit, like the preview layer).
        // For the square layouts the part outside the saved square is dimmed INSIDE the picture, so
        // the clear square is exactly the photo's centre square that Darkroom.centerCropSquare keeps
        // (Mark, 2026-11-13: you must always know exactly what is captured).
        if settings.layout.isSquareFormat {
            GeometryReader { geo in
                let picture = AVMakeRect(aspectRatio: CGSize(width: lens.pictureAspect, height: 1),
                                         insideRect: CGRect(origin: .zero, size: geo.size))
                let side = min(picture.width, picture.height)
                let square = CGRect(x: picture.midX - side / 2, y: picture.midY - side / 2,
                                    width: side, height: side)
                ZStack {
                    // Dim the picture outside the square (even-odd: the picture minus the square).
                    Path { p in
                        p.addRect(picture)
                        p.addRect(square)
                    }
                    .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                    // Outline the square itself, quietly, drawn just INSIDE its edge. Centred on the edge,
                    // half the line fell outside the content: on a Mac (wider than tall, so the square runs
                    // the full height) that half sat in the title bar's strip and showed as a stray line
                    // above every full-window screen (Mark spotted it, 2026-11-13).
                    Path { p in p.addRect(square.insetBy(dx: 0.5, dy: 0.5)) }
                        .stroke(Color.white.opacity(0.55), lineWidth: 1)
                }
            }
            .allowsHitTesting(false)
            .ignoresSafeArea()
        }
    }

    /// The zoom factor, said plainly. Principle 2: a real number, not five dots.
    /// Only while it's changing — the capture screen owes you nothing at rest.
    /// One finger on the viewfinder: a tap, a press and hold, or (while the square shows) a drag
    /// for brightness. A pinch's fingers also arrive here; any touch a pinch joined does nothing.
    private var focusGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.viewfinderSpace))
            .onChanged { value in
                if touchStart == nil {
                    touchStart = value.startLocation
                    held = false
                    let start = value.startLocation
                    holdTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(600))
                        guard !Task.isCancelled, !pinching else { return }
                        held = true
                        lens.focus(atScreenPoint: start, lock: true)
                    }
                }
                let t = value.translation
                if hypot(t.width, t.height) > 10 { holdTask?.cancel() }
                guard !pinching else { return }
                // Brightness: a mostly vertical drag while the square is up. Up is brighter.
                if focusSquareVisible, lens.focusPoint != nil, abs(t.height) > 10, abs(t.height) > abs(t.width) {
                    if biasAtDragStart == nil { biasAtDragStart = lens.exposureBias }
                    lens.setExposureBias((biasAtDragStart ?? 0) - Float(t.height) / 120)
                }
            }
            .onEnded { value in
                holdTask?.cancel()
                let t = value.translation
                if !pinching, !held, biasAtDragStart == nil, hypot(t.width, t.height) <= 10 {
                    lens.focus(atScreenPoint: value.startLocation, lock: false)
                }
                touchStart = nil
                biasAtDragStart = nil
                pinching = false
            }
    }

    /// Show the square, and let it go after a moment unless focus is locked.
    private func showFocusSquare() {
        focusSquareVisible = true
        focusSquareFade?.cancel()
        focusSquareFade = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, !lens.focusLocked else { return }
            withAnimation(.easeOut(duration: 0.4)) { focusSquareVisible = false }
        }
    }

    static let viewfinderSpace = "viewfinder"

    /// Apple's yellow square where you tapped, with the sun beside it riding up and down with the
    /// brightness when this camera can change it. Drawn in an edge-to-edge frame, like the square
    /// guide: inside the safe area it landed ~58 points off on a landscape iPhone (measured
    /// 2026-11-13, the Dynamic Island side's inset).
    @ViewBuilder
    private var focusSquare: some View {
        if let p = lens.focusPoint, focusSquareVisible {
            GeometryReader { _ in focusSquareMark.position(p) }
                .allowsHitTesting(false)
                .ignoresSafeArea()
                .accessibilityHidden(true)
        }
    }

    private var focusSquareMark: some View {
        ZStack {
            Rectangle()
                .stroke(Color.yellow, lineWidth: 1.5)
                .frame(width: 76, height: 76)
            if lens.canAdjustExposure {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.yellow)
                    .offset(x: 54, y: CGFloat(-lens.exposureBias) * 18)
            }
        }
    }

    /// Apple's banner for a press and hold. The next tap clears it.
    private var focusLockBanner: some View {
        Text("AE/AF LOCK")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.yellow, in: RoundedRectangle(cornerRadius: 4))
            .padding(.bottom, 10)
            .accessibilityLabel("Focus and exposure locked")
    }

    /// Apple's way of writing a zoom: "1x", "2x", "0.5x", "2.4x" (a whole number has no
    /// decimal). The number is already in Apple's scale (`Lens.displayZoom`).
    static func appleZoomLabel(_ z: CGFloat) -> String {
        let tenths = (z * 10).rounded() / 10
        return tenths == tenths.rounded() ? String(format: "%.0f×", tenths) : String(format: "%.1f×", tenths)
    }

    @ViewBuilder
    private var zoomReadout: some View {
        if zoomAnchor != nil {
            Text(Self.appleZoomLabel(lens.displayZoom))
                .font(.footnote.monospacedDigit().weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.black.opacity(0.35), in: Capsule())
                .padding(.bottom, 14)
        }
    }

    // MARK: - Pressing it

    private func shoot() async {
        guard let photograph = await lens.capture() else { return }
        await develop(photograph)
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
        // Freeze this shot's settings and its capture place, write it to durable disk, and wake the
        // worker — all through the one shared intake (`DarkRoomWorker.enqueue`), which the Dark
        // Room's "load a picture" uses too, so both doors develop a shot identically. The place is
        // stamped now so the footer testifies to where it was taken even if it develops hours later.
        await worker.enqueue(photograph, place: place.placeStamp)
    }
}

// Copied verbatim from Hal (Hal Universal/ChatViews.swift, 2026-11-13) at Mark's request: on the Mac the
// Preferences and Dark Room cards were small fixed cards in a big window; Hal solved it this way.
extension View {
    /// Presents `content` as a sheet on iPhone/iPad, but as a window-filling full-screen cover on a
    /// "Designed for iPad" Mac (2026-08-05 Mac resizability). On Mac a `.sheet` is a fixed-size
    /// floating card that ignores the window; a `.fullScreenCover` fills the window and resizes
    /// with it, giving a modal container the same resizability as the main window. The
    /// isiOSAppOnMac value is constant for the process, so this `if` picks one presentation once at
    /// view-build time and never flips — the presentation identity stays stable. Same binding and
    /// onDismiss in both cases; each container keeps its own dismiss control (Done, or Cancel/Save).
    @ViewBuilder
    func macResizablePresentation<PresentedContent: View>(
        isPresented: Binding<Bool>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> PresentedContent
    ) -> some View {
        if ProcessInfo.processInfo.isiOSAppOnMac {
            self.fullScreenCover(isPresented: isPresented, onDismiss: onDismiss, content: content)
        } else {
            self.sheet(isPresented: isPresented, onDismiss: onDismiss, content: content)
        }
    }
}

// Thomas's addition, written to match Hal's modifier above: the same idea for a screen opened FOR an
// item (the license screen opens for one model). On the Mac the license card sized itself to its
// scrolling text; in a small window the card and the window kept re-measuring each other until macOS
// aborted ("more Layout Window passes than there are views in the window", reproduced twice,
// 2026-11-13); the square's numbers card did the same. A window-filling cover has no size to
// negotiate. iPhone and iPad keep the sheet.
extension View {
    @ViewBuilder
    func macResizablePresentation<Item: Identifiable, PresentedContent: View>(
        item: Binding<Item?>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> PresentedContent
    ) -> some View {
        if ProcessInfo.processInfo.isiOSAppOnMac {
            self.fullScreenCover(item: item, onDismiss: onDismiss, content: content)
        } else {
            self.sheet(item: item, onDismiss: onDismiss, content: content)
        }
    }
}

/// What Thomas calls the device it runs on, in words people read ("your Mac", "this iPad"). Thomas runs
/// on iPhone, iPad and (as the same app) on a Mac, and its messages said "phone" everywhere (found on the
/// Mac, 2026-11-13). `deviceKind` is copied verbatim from Hal 4 (Sources/HalKit/BuildIdentity.swift).
nonisolated enum ThisDevice {
    /// WHICH KIND OF DEVICE THIS HAL IS RUNNING ON: "Mac", "iPhone" or "iPad". The one place that says it: the prompt's
    /// "Device:" line, the send's log line and every door's reply read it. It names the KIND, never the person's own name
    /// for the device, which is theirs. Hal runs on a Mac as an iPad app, so the Mac is asked first (an iPad app on a Mac
    /// reports an iPad's screen). The hardware name is read from the system without UIKit, which HalKit does not import;
    /// in the Simulator the system names the simulated device in its environment.
    public nonisolated static var deviceKind: String {
        if ProcessInfo.processInfo.isiOSAppOnMac { return "Mac" }
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var bytes = [UInt8](repeating: 0, count: size)
        sysctlbyname("hw.machine", &bytes, &size, nil, 0)
        let machine = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]
            ?? String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        if machine.hasPrefix("iPad") { return "iPad" }
        return machine.hasPrefix("iPhone") ? "iPhone" : "Mac"
    }
}

// ==== LEGO END: 18 CameraView (The Sacred Screen) ====

// ==== LEGO START: 19 Seer (Which Eye Is Loaded) ====

/// Which machine is doing the seeing.
///
/// A camera has one film in it at a time. This is that — chosen before you raise the
/// camera, then out of your hands. There are two *kinds* of eye and they are genuinely
/// different animals: Apple's built-in model is obedient but nearly blind and has a filter
/// that stops images at the door; the MLX eyes (Qwen, and any other VLM you load) see far
/// more, have no filter at all, and largely ignore the system prompt. Preferences lets you
/// load any of them. None is "better" — that's not ours to say (Principle 3).
///
/// `.apple` is the one built-in special case; `.mlx(repoID:)` is any downloadable VLM,
/// named by its shared-store repo id — so the id rides *inside* the value and a shot frozen
/// with a given eye re-develops with that same eye, even if the live eye later changes.
nonisolated enum Seer: Hashable, Sendable {
    case apple
    case mlx(repoID: String)

    /// The canonical string spelling — one form used for persistence (`UserDefaults`), for
    /// the frozen `ShotConfig` (`Codable`), and for the antenna. `init(token:)` stays
    /// back-compatible: an install that saved the old `"qwen"`/`"afm"` raw values still
    /// decodes to the right eye.
    var token: String {
        switch self {
        case .apple:       return "apple"
        case .mlx(let id): return id
        }
    }

    init(token: String) {
        switch token {
        case "apple", "afm", "":  self = .apple
        case "qwen":              self = .mlx(repoID: Qwen.repo)   // legacy alias for the old rawValue
        default:                  self = .mlx(repoID: token)
        }
    }

    /// The catalog id this eye corresponds to — `"apple"`, or the MLX repo id. Used to line
    /// the selected eye up against a `CameraModel` in the library and the About screen.
    var modelID: String { token }

    var name: String {
        switch self {
        case .apple:       return "Apple Intelligence"
        case .mlx(let id): return ModelCatalog.model(id: id)?.displayName ?? id
        }
    }

    /// Whether this eye can be loaded right now.
    var isAvailable: Bool {
        switch self {
        case .apple:       return Readiness.current.isReady
        case .mlx(let id): return MLXEyeLoader.isAvailable(id)
        }
    }

    /// The image is already upright — see `uprighted`. No orientation to pass.
    ///
    /// The prompt and temperature come from Settings, so every eye is handed exactly the
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
        case .mlx(let id):
            // No retry: there is no filter to get past.
            return await MLXVLMEye(repoID: id, systemPrompt: systemPrompt, temperature: temperature).look(at: image)
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
        case .mlx(let id):
            return await MLXVLMEye(repoID: id, systemPrompt: systemPrompt, temperature: temperature).condense(text, toAtMostWords: maxWords)
        }
    }
}

/// Persisted as a single string (`token`) rather than by synthesized case-keys, so the
/// on-disk form is the stable, human-legible spelling shared with `UserDefaults` and the
/// antenna — and so an old `"qwen"` value survives the upgrade. Custom because `.mlx` carries
/// an associated value, so there is no free `String` raw value to lean on.
extension Seer: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        self = Seer(token: try c.decode(String.self))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(token)
    }
}

// ==== LEGO END: 19 Seer (Which Eye Is Loaded) ====
