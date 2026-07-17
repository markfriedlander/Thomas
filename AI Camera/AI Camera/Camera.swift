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

    /// Current optical/digital zoom factor. On a virtual device this is one continuous
    /// scale spanning every lens — crossing a seam swaps the physical camera silently.
    private(set) var zoom: CGFloat = 1

    /// The zoom factors at which the device changes lenses (e.g. `[2.0, 6.0]` on a triple
    /// camera: ultra-wide → wide at 2×, wide → tele at 6×). Exposed so the UI can show
    /// where the seams are, and so `/rotation` can report them.
    var switchOverZoomFactors: [CGFloat] {
        device?.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) } ?? []
    }

    var zoomRange: ClosedRange<CGFloat> {
        guard let device else { return 1...1 }
        // Cap the top: a device will happily offer 100×+ of pure digital upscaling, which
        // is not zoom, it's cropping. 12× is past every optical seam on current phones.
        return device.minAvailableVideoZoomFactor...min(device.maxAvailableVideoZoomFactor, 12)
    }

    #if DEBUG
    /// The lens currently on screen, so the antenna can interrogate it. DEBUG-only —
    /// this exists to serve a diagnostic route that doesn't ship.
    static weak var current: Lens?
    #endif

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
            "interfaceOrientation": Self.interfaceOrientationName
        ]
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

    private func configure() {
        guard !configured else { return }
        session.beginConfiguration()
        session.sessionPreset = .photo

        // ⭐ A VIRTUAL device, in preference order — this is what the native camera uses.
        //
        // `.builtInWideAngleCamera` is ONE physical lens, which is why the camera was
        // stuck on a single focal length. A virtual device presents all the back lenses
        // as one, and **switches between them automatically as you zoom** — Apple: "the
        // virtual device chooses the best camera for the scene," picking the longest focal
        // length that avoids digital upscaling, and falling back to a wider lens when the
        // subject is closer than the tele's minimum focus distance. We get that for free;
        // we just have to ask for the right device.
        //
        // Ordered most-lenses-first, degrading gracefully all the way down to one lens.
        // EVERY back camera any iPhone has ever shipped is covered by the last entry, so
        // this cannot come up empty on hardware that has a camera at all:
        let preferred: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,     // ultra-wide + wide + tele   (Pro)
            .builtInDualWideCamera,   // ultra-wide + wide          (standard 13/14/15/16)
            .builtInDualCamera,       // wide + tele                (older Plus/Pro)
            .builtInWideAngleCamera   // one lens                   (SE, and the floor)
        ]
        // Walk the list explicitly and take the first that EXISTS.
        //
        // ⚠️ Not `DiscoverySession(...).devices.first` — that assumes the discovery
        // session hands devices back in the order they were requested, which is an
        // ordering guarantee CC never verified. An SE would then get whatever came out
        // first. This asks for each device by name, in our order, and stops at the first
        // real one. On a single-lens phone that's the wide angle, `zoomRange` collapses to
        // whatever it supports, `switchOverZoomFactors` is empty, and pinch still works —
        // it's just digital, because there's no second lens to switch to.
        if let device = preferred.lazy.compactMap({
               AVCaptureDevice.default($0, for: .video, position: .back)
           }).first,
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
            self.device = device
            // Start at 1× — the wide lens on every modern iPhone, not the ultra-wide.
            // On a virtual device the zoom scale is continuous ACROSS lenses, so 1.0 is
            // not necessarily the minimum; `switchOverZoomFactors` says where the seams
            // are. Clamp into whatever this device actually supports.
            zoom = defaultZoom(for: device)
            applyZoom(zoom)
        }
        if session.canAddOutput(output) { session.addOutput(output) }

        session.commitConfiguration()
        configured = true
        beginTrackingRotation()
    }

    private func beginTrackingRotation() {
        guard let device else { return }
        // Rebuild, don't skip. `configure()` runs before the viewfinder exists, so the
        // first coordinator is built with previewLayer == nil — and Apple documents that
        // as "returns 0 degrees forever." When the layer finally arrives via attach(),
        // the coordinator has to be made again against it. An early-return guard here
        // was the bug: it kept the useless layer-less coordinator.
        rotationObservers.removeAll()
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

    private func apply(previewAngle angle: CGFloat) {
        guard let connection = previewLayer?.connection,
              connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    private func apply(captureAngle angle: CGFloat) {
        guard let connection = output.connection(with: .video),
              connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    // MARK: - Zoom

    /// 1× on a virtual device isn't the minimum — on a triple camera the ultra-wide sits
    /// below it. Open where the native camera opens.
    private func defaultZoom(for device: AVCaptureDevice) -> CGFloat {
        max(device.minAvailableVideoZoomFactor, min(1.0, device.maxAvailableVideoZoomFactor))
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

    /// The date, in the book's voice: "June 21, 2020".
    static func stamp(_ date: Date = Date()) -> String {
        date.formatted(.dateTime.month(.wide).day().year())
    }

    private func resolve(_ location: CLLocation) {
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
        resolve(loc)
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Silent. A shot without a place stamp is still a shot.
    }
}

// ==== LEGO END: 14 Place (Reality's Receipt) ====
