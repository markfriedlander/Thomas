//
//  Camera.swift
//  AI Camera
//
//  The lens and the world's receipt.
//
//  Two jobs, both of which happen BEFORE any AI is involved:
//    - `Lens`  — AVFoundation capture. A photograph. No model, no inference, just light.
//    - `Place` — where and when, from GPS and the clock.
//
//  `Place` is not decoration. Panel 1 is what was actually there; the footer is what
//  notarizes it. In an app about the distance between what's real and what's perceived,
//  a verifiable anchor is load-bearing — and it's free: no AI, no latency, no tokens.
//  Cameras have stamped the date on the frame since long before any of this.
//

import Foundation
import AVFoundation
import CoreImage
import CoreLocation
import MapKit
import ImageIO
import UIKit

// ==== LEGO START: 13 Lens (Capture) ====

/// Rotate the pixels so that up is up.
///
/// ⚠️ This exists because a warning didn't work.
///
/// Orientation lives in metadata, not in the pixels: a phone held upright hands you a
/// sideways buffer plus a note saying "rotate me." Every consumer then has to remember
/// the note. On 2026-07-14 CC wrote an elaborate comment about this trap, threaded the
/// orientation correctly into the model — and then handed the compositor the raw buffer
/// with no orientation at all. The first real photograph came out sideways.
///
/// So the note is abolished. Both doors into this app (the shutter, and the antenna's
/// image upload) bake the rotation into the pixels immediately. Downstream — the eyes,
/// the darkroom — there is no orientation to pass, and therefore none to get wrong.
extension CGImage {
    func uprighted(_ orientation: CGImagePropertyOrientation) -> CGImage {
        guard orientation != .up else { return self }
        let ci = CIImage(cgImage: self).oriented(orientation)
        return CIContext().createCGImage(ci, from: ci.extent) ?? self
    }
}

/// The camera. Owns the AVFoundation session and hands back still frames.
///
/// Deliberately knows nothing about models, perception, or text. It takes photographs.
/// Everything downstream is somebody else's problem — which is the whole point of the
/// shot being atomic: the lens does its job and the interpretation is already loaded.
@MainActor
@Observable
final class Lens: NSObject {

    let session = AVCaptureSession()

    private let output = AVCapturePhotoOutput()
    private var device: AVCaptureDevice?
    private var configured = false
    private var pending: CheckedContinuation<AVCapturePhoto?, Never>?

    /// Apple's answer to "which way is the phone pointing."
    ///
    /// ⚠️ Do NOT replace this with `UIDevice.current.orientation`. That was the first
    /// attempt and it is a trap: it reports `.unknown` unless you explicitly start
    /// orientation notifications, so the code silently fell through to its default —
    /// "assume portrait" — forever. Portrait therefore worked *by accident* and landscape
    /// came out 90° wrong.
    ///
    /// The coordinator hands back two different angles, and they are genuinely different
    /// numbers: one to rotate the live preview, one to rotate the captured frame. Both
    /// track the device continuously, including the cases UIDevice can't express (face
    /// up, face down, mid-rotation).
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var rotationObservers: [NSKeyValueObservation] = []
    private weak var previewLayer: AVCaptureVideoPreviewLayer?

    private(set) var isAuthorized = false
    private(set) var isRunning = false
    /// True when there is a second camera to flip to. Decided by the cameras present, not by the
    /// platform: a Mac with only its built-in camera has none (the flip button hides), while an iPhone,
    /// an iPad, or a Mac using an iPhone as its camera has two (Mark, 2026-11-13).
    private(set) var canFlip = false

    /// The shape of the picture the camera delivers, upright (width / height). The viewfinder shows the
    /// WHOLE picture (aspect-fit, bands where the screen is another shape), so this is also the shape
    /// of the picture on screen, and the square guide is drawn inside it. Mark, 2026-11-13: you must
    /// always know exactly what is captured; a full-screen preview hid up to 46% of every photo.
    private(set) var pictureAspect: CGFloat = 3.0 / 4.0

    /// Current optical/digital zoom factor. On a virtual device this is one continuous
    /// scale spanning every lens — crossing a seam swaps the physical camera silently.
    private(set) var zoom: CGFloat = 1

    /// The zoom factors at which the device changes lenses (e.g. `[2.0, 6.0]` on a triple
    /// camera: ultra-wide → wide at 2×, wide → tele at 6×). Exposed so the UI can show
    /// where the seams are, and so `/rotation` can report them.
    var switchOverZoomFactors: [CGFloat] {
        device?.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) } ?? []
    }

    /// What Apple's own Camera calls a zoom factor, relative to ours. The device's raw scale
    /// starts at its widest lens (1.0 = the ultra-wide on a phone that has one), but Apple's
    /// Camera calls the main lens 1x and the ultra-wide 0.5x. The SDK documents this multiplier
    /// as the way to stay consistent with Apple's system UI (iOS 18+). Mark, 2026-11-13: Thomas
    /// read 1.0 to 12.0 where Apple's Camera reads 0.5 to 10 on the same phone; "let's match
    /// Apple so it feels consistent."
    var displayMultiplier: CGFloat {
        guard let m = device?.displayVideoZoomFactorMultiplier, m > 0 else { return 1 }
        return m
    }

    /// The zoom as Apple's Camera would label it (0.5x, 1x, 2x...).
    var displayZoom: CGFloat { zoom * displayMultiplier }

    var zoomRange: ClosedRange<CGFloat> {
        guard let device else { return 1...1 }
        // Cap the top where Apple's Camera stops, in Apple's numbers: 10x on a phone without a
        // telephoto (Mark's 16 Plus, measured by him in Apple's Camera), and 5x the telephoto on
        // a phone with one (Apple's published "digital zoom up to" for its Pro phones: a 2x tele
        // reaches 10x, 3x reaches 15x, 5x reaches 25x). Past that a device offers 100x+ of pure
        // upscaling, which is cropping, not zoom. Only Mark's phone is measured; a newer Pro may
        // let Apple's Camera go further than this rule.
        let longestLens = (switchOverZoomFactors.last ?? 1) * displayMultiplier
        let appleTop = max(10, 5 * longestLens)
        let low = device.minAvailableVideoZoomFactor
        let high = max(low, min(device.maxAvailableVideoZoomFactor, appleTop / displayMultiplier))
        return low...high
    }

    // DEBUG-only diagnostics. Every member below is read ONLY by the DEBUG antenna's diagnostic
    // routes (rawZoomBounds/diagnostics/interfaceOrientationName by GET routes, `current` as the
    // antenna's live handle); nothing in a shipping build calls any of them. Wrapped so no dead
    // code ships (Mark, 2026-07-28: "we should not ship dead code — it isn't safe — wrap it").
    #if DEBUG
    /// The RAW device zoom bounds, read without ever constructing `zoomRange` — because that
    /// `ClosedRange` traps the instant `minAvailableVideoZoomFactor` exceeds the 12× cap
    /// (`low...high` with low > high). This is the antenna's way to SEE those numbers, and
    /// spot exactly that condition, without triggering the crash it's hunting for. `cap` is the
    /// top the range clamps to (raw). `zoomRange` now guards low > high itself; the numbers stay
    /// for seeing. The display* entries are what a person reads on screen (Apple's numbers).
    var rawZoomBounds: [String: Double]? {
        guard let device else { return nil }
        let range = zoomRange
        return [
            "deviceMin": Double(device.minAvailableVideoZoomFactor),
            "deviceMax": Double(device.maxAvailableVideoZoomFactor),
            "cap": Double(range.upperBound),
            "current": Double(zoom),
            "displayMultiplier": Double(displayMultiplier),
            "displayMin": Double(range.lowerBound * displayMultiplier),
            "displayMax": Double(range.upperBound * displayMultiplier),
            "displayCurrent": Double(displayZoom)
        ]
    }

    /// The lens currently on screen, so the antenna can interrogate it. DEBUG-only —
    /// this exists to serve a diagnostic route that doesn't ship.
    static weak var current: Lens?

    /// Live rotation state, exposed so the antenna can report it. Reading the real
    /// numbers beats reasoning about what they ought to be.
    var diagnostics: [String: Any] {
        [
            "hasDevice":         device != nil,
            "hasPreviewLayer":   previewLayer != nil,
            "hasCoordinator":    rotation != nil,
            "previewAngle":      rotation?.videoRotationAngleForHorizonLevelPreview ?? -1,
            "captureAngle":      rotation?.videoRotationAngleForHorizonLevelCapture ?? -1,
            "appliedPreview":    previewLayer?.connection?.videoRotationAngle ?? -1,
            "appliedCapture":    output.connection(with: .video)?.videoRotationAngle ?? -1,
            "interfaceOrientation": Self.interfaceOrientationName,
            // Which camera this actually is, so a Mac's (or any new device's) camera is measured,
            // not guessed: its name, its type, and which way it says it faces.
            "deviceName":        device?.localizedName ?? "",
            "deviceType":        device?.deviceType.rawValue ?? "",
            "devicePosition":    device.map { $0.position == .front ? "front" : $0.position == .back ? "back" : "unspecified" } ?? "",
            "isiOSAppOnMac":     ProcessInfo.processInfo.isiOSAppOnMac,
            "canFlip":           canFlip,
            // What the camera can hand over, measured not assumed (the Mac's landscape/portrait
            // question, 2026-11-13): the format in use, every size it offers, the largest photo.
            "activeFormat":      device.map { d -> String in
                let dim = CMVideoFormatDescriptionGetDimensions(d.activeFormat.formatDescription)
                return "\(dim.width)x\(dim.height)" } ?? "",
            "formats":           device.map { d -> [String] in
                Array(Set(d.formats.map { f -> String in
                    let dim = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
                    return "\(dim.width)x\(dim.height)" })).sorted() } ?? [],
            "maxPhoto":          "\(output.maxPhotoDimensions.width)x\(output.maxPhotoDimensions.height)",
            "sessionPreset":     session.sessionPreset.rawValue,
            // Where the WHOLE captured picture lies relative to the preview on screen (Apple's own
            // conversion), and the screen area the preview occupies, in points. A picture rect larger
            // than the layer means part of every photo is off screen (2026-11-13, Mark: "There is a
            // portion of image that is captured that isn't actually visible through the view finder?").
            "pictureRectOnScreen": previewLayer.map { l -> [Double] in
                let r = l.layerRectConverted(fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1))
                return [r.minX, r.minY, r.width, r.height].map { Double($0) } } ?? [],
            "previewBounds":     previewLayer.map { [Double($0.bounds.width), Double($0.bounds.height)] } ?? [],
            "pictureAspect":     Double(pictureAspect),
            "previewMirrored":   previewLayer?.connection?.isVideoMirrored ?? false,
            "photoMirrored":     output.connection(with: .video)?.isVideoMirrored ?? false,
            "position":          position == .front ? "front" : "back",
            // Every camera the flip could choose between, by name and the way it says it faces.
            "backPick":          backDevice().map { "\($0.localizedName) [\($0.deviceType.rawValue)]" } ?? "",
            "frontPick":         frontDevice().map { "\($0.localizedName) [\($0.deviceType.rawValue)]" } ?? "",
            "macAngle":          macAngle ?? -1
        ]
    }

    /// Focus and exposure as the camera holds them now, for `POST /focus`: what the person set (point
    /// on screen, lock, brightness) beside what the device reports, so a tap can be checked against
    /// what the camera actually did.
    var focusDiagnostics: [String: Any] {
        func mode(_ m: AVCaptureDevice.FocusMode) -> String {
            switch m { case .locked: "locked"; case .autoFocus: "auto"; case .continuousAutoFocus: "continuous"; @unknown default: "?" }
        }
        func mode(_ m: AVCaptureDevice.ExposureMode) -> String {
            switch m { case .locked: "locked"; case .autoExpose: "auto"; case .continuousAutoExposure: "continuous"; case .custom: "custom"; @unknown default: "?" }
        }
        var d: [String: Any] = [
            "focusPoint":   focusPoint.map { [Double($0.x), Double($0.y)] } ?? [],
            "focusLocked":  focusLocked,
            "exposureBias": Double(exposureBias),
            "canAdjustExposure": canAdjustExposure
        ]
        if let device {
            d["deviceFocusMode"] = mode(device.focusMode)
            d["deviceFocusPoint"] = [Double(device.focusPointOfInterest.x), Double(device.focusPointOfInterest.y)]
            d["deviceExposureMode"] = mode(device.exposureMode)
            d["deviceExposurePoint"] = [Double(device.exposurePointOfInterest.x), Double(device.exposurePointOfInterest.y)]
            d["deviceBias"] = Double(device.exposureTargetBias)
            d["canFocusAtPoint"] = device.isFocusPointOfInterestSupported
            d["canExposeAtPoint"] = device.isExposurePointOfInterestSupported
            d["watchingScene"] = device.isSubjectAreaChangeMonitoringEnabled
        }
        return d
    }

    nonisolated static var interfaceOrientationName: String {
        MainActor.assumeIsolated {
            // effectiveGeometry, not the deprecated `interfaceOrientation`.
            let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
            switch scene?.effectiveGeometry.interfaceOrientation {
            case .portrait:           return "portrait"
            case .portraitUpsideDown: return "portraitUpsideDown"
            case .landscapeLeft:      return "landscapeLeft"
            case .landscapeRight:     return "landscapeRight"
            default:                  return "unknown"
            }
        }
    }
    #endif

    func start() async {
        isAuthorized = await Self.authorize()
        guard isAuthorized else { return }
        configure()
        guard !session.isRunning else { isRunning = true; return }
        let s = session
        await Task.detached { s.startRunning() }.value
        isRunning = session.isRunning
    }

    func stop() {
        guard session.isRunning else { return }
        let s = session
        Task.detached { s.stopRunning() }
        isRunning = false
    }

    /// The viewfinder hands us its layer so the coordinator can measure the preview
    /// against it. Without a layer, the preview angle is always reported as 0.
    func attach(previewLayer layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        #if DEBUG
        Lens.current = self
        #endif
        beginTrackingRotation()
    }

    private static func authorize() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    /// Which way the camera faces. Back by default; the flip glyph toggles it.
    private(set) var position: AVCaptureDevice.Position = .back

    /// The back camera as a **virtual device**, in preference order — what the native camera
    /// uses. `.builtInWideAngleCamera` is ONE physical lens (the old single-focal-length bug);
    /// a virtual device presents all the back lenses as one and **switches between them as you
    /// zoom** (Apple picks the best lens for the scene). Ordered most-lenses-first, degrading to
    /// the single wide angle, which EVERY iPhone has — so this can't come up empty on real
    /// hardware. Asked for by name in our order (not `DiscoverySession.first`, whose ordering CC
    /// never verified).
    private func backDevice() -> AVCaptureDevice? {
        let preferred: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,     // ultra-wide + wide + tele   (Pro)
            .builtInDualWideCamera,   // ultra-wide + wide          (standard 13/14/15/16)
            .builtInDualCamera,       // wide + tele                (older Plus/Pro)
            .builtInWideAngleCamera   // one lens                   (SE, and the floor)
        ]
        return preferred.lazy.compactMap {
            AVCaptureDevice.default($0, for: .video, position: .back)
        }.first
    }

    /// The front camera — a single wide-angle lens on every iPhone.
    private func frontDevice() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
    }

    private func configure() {
        guard !configured else { return }
        session.beginConfiguration()
        session.sessionPreset = .photo

        // An iPhone opens on its back camera. A Mac (the same app, run as "Designed for iPad") has no
        // back camera, so it falls back to whatever camera is there rather than showing nothing.
        if let device = backDevice() ?? frontDevice() ?? AVCaptureDevice.default(for: .video),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
            self.device = device
            self.position = device.position == .front ? .front : .back
            // Start at Apple's 1x, the main lens, not the ultra-wide (see `defaultZoom`).
            zoom = defaultZoom(for: device)
            applyZoom(zoom)
        }
        if session.canAddOutput(output) { session.addOutput(output) }

        session.commitConfiguration()
        configured = true
        // Two cameras only if they differ by name as well as ID: on a Mac the one FaceTime camera is
        // handed out as BOTH the "back" and the "front" camera, under different IDs (measured with
        // /rotation's backPick/frontPick, 2026-11-13).
        if let back = backDevice(), let front = frontDevice() {
            canFlip = back.uniqueID != front.uniqueID && back.localizedName != front.localizedName
        }
        beginTrackingRotation()
        if let device { startFocusFresh(on: device) }
    }

    /// Flip between the back and front cameras — the selfie toggle.
    ///
    /// A full session reconfiguration: swap the input, keep the one photo output, and rebuild
    /// the rotation coordinator against the new device (its angles differ, and the front camera
    /// is mounted the other way). Wrapped in begin/commit so the session never runs half-built.
    ///
    /// ⚠️ NEEDS A DEVICE CHECK. Two things can only be judged on real hardware: whether the
    /// **front preview should be mirrored** (users expect a mirror; the *saved* photo usually
    /// isn't), and the front camera's **capture orientation**. Left honest for now — no mirroring
    /// applied — so we tune it against what the phone actually shows rather than guessing.
    func flip() {
        guard configured else { return }
        let target: AVCaptureDevice.Position = (position == .back) ? .front : .back
        guard let device = (target == .front ? frontDevice() : backDevice()),
              let input = try? AVCaptureDeviceInput(device: device) else { return }

        session.beginConfiguration()
        for existing in session.inputs { session.removeInput(existing) }
        if session.canAddInput(input) {
            session.addInput(input)
            self.device = device
            self.position = target
            zoom = defaultZoom(for: device)
            applyZoom(zoom)
        } else if let back = backDevice(), let backInput = try? AVCaptureDeviceInput(device: back),
                  session.canAddInput(backInput) {
            // Couldn't add the target — fall back to the back camera so we never end up input-less.
            session.addInput(backInput)
            self.device = back
            self.position = .back
        }
        session.commitConfiguration()
        beginTrackingRotation()   // the new device faces the other way; its angles must be remade
        if let current = self.device { startFocusFresh(on: current) }
    }

    #if DEBUG
    /// Which way it faces, as a plain bool, so the antenna doesn't have to import AVFoundation to ask.
    /// `setCamera(front:)` flips only if it isn't already there. DEBUG-only: read/driven solely by the
    /// antenna's `/flip` verb; a human uses `flip()` (the flip button), which stays in every build.
    var isFront: Bool { position == .front }
    func setCamera(front: Bool) { if isFront != front { flip() } }

    /// Antenna-only experiment (2026-11-13, the Mac's landscape/portrait question): use the camera
    /// format of this size and, on a Mac, this quarter-turn angle, so each combination can be LOOKED
    /// at instead of reasoned about. Not a user feature; nothing calls it but `POST /camera-format`.
    var debugMacAngle: CGFloat?
    func debugUseFormat(width: Int32, height: Int32, angle: CGFloat?) -> Bool {
        guard let device, let f = device.formats.first(where: {
            let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return d.width == width && d.height == height
        }), (try? device.lockForConfiguration()) != nil else { return false }
        session.beginConfiguration()
        session.sessionPreset = .inputPriority
        device.activeFormat = f
        session.commitConfiguration()
        device.unlockForConfiguration()
        debugMacAngle = angle
        beginTrackingRotation()
        return true
    }
    #endif

    private func beginTrackingRotation() {
        guard let device else { return }
        // Rebuild, don't skip. `configure()` runs before the viewfinder exists, so the
        // first coordinator is built with previewLayer == nil — and Apple documents that
        // as "returns 0 degrees forever." When the layer finally arrives via attach(),
        // the coordinator has to be made again against it. An early-return guard here
        // was the bug: it kept the useless layer-less coordinator.
        rotationObservers.removeAll()
        applyMirroring()   // the camera (or the layer) just changed; the mirror follows it
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device,
                                                              previewLayer: previewLayer)
        rotation = coordinator
        // KVO fires off the main actor, so each angle is read and the reference bound to
        // a constant here, before hopping. Capturing the weak `self` var directly inside
        // the Task is what the compiler objects to — and it's right to.
        rotationObservers = [
            coordinator.observe(\.videoRotationAngleForHorizonLevelPreview,
                                options: [.initial, .new]) { [weak self] c, _ in
                let angle = c.videoRotationAngleForHorizonLevelPreview
                guard let lens = self else { return }
                Task { @MainActor in lens.apply(previewAngle: angle) }
            },
            coordinator.observe(\.videoRotationAngleForHorizonLevelCapture,
                                options: [.initial, .new]) { [weak self] c, _ in
                let angle = c.videoRotationAngleForHorizonLevelCapture
                guard let lens = self else { return }
                Task { @MainActor in lens.apply(captureAngle: angle) }
            }
        ]
    }

    /// Mirror the PREVIEW of a camera that faces the person (so it moves like a mirror), never the
    /// saved photo: the iPhone Camera app's default (Settings > Camera > Mirror Front Camera is off
    /// unless turned on), and what FaceTime does. A camera faces the person when it is the front
    /// camera, or on a Mac, where the built-in camera looks at whoever is at the screen even though
    /// it calls itself "back" (Mark, 2026-11-13: "do what FaceTime does or whatever the ... most common
    /// standard is"). Set explicitly rather than left to automatic adjustment, which keyed on the
    /// camera's own position and so never mirrored the Mac.
    private func applyMirroring() {
        let facesPerson = position == .front || ProcessInfo.processInfo.isiOSAppOnMac
        if let c = previewLayer?.connection, c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = facesPerson
        }
        if let c = output.connection(with: .video), c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = false
        }
    }


    /// Recompute `pictureAspect` from the format in use and the preview's rotation.
    private func updatePictureAspect() {
        guard let device else { return }
        let d = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        guard d.width > 0, d.height > 0 else { return }
        let angle = previewLayer?.connection?.videoRotationAngle ?? 0
        let quarter = Int(angle.rounded()) % 180 == 90
        pictureAspect = quarter ? CGFloat(d.height) / CGFloat(d.width) : CGFloat(d.width) / CGFloat(d.height)
    }

    private func apply(previewAngle angle: CGFloat) {
        defer { updatePictureAspect() }
        let angle = macAngle ?? angle
        guard let connection = previewLayer?.connection,
              connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    private func apply(captureAngle angle: CGFloat) {
        let angle = macAngle ?? angle
        guard let connection = output.connection(with: .video),
              connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    /// The angle to use on a Mac, or nil everywhere else (iPhone and iPad keep the coordinator's live,
    /// horizon-level answer).
    ///
    /// On a Mac this same app runs as "Designed for iPad" and believes it is an iPad held in portrait,
    /// while a Mac never turns, so the horizon-level angle comes back 0 and the picture was a quarter
    /// turn counterclockwise (Mark's face sideways, seen in Thomas's own window, 2026-11-13). A quarter
    /// turn (90) puts it upright: what an iPad held in portrait gives its camera, and a Mac's camera is
    /// fixed to its screen, so it never needs to change.
    ///
    /// ⚠️ Not `videoRotationAngleRelative(toDeviceOrientation:)`, Apple's iOS 27 "angle for an orientation
    /// the app provides": it is iPhone/iPad only and does NOT exist in the Mac's AVFoundation (checked
    /// with class_getInstanceMethod on macOS 27.2). Calling it crashed Thomas on the Mac, 2026-11-13.
    private var macAngle: CGFloat? {
        #if DEBUG
        if let debugMacAngle, ProcessInfo.processInfo.isiOSAppOnMac { return debugMacAngle }
        #endif
        return ProcessInfo.processInfo.isiOSAppOnMac ? 90 : nil
    }

    // MARK: - Zoom

    /// Open where Apple's Camera opens: its 1x, the main lens. On a virtual device with an
    /// ultra-wide the raw scale starts AT the ultra-wide (raw 1.0 = Apple's 0.5x), so Apple's 1x
    /// is raw 1 / displayMultiplier (2.0 on Mark's 16 Plus). Until 2026-11-13 this returned raw
    /// 1.0 and so opened on the ultra-wide, believing raw 1.0 was the main lens.
    private func defaultZoom(for device: AVCaptureDevice) -> CGFloat {
        let range = zoomRange
        return min(max(1 / displayMultiplier, range.lowerBound), range.upperBound)
    }

    /// Pinch. `scale` is the gesture's cumulative magnification since it began, so the
    /// caller passes the zoom the pinch started from rather than compounding each update.
    func zoom(by scale: CGFloat, from initial: CGFloat) {
        applyZoom(initial * scale)
    }

    private func applyZoom(_ requested: CGFloat) {
        guard let device else { return }
        let clamped = min(max(requested, zoomRange.lowerBound), zoomRange.upperBound)
        // Lock only for the instant of the change — holding it blocks the session.
        guard (try? device.lockForConfiguration()) != nil else { return }
        device.videoZoomFactor = clamped
        device.unlockForConfiguration()
        zoom = clamped
    }

    // MARK: - Focus and exposure (Apple's Camera gestures: tap, press and hold, drag)

    /// Where the person last tapped to focus and expose, in the preview layer's points (the same
    /// points as the viewfinder on screen), or nil while the camera chooses for itself.
    private(set) var focusPoint: CGPoint?
    /// True after a press and hold: focus and exposure stay where they were set until the next tap,
    /// whatever the scene does (Apple's "AE/AF LOCK").
    private(set) var focusLocked = false
    /// The brightness the person dragged in, in exposure stops (EV). 0 is the camera's own choice.
    private(set) var exposureBias: Float = 0
    private var subjectAreaObserver: NSObjectProtocol?

    /// A couple of stops either way, like Apple's Camera slider. The hardware allows far more,
    /// which mostly gives a white or a black frame.
    private static let biasLimit: Float = 2

    /// True when this camera lets brightness be adjusted at all.
    var canAdjustExposure: Bool {
        guard let device else { return false }
        return device.maxExposureTargetBias > device.minExposureTargetBias
    }

    /// A tap (lock false) or a press and hold (lock true) at a point on the viewfinder. Focus and
    /// exposure are set once at that point and then held. After a tap, a big change in the scene
    /// hands control back to the camera (`watchSubjectArea`), as in Apple's Camera; after a hold,
    /// nothing does until the next tap. Returns false, and changes nothing, when the point is
    /// outside the picture (on the black bands) or this camera can set neither.
    @discardableResult
    func focus(atScreenPoint point: CGPoint, lock: Bool) -> Bool {
        guard let device, let layer = previewLayer else { return false }
        let picture = layer.layerRectConverted(fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard picture.contains(point) else { return false }
        // The layer knows its own rotation, mirroring and fit, so it is the one to convert.
        let devicePoint = layer.captureDevicePointConverted(fromLayerPoint: point)
        let canFocus = device.isFocusPointOfInterestSupported && device.isFocusModeSupported(.autoFocus)
        let canExpose = device.isExposurePointOfInterestSupported && device.isExposureModeSupported(.autoExpose)
        guard canFocus || canExpose else { return false }
        guard (try? device.lockForConfiguration()) != nil else { return false }
        if canFocus {
            device.focusPointOfInterest = devicePoint
            device.focusMode = .autoFocus        // focus once there, then hold
        }
        if canExpose {
            device.exposurePointOfInterest = devicePoint
            device.exposureMode = .autoExpose    // meter once there, then hold
        }
        if device.maxExposureTargetBias > device.minExposureTargetBias {
            device.setExposureTargetBias(0, completionHandler: nil)
        }
        device.isSubjectAreaChangeMonitoringEnabled = !lock
        device.unlockForConfiguration()
        focusPoint = point
        focusLocked = lock
        exposureBias = 0
        return true
    }

    /// Brighter (positive) or darker (negative), in stops, kept within `biasLimit` and what the
    /// camera allows.
    func setExposureBias(_ ev: Float) {
        guard let device, canAdjustExposure else { return }
        let low = max(device.minExposureTargetBias, -Self.biasLimit)
        let high = min(device.maxExposureTargetBias, Self.biasLimit)
        let clamped = min(max(ev, low), high)
        guard (try? device.lockForConfiguration()) != nil else { return }
        device.setExposureTargetBias(clamped, completionHandler: nil)
        device.unlockForConfiguration()
        exposureBias = clamped
    }

    /// Hand focus and exposure back to the camera: continuous, centred, no brightness change.
    func resetFocus() {
        focusPoint = nil
        focusLocked = false
        exposureBias = 0
        guard let device, (try? device.lockForConfiguration()) != nil else { return }
        let centre = CGPoint(x: 0.5, y: 0.5)
        if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = centre }
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = centre }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        if device.maxExposureTargetBias > device.minExposureTargetBias {
            device.setExposureTargetBias(0, completionHandler: nil)
        }
        device.isSubjectAreaChangeMonitoringEnabled = false
        device.unlockForConfiguration()
    }

    /// A new camera (launch or flip) starts with the camera choosing, and with the scene watcher
    /// pointed at it.
    private func startFocusFresh(on device: AVCaptureDevice) {
        resetFocus()
        if let old = subjectAreaObserver { NotificationCenter.default.removeObserver(old) }
        subjectAreaObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.subjectAreaDidChangeNotification, object: device, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.focusPoint != nil, !self.focusLocked else { return }
                self.resetFocus()
            }
        }
    }

    // MARK: - The shutter

    /// Press the shutter. Returns an **upright** frame, or nil if the capture failed.
    ///
    /// Two belts, because this has bitten us once already: the capture connection is
    /// already rotated by the coordinator, AND we honour whatever orientation the photo
    /// declares about itself. Downstream is handed pixels and nothing else.
    func capture() async -> CGImage? {
        let photo: AVCapturePhoto? = await withCheckedContinuation { cont in
            pending = cont
            output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
        guard let photo, let cg = photo.cgImageRepresentation() else { return nil }
        let raw = photo.metadata[kCGImagePropertyOrientation as String] as? UInt32 ?? 1
        return cg.uprighted(CGImagePropertyOrientation(rawValue: raw) ?? .up)
    }
}

extension Lens: @preconcurrency AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        pending?.resume(returning: error == nil ? photo : nil)
        pending = nil
    }
}

// ==== LEGO END: 13 Lens (Capture) ====

// ==== LEGO START: 14 Place (Reality's Receipt) ====

/// Where the shot was taken, and when.
///
/// The footer in Mark's book: place bottom-left, date bottom-right. Derived from GPS and
/// the clock — no AI, no latency, no tokens. **The machine asserts; the photograph and
/// the metadata testify.**
///
/// Failure here is silent by design: a shot with no place stamp is still a shot. We never
/// block the shutter waiting for a fix, and we never invent a location we don't have.
@MainActor
@Observable
final class Place: NSObject {

    /// e.g. "Tulsa, Oklahoma" — nil until a fix arrives, and nil forever if denied.
    private(set) var name: String?

    /// The latest raw GPS fix, kept always (even in raw-coordinate mode, where we never geocode).
    /// Feeds `rawStamp`, the footer's forensic alternative to a place name.
    private(set) var coordinate: CLLocationCoordinate2D?

    #if DEBUG
    /// The live place, so the antenna can stamp the real location on a remote press — the
    /// same app-level handle `Lens.current` gives it for the sensor. DEBUG-only, because the
    /// antenna it serves doesn't ship. Without this the location was locked inside the camera
    /// view and a remote press landed with no place stamp, which broke the antenna's own rule:
    /// do everything a human can that Apple doesn't block. A human gets the stamp; now so does
    /// the antenna. `weak`, like the lens — it auto-nils when the view lets the `Place` go.
    static weak var current: Place?
    #endif

    private let manager = CLLocationManager()
    private var lastGeocoded: CLLocation?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func start() {
        #if DEBUG
        // Register as the live place the moment the camera starts tracking — the parallel to
        // `Lens.current = self` in `Camera.attach`. This is what lets `POST /press` stamp the
        // real location instead of nil.
        Place.current = self
        #endif
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways: manager.startUpdatingLocation()
        default: break   // denied — no stamp, no complaint
        }
    }

    func stop() { manager.stopUpdatingLocation() }

    /// What the footer stamps for place, honoring the raw-coordinate privacy setting. Read at
    /// capture time (and by the antenna), so a shot freezes whichever form was chosen when taken.
    /// In raw mode this is `rawStamp` and NO geocode is ever performed (see `resolve`); otherwise
    /// it is the reverse-geocoded `name`.
    var placeStamp: String? {
        Settings.shared.stampRawCoordinates ? rawStamp : name
    }

    /// The raw fix as a footer string, e.g. "34.0522° N, 118.2437° W". Nil until a fix arrives.
    /// Unmediated: just the numbers the device measured, with no third-party lookup deciding what
    /// they "mean" — arguably the more honest stamp for a camera about the gap between a thing and
    /// an account of it (NEXT.md).
    var rawStamp: String? {
        guard let c = coordinate else { return nil }
        let lat = String(format: "%.4f", abs(c.latitude))
        let lon = String(format: "%.4f", abs(c.longitude))
        return "\(lat)° \(c.latitude >= 0 ? "N" : "S"), \(lon)° \(c.longitude >= 0 ? "E" : "W")"
    }

    /// The date and time, in the book's voice: "June 21, 2020 · 3:42 PM". Time was added
    /// 2026-07-16 (Mark) so two shots the same day no longer stamp identically — the footer's
    /// whole job is to testify *when*, and time sharpens it. One source, so every layout's
    /// footer reads the same.
    static func stamp(_ date: Date = Date()) -> String {
        let day = date.formatted(.dateTime.month(.wide).day().year())
        let time = date.formatted(.dateTime.hour().minute())
        return "\(day) · \(time)"
    }

    private func resolve(_ location: CLLocation) {
        // Raw-coordinate privacy mode: never geocode, so no coordinate is ever sent anywhere and
        // the shot path can be genuinely, provably local. The footer uses `rawStamp` instead.
        if Settings.shared.stampRawCoordinates { return }
        // Don't re-geocode for small moves; the place name doesn't change block to block.
        if let last = lastGeocoded, location.distance(from: last) < 500 { return }
        lastGeocoded = location

        // MapKit, not CLGeocoder — the latter is deprecated as of iOS 26.
        //
        // `cityWithContext` is a gift: Apple's own "city, plus enough context to
        // disambiguate it" — which resolves to exactly the form the book's footer uses
        // ("Tulsa, Oklahoma"). We are not assembling that string ourselves out of
        // locality + state and hoping it reads right in every country.
        Task { @MainActor [weak self] in
            guard let request = MKReverseGeocodingRequest(location: location),
                  let items = try? await request.mapItems,
                  let place = items.first?.addressRepresentations else { return }
            self?.name = place.cityWithContext ?? place.regionName
        }
    }
}

extension Place: @preconcurrency CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: manager.startUpdatingLocation()
        default: break
        }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        coordinate = loc.coordinate   // always keep the raw fix, for the coordinate stamp
        resolve(loc)
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Silent. A shot without a place stamp is still a shot.
    }
}

// ==== LEGO END: 14 Place (Reality's Receipt) ====
