//
//  LocalAPIServer.swift
//  AI Camera
//
//  The antenna — the path by which an external process (Claude Code) can drive the
//  camera without going through the SwiftUI shell or Mark's thumbs.
//
//  Adapted from Posey's Services/LocalAPI/LocalAPIServer.swift (2026-07-14), which was
//  itself adapted from Hal Universal's. Port family: Posey 8765, Hal 8766, AI Camera
//  8767. The Keychain/NWListener/HTTP-parsing machinery is Posey's, retyped — including
//  two comments that encode real scars (the cached-token Catalyst bug, and the temp-file
//  token drop that lets a harness self-serve without grepping a redacted log).
//
//  Deliberate divergences from Posey, both because this app is shaped differently:
//
//    1. NO handler injection. Posey injects @Sendable closures because its API drives a
//       stateful ViewModel across an actor boundary. A look is a *pure function*
//       (image + Eye -> Perception), so the server calls `Eye.look` directly. Fewer
//       moving parts, nothing to wire up, nothing to forget to wire up.
//
//    2. NO /command route (yet). Posey has SET_* verbs because it has persistent state
//       to set. We have no Preferences screen and nothing durable to mutate, so a
//       /command route would be a stub that lies about what it does. Per-request
//       overrides on /look cover every experiment we currently want, and are *better*
//       for sweeps: six system prompts in six requests, no state to reset between them.
//       Add /command when there is real state behind it.
//
//  Everything here compiles out of Release builds — see the #if DEBUG below.
//

import Foundation
import FoundationModels   // Guardrails.permissiveContentTransformations
import MLX                // Memory.snapshot() — GET /memory
import Network
import Security
import CoreGraphics
import ImageIO
import UIKit              // UIImage.cgImage — /shoot returns the drawn frame's CGImage

// Posey Task 13 #1 (2026-05-03), adopted here: the entire server compiles only in DEBUG
// builds. Release binaries ship no HTTP runtime, no bearer-token Keychain handling, and
// no port-bind code. The App Store never sees an open socket. Callers are guarded the
// same way.
#if DEBUG

// ==== LEGO START: 9 The Antenna (Class, Token, Address) ====

/// Local HTTP API server — lets Claude Code drive the camera directly over WiFi.
/// Default OFF; toggled from the main screen.
///
/// Port 8767. Auth via a Keychain-backed bearer token that persists across launches.
@MainActor
final class LocalAPIServer {

    static let shared = LocalAPIServer()

    static let port: UInt16 = 8767
    private var listener: NWListener?

    var isRunning: Bool { listener != nil }

    // MARK: — Keychain token

    private static let keychainService = "com.MarkFriedlander.AI-Camera"
    private static let keychainAccount = "localAPIToken"

    static func loadOrCreateToken() -> String {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: keychainService as CFString,
            kSecAttrAccount: keychainAccount as CFString,
            kSecReturnData:  true
        ]
        var item: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data,
           let token = String(data: data, encoding: .utf8) { return token }

        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let add: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: keychainService as CFString,
            kSecAttrAccount: keychainAccount as CFString,
            kSecValueData:   Data(token.utf8) as CFData
        ]
        SecItemAdd(add as CFDictionary, nil)
        return token
    }

    /// Process-lifetime cache of the bearer token. Posey's scar, inherited deliberately:
    /// this was once a computed property, which silently broke wherever the sandboxed
    /// keychain rejects `SecItemAdd` — `loadOrCreateToken()` then emits a *fresh* UUID on
    /// every access, so the startup log printed token A, the request handler computed
    /// token B, and every request 401'd. Caching at first access makes the token stable
    /// for the process regardless of whether the keychain actually persisted it.
    static let apiToken: String = loadOrCreateToken()

    // MARK: — LAN address

    static func localIPAddress() -> String {
        var best = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return best }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let iface = ptr?.pointee {
            defer { ptr = ptr?.pointee.ifa_next }
            guard iface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: iface.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(iface.ifa_addr, socklen_t(iface.ifa_addr.pointee.sa_len),
                        &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: hostname)
            if !ip.isEmpty && ip != "0.0.0.0" { best = ip }
        }
        return best
    }

    var connectionInfo: String {
        "http://\(Self.localIPAddress()):\(Self.port)  token: \(Self.apiToken)"
    }

    // MARK: — Lifecycle

    func start() {
        guard !isRunning else { return }
        do {
            // Capture before the closure to avoid crossing actor boundaries.
            let ip    = Self.localIPAddress()
            let port  = Self.port
            let token = Self.apiToken

            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)

            l.newConnectionHandler = { [weak self] conn in
                conn.start(queue: .global(qos: .userInitiated))
                Task { await self?.handleConnection(conn) }
            }
            l.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    NSLog("CameraAPI: Ready — %@:%d", ip, Int(port))
                    NSLog("CameraAPI: Token — %@", token)
                    // Posey's trick, inherited: drop the address+token at a known temp
                    // path so a host-side harness can read it without grepping the
                    // unified log (which redacts NSLog args as <private> in places).
                    // DEBUG-only file; Release ships neither the antenna nor this writer.
                    let tokenFile = NSTemporaryDirectory() + "ai-camera-api-token.txt"
                    try? "\(ip)\n\(port)\n\(token)\n".write(
                        toFile: tokenFile, atomically: true, encoding: .utf8
                    )
                case .failed(let e):
                    NSLog("CameraAPI: Failed — %@", "\(e)")
                default: break
                }
            }
            l.start(queue: .global(qos: .userInitiated))
            self.listener = l
        } catch {
            NSLog("CameraAPI: Could not start NWListener — %@", "\(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        NSLog("CameraAPI: Stopped")
    }
}

// ==== LEGO END: 9 The Antenna (Class, Token, Address) ====

// ==== LEGO START: 10 The Model Lane (Serialization + Settle) ====

/// The single lane every heavy model operation passes through, one at a time, with the
/// phone let to settle between each.
///
/// ⚠️ This exists instead of a note telling you to pace your calls.
///
/// **Mark's rule, 2026-07-16, and it is the whole design of this file:** *"we should be
/// drawing one at a time in sequence. We should also be building and tearing down the drawer
/// each time. Give it time to settle between as well just the same way we move between frames
/// or if you look at Hal between prompts. This is how we make sure that one operation has its
/// own world and all its resources from scratch."*
///
/// It started life as `LookQueue`, serializing only AFM looks (the Foundation Models SDK has
/// a `concurrentRequests` error — AFM rejects overlapping sessions outright). **That was not
/// enough, and the gap crashed the app.** Measured 2026-07-16: two draws fired at once, or a
/// draw started while the eye was still resident, jetsams the process (signal 9) — a
/// 2.7 GB diffusion load has no room to run twice. Looks were serialized; **draws were not**,
/// and neither the shutter's own looks nor either engine's draws shared a lane. So this is
/// now the lane for *everything* heavy: every look and every draw, from the shutter and from
/// the antenna alike.
///
/// Two guarantees:
///   1. **One at a time.** FIFO. A second caller queues behind the first rather than racing
///      it. The actor only protects `tail`; the serialization is the task chaining. (A bare
///      `actor` would NOT do this — actors are re-entrant across `await` and would let a
///      second op start mid-suspension, which is exactly the bug.)
///   2. **Settle between.** After each op finishes, drain the GPU, clear MLX's cache, and
///      **poll until iOS has actually reclaimed the memory** before the next op starts. Not
///      a guessed sleep — the same measured wait Hal does between model swaps
///      (`waitForMemoryHeadroom`). Every op therefore begins in a clean world: whatever ran
///      before it is not merely released but *reclaimed*.
actor ModelLane {
    static let shared = ModelLane()

    /// Completes when everything enqueued so far has finished (including its settle).
    private var tail: Task<Void, Never> = Task {}

    /// Run `work` once every previously-enqueued item has finished, then settle before the
    /// lane is handed to the next caller. FIFO.
    ///
    /// - Parameter label: names the op in the log, so the sequence reads as a story —
    ///   `look` … `settle` … `draw` … `settle` — rather than anonymous waits.
    func run<T: Sendable>(_ label: String, _ work: @Sendable @escaping () async -> T) async -> T {
        let previous = tail
        let mine = Task<T, Never> {
            await previous.value
            let result = await work()
            // The settle is part of the op, not a courtesy after it: the next caller must
            // not begin until this one's world is not just dropped but reclaimed.
            await Self.settle(after: label)
            return result
        }
        // Update the tail synchronously, before any suspension, so a second caller entering
        // `run` queues behind `mine` (and its settle) rather than racing it.
        tail = Task { _ = await mine.value }
        return await mine.value
    }

    /// Let the phone settle: drain GPU work, release MLX's cache, and wait for iOS to give
    /// the memory back, so the next operation starts from scratch.
    ///
    /// iOS reclaims Mach VM lazily. Measured 2026-07-16, the reclaim is usually fast (a Qwen
    /// teardown returned ~1.6 GB in 79 ms) — but *usually* is not *always*, and the whole
    /// point of settling is that the next 2.7 GB load never races a reclaim that hasn't
    /// finished. So this polls until availability plateaus (two reads within 50 MB) rather
    /// than trusting a fixed delay. Bounded, because a settle that never ends is worse than a
    /// settle that's a little early.
    private static func settle(after label: String) async {
        MLX.Stream.gpu.synchronize()
        MLX.Memory.clearCache()
        let start = Date()
        let deadline = start.addingTimeInterval(2.0)
        var last = processAvailableMemoryMB()
        var plateaus = 0
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 150_000_000)
            let now = processAvailableMemoryMB()
            // A plateau: the reclaim has stopped climbing. Two in a row = settled.
            if abs(now - last) < 50 {
                plateaus += 1
                if plateaus >= 2 { break }
            } else {
                plateaus = 0
            }
            last = now
        }
        cameraLog("LANE: settled after \(label) — availableMB=\(formatMB(processAvailableMemoryMB())) in \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
    }
}

// ==== LEGO END: 10 The Model Lane (Serialization + Settle) ====

// ==== LEGO START: 11 HTTP Plumbing (Parse, Respond) ====

extension LocalAPIServer {

    fileprivate struct ParsedRequest {
        let method:  String
        let path:    String
        let token:   String?
        let headers: [String: String]
        let bodyData: Data?
    }

    private func handleConnection(_ conn: NWConnection) async {
        guard let data = await receiveRequest(conn),
              let req  = parseRequest(data) else {
            respond(conn, status: 400, body: #"{"error":"Bad request"}"#)
            return
        }
        guard req.token == Self.apiToken else {
            respond(conn, status: 401, body: #"{"error":"Unauthorized"}"#)
            return
        }
        let (status, body) = await route(req)
        respond(conn, status: status, body: body)
    }

    /// Accumulates TCP chunks until the full HTTP request (headers + body) arrives.
    /// Raw `Data` throughout, so binary image bodies survive intact.
    private func receiveRequest(_ conn: NWConnection) async -> Data? {
        await withCheckedContinuation { cont in
            var buf = Data()
            let sep = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n
            var resumed = false

            func finish(_ value: Data?) {
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: value)
            }

            func next() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { chunk, _, done, err in
                    if let chunk { buf.append(chunk) }
                    if let sepRange = buf.range(of: sep) {
                        let headerData = Data(buf[..<sepRange.lowerBound])
                        if let hdrStr = String(data: headerData, encoding: .utf8),
                           let clLine = hdrStr.components(separatedBy: "\r\n")
                               .first(where: { $0.lowercased().hasPrefix("content-length:") }),
                           let cl = Int(clLine.components(separatedBy: ":")
                               .last?.trimmingCharacters(in: .whitespaces) ?? "") {
                            let received = buf.count - sepRange.upperBound
                            if received >= cl { finish(buf); return }
                        } else {
                            finish(buf); return   // no body (e.g. GET)
                        }
                    }
                    if done || err != nil {
                        finish(buf.isEmpty ? nil : buf)
                    } else { next() }
                }
            }
            next()
        }
    }

    fileprivate func parseRequest(_ data: Data) -> ParsedRequest? {
        let sep = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let sepRange = data.range(of: sep) else { return nil }

        let headerData = Data(data[..<sepRange.lowerBound])
        guard let hdrStr = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = hdrStr.components(separatedBy: "\r\n")
        guard let reqLine = lines.first else { return nil }
        let rp = reqLine.components(separatedBy: " ")
        guard rp.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let ci = line.firstIndex(of: ":") {
                let key = String(line[..<ci]).lowercased().trimmingCharacters(in: .whitespaces)
                let val = String(line[line.index(after: ci)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = val
            }
        }

        let token: String? = {
            guard let auth = headers["authorization"],
                  auth.lowercased().hasPrefix("bearer ") else { return nil }
            return String(auth.dropFirst(7))
        }()

        let bodySlice = data[sepRange.upperBound...]
        return ParsedRequest(method: rp[0], path: rp[1], token: token,
                             headers: headers,
                             bodyData: bodySlice.isEmpty ? nil : Data(bodySlice))
    }

    private func respond(_ conn: NWConnection, status: Int, body: String) {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized",
                      404: "Not Found", 500: "Internal Server Error"][status] ?? "OK"
        let bodyData = Data(body.utf8)
        let head = """
            HTTP/1.1 \(status) \(reason)\r
            Content-Type: application/json\r
            Content-Length: \(bodyData.count)\r
            Connection: close\r
            \r

            """
        conn.send(content: Data(head.utf8) + bodyData,
                  completion: .contentProcessed { _ in conn.cancel() })
    }
}

// ==== LEGO END: 11 HTTP Plumbing (Parse, Respond) ====

// ==== LEGO START: 12 Routes (Dispatch) ====

extension LocalAPIServer {

    fileprivate func route(_ req: ParsedRequest) async -> (Int, String) {
        switch (req.method, req.path) {
        case ("POST", "/look"):   return await handleLook(req)
        case ("GET",  "/state"):  return handleState()
        case ("GET",  "/models"): return handleModels()
        case ("GET",  "/rotation"): return handleRotation()
        case ("GET",  "/memory"): return await handleMemory()
        case ("POST", "/unload"): return await handleUnload()
        case ("GET",  "/disk"):      return handleDisk()
        case ("GET",  "/repo"):      return await handleRepo(req)
        case ("POST", "/download"):  return await handleDownload(req)
        case ("GET",  "/downloads"): return await handleDownloads()
        case ("POST", "/release"):   return await handleRelease(req)
        case ("POST", "/draw"):      return await handleDraw(req)
        case ("POST", "/shoot"):     return await handleShoot(req)
        case ("POST", "/press"):     return await handlePress(req)
        // ── Driving the app the way a human does: configuration + the two gestures. ──
        case ("GET",  "/settings"):        return await handleGetSettings()
        case ("POST", "/settings"):        return await handleSetSettings(req)
        case ("POST", "/zoom"):            return await handleZoom(req)
        case ("POST", "/flip"):            return await handleFlip(req)
        case ("POST", "/cancel-download"): return await handleCancelDownload(req)
        default: return (404, #"{"error":"Not found"}"#)
        }
    }

    /// POST /press — **thumbs on the phone.** Press the shutter, for real, from here.
    ///
    ///   X-Draw: true|false (optional; default true)
    ///
    /// Mark, 2026-07-16: *"You need to have thumbs on the phone. Please add whatever you need
    /// to do that."* And he is right that it was always the charter — the antenna exists so
    /// *"the API can do everything a human can do that isn't blocked by Apple security
    /// policies."* A human points the lens and presses the shutter; this is that.
    ///
    /// The difference from `/shoot` is the whole point: `/shoot` runs the pipeline on a
    /// photograph handed IN (a test file), which is how the flower got drawn — it never
    /// touched the sensor. **This captures from the live lens** (`Lens.current`, the same
    /// camera the viewfinder is showing), runs the identical `Shot` pipeline, and **saves to
    /// Photos** exactly like the button. It is indistinguishable from a real press, except
    /// that it also hands the drawing and the memory numbers back so a session can see what
    /// it took.
    ///
    /// Requires the app foregrounded with the camera on screen — otherwise there is no live
    /// lens, and it says so rather than guessing.
    private func handlePress(_ req: ParsedRequest) async -> (Int, String) {
        // The live lens, and a frame from it — on the main actor, where capture lives.
        let lens = await MainActor.run { Lens.current }
        guard let lens else {
            return (200, json([
                "pressed": false,
                "error": "No live lens. Foreground the app with the camera on screen, then press."
            ]))
        }
        guard let photograph = await lens.capture() else {
            return (200, json(["pressed": false, "error": "The lens returned no frame."]))
        }

        let seer = await MainActor.run { Settings.shared.seer }
        let drawThird = (req.headers["x-draw"] ?? "true") != "false"
        // Optional layout override, so a session can exercise every layout without reaching
        // the app's UI — the raw case name, e.g. `X-Layout: separate`. Absent → whatever the
        // app is set to.
        let layoutOverride = req.headers["x-layout"].flatMap { Layout(rawValue: $0) }

        let availBefore = processAvailableMemoryMB()
        let started = Date()

        // Returns EVERY saved frame as PNG bytes, not just the drawing — so a session can see
        // the whole triptych (reality, the words, the re-imagining), which is exactly what
        // Mark said we need to diagnose anything: *"Without being able to look at all three
        // we're gonna have some issues."*
        // ⭐ SEPARATE THE ACTIVITIES (Mark, 2026-07-16). The lane does ONLY the heavy model work
        // — see, then draw — and at the end drains the GPU and *waits for iOS to actually reclaim*
        // the models' memory (`ModelLane` settle). Everything after — compositing the frames,
        // saving, base64 — runs OUTSIDE the lane, once that memory is truly gone. That is exactly
        // how the real shutter is built (`CameraView.develop` composites outside the lane), and
        // doing it *inside* here was the bug: a ~130 MB composite landed on top of the drawer's
        // not-yet-reclaimed 2.7 GB and iOS jetsammed the app. The compositing itself is cheap and
        // model-free; it just must not race the reclaim.
        struct PressRaw: Sendable {
            let words: String
            let wordsToHand: String
            let outcome: String
            let drawn: CGImage?
        }
        let raw = await ModelLane.shared.run("press") { () -> PressRaw in
            let (perception, drawnImage, wordsForHand) = await Shot.seeThenDraw(photograph, seer: seer, drawThird: drawThird)
            return PressRaw(words: perception.wireText,
                            wordsToHand: wordsForHand,
                            outcome: perception.wireName,
                            drawn: drawnImage?.cgImage)
        }

        // ── Outside the lane: the model memory has settled. Now build, save, encode. ──
        let (toSave, layoutName): ([UIImage], String) = await MainActor.run {
            let layout = layoutOverride ?? Settings.shared.layout
            // Frame 2 per the user's setting: the full perception, or the condensed words the
            // hand drew from. See `FrameTwoWords`.
            let frameTwo = Settings.shared.frameTwoShows == .fullPerception ? raw.words : raw.wordsToHand
            // The real place, from the live `Place` (`Place.current`) — a remote press stamps the
            // GPS the way a human press does. nil only if there's no fix yet or it's denied.
            let place = Place.current?.name
            let f = Darkroom.develop(photograph: photograph,
                                     words: frameTwo,
                                     drawing: raw.drawn,
                                     place: place,
                                     layout: layout)
            return (f, layout.name)
        }
        await Shot.save(toSave)
        let framePNGs: [Data] = await MainActor.run { toSave.compactMap { $0.pngData() } }

        let seconds = Date().timeIntervalSince(started)
        let snapshot = MLX.Memory.snapshot()
        let payload: [String: Any] = [
            "pressed":           true,
            "savedToPhotos":     true,
            "seer":              seer == .qwen ? "qwen" : "afm",
            "layout":            layoutName,
            "drewThirdFrame":    raw.drawn != nil,
            // ⭐ The count that answers the "separate images" bug: how many assets landed.
            "savedCount":        framePNGs.count,
            "outcome":           raw.outcome,
            "words":             raw.words,
            // What the hand actually drew from — equals `words` unless it was condensed to fit.
            "wordsToHand":       raw.wordsToHand,
            "width":             photograph.width,
            "height":            photograph.height,
            "totalSeconds":      round(seconds * 100) / 100,
            "mlxPeakMB":         Int(Double(snapshot.peakMemory) / 1_048_576),
            "availableMBBefore": availBefore.isInfinite ? "unavailable" : Int(availBefore),
            "availableMBAfter":  processAvailableMemoryMB().isInfinite ? "unavailable" : Int(processAvailableMemoryMB()),
            // Every saved frame, in save order, base64'd. Reality → words → re-imagining.
            "frames":            framePNGs.map { $0.base64EncodedString() },
            "log":               MemoryLog.shared.recent(60)
        ]
        return (200, json(payload))
    }

    // MARK: - Driving the app the way a human does (config + the two gestures)

    /// GET /settings — the full persistent Preferences state. This is the state the LIVE shutter
    /// (`/press`) actually runs on, so a session reads it here before and after changing it.
    private func handleGetSettings() async -> (Int, String) {
        let snap = await MainActor.run { Self.readSettings() }
        return (200, json(snap.dict))
    }

    /// POST /settings — set any persistent Preference, exactly as tapping in Preferences would.
    ///
    /// This was the biggest gap in the antenna: it could override a `/shoot` call per-request but
    /// could never put the APP into a chosen state, so the live shutter could only ever run in
    /// whatever state it happened to be left in. Now a session can configure the app and then
    /// press. Body is a JSON object; every field is optional:
    ///
    ///   {"seer":"apple"|"qwen", "layout":"<rawValue>", "drawsThirdFrame":true,
    ///    "systemPrompt":"…", "temperature":0.8, "frameTwoShows":"sentToHand"|"fullPerception",
    ///    "drawingSize":"native"|"instagram"|"large", "upscaler":"metalFX"|"coreImage",
    ///    "reset":"prompt"|"everything"}
    private func handleSetSettings(_ req: ParsedRequest) async -> (Int, String) {
        guard let data = req.bodyData,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return (400, #"{"error":"POST a JSON object of settings to set"}"#)
        }
        let applied = await MainActor.run { () -> [String] in
            let s = Settings.shared
            var changed: [String] = []
            if let v = obj["seer"] as? String, let x = Seer(rawValue: v) { s.seer = x; changed.append("seer=\(v)") }
            if let v = obj["layout"] as? String, let x = Layout(rawValue: v) { s.layout = x; changed.append("layout=\(v)") }
            if let v = obj["drawsThirdFrame"] as? Bool { s.drawsThirdFrame = v; changed.append("drawsThirdFrame=\(v)") }
            if let v = obj["systemPrompt"] as? String { s.systemPrompt = v; changed.append("systemPrompt") }
            if let v = obj["temperature"] as? Double { s.temperature = v; changed.append("temperature=\(v)") }
            if let v = obj["frameTwoShows"] as? String, let x = FrameTwoWords(rawValue: v) { s.frameTwoShows = x; changed.append("frameTwoShows=\(v)") }
            if let v = obj["drawingSize"] as? String, let x = DrawingSize(rawValue: v) { s.drawingSize = x; changed.append("drawingSize=\(v)") }
            if let v = obj["upscaler"] as? String, let x = UpscaleMethod(rawValue: v) { s.upscaler = x; changed.append("upscaler=\(v)") }
            if let v = obj["decoderChoice"] as? String, let x = DecoderChoice(rawValue: v) { s.decoderChoice = x; changed.append("decoderChoice=\(v)") }
            if let v = obj["reset"] as? String {
                if v == "everything" { s.resetEverything(); changed.append("reset=everything") }
                else if v == "prompt" { s.resetPromptToDefault(); changed.append("reset=prompt") }
            }
            return changed
        }
        var payload = await MainActor.run { Self.readSettings() }.dict
        payload["applied"] = applied
        return (200, json(payload))
    }

    /// A Sendable snapshot of the persistent settings, so it can cross the `MainActor.run`
    /// boundary (a `[String: Any]` can't — `Any` isn't Sendable). `.dict` builds the JSON shape
    /// off the actor.
    private struct SettingsSnapshot: Sendable {
        let seer, layout, frameTwoShows, drawingSize, upscaler, decoderChoice, systemPrompt: String
        let drawsThirdFrame: Bool
        let temperature: Double
        var dict: [String: Any] {
            ["seer": seer, "layout": layout, "drawsThirdFrame": drawsThirdFrame,
             "temperature": temperature, "frameTwoShows": frameTwoShows,
             "drawingSize": drawingSize, "upscaler": upscaler, "decoderChoice": decoderChoice,
             "systemPrompt": systemPrompt]
        }
    }

    @MainActor
    private static func readSettings() -> SettingsSnapshot {
        let s = Settings.shared
        return SettingsSnapshot(
            seer: s.seer.rawValue, layout: s.layout.rawValue,
            frameTwoShows: s.frameTwoShows.rawValue, drawingSize: s.drawingSize.rawValue,
            upscaler: s.upscaler.rawValue, decoderChoice: s.decoderChoice.rawValue,
            systemPrompt: s.systemPrompt,
            drawsThirdFrame: s.drawsThirdFrame, temperature: s.temperature)
    }

    /// POST /zoom — drive the zoom the way a pinch does (a pinch just calls `lens.zoom`). Reports
    /// the RAW device bounds first, which is SAFE to read; then, if `X-Zoom` is given, applies it,
    /// which reads `zoomRange` and is the suspected zoom-crash site. `X-Zoom: max` pushes past the
    /// 12× cap on purpose; a number sets an absolute factor. If `deviceMin` in `bounds` ever comes
    /// back above `cap`, that alone is the bug: `zoomRange` traps on read.
    private func handleZoom(_ req: ParsedRequest) async -> (Int, String) {
        let live = await MainActor.run { Lens.current }
        guard let lens = live else {
            return (200, json(["ok": false, "error": "No live lens. Foreground the camera on screen, then zoom."]))
        }
        let bounds = await MainActor.run { lens.rawZoomBounds ?? [:] }
        if let z = req.headers["x-zoom"] {
            let factor: CGFloat
            switch z {
            case "max": factor = 999          // over the top on purpose; applyZoom clamps, or traps
            case "min": factor = 0
            default:    factor = CGFloat(Double(z) ?? 1)
            }
            // The next line reads `zoomRange`. If the range is backwards, it does not return —
            // which is exactly the diagnosis. The console/log carries the trap.
            let now = await MainActor.run { () -> Double in lens.zoom(by: factor, from: 1); return Double(lens.zoom) }
            return (200, json(["ok": true, "bounds": bounds, "requested": z, "zoom": now]))
        }
        return (200, json(["ok": true, "bounds": bounds, "zoom": bounds["current"] ?? 1]))
    }

    /// POST /flip — switch the camera the way the flip glyph does (`lens.flip`), then hand back a
    /// frame from the NEW camera so its mirroring and orientation can be eyeballed — the exact
    /// things that couldn't be judged when the selfie flip shipped compile-only. Optional
    /// `X-Camera: front|back` forces a side instead of toggling.
    private func handleFlip(_ req: ParsedRequest) async -> (Int, String) {
        let live = await MainActor.run { Lens.current }
        guard let lens = live else {
            return (200, json(["ok": false, "error": "No live lens. Foreground the camera on screen."]))
        }
        let position: String = await MainActor.run {
            if let want = req.headers["x-camera"] { lens.setCamera(front: want == "front") }
            else { lens.flip() }
            return lens.isFront ? "front" : "back"
        }
        // Let the reconfigured session settle before we capture from the new camera.
        try? await Task.sleep(for: .milliseconds(400))
        let cg = await lens.capture()
        var payload: [String: Any] = ["ok": true, "position": position]
        if let cg {
            let png = await MainActor.run { UIImage(cgImage: cg).pngData() }
            if let png {
                payload["frame"] = png.base64EncodedString()
                payload["width"] = cg.width
                payload["height"] = cg.height
            }
        }
        if payload["frame"] == nil {
            payload["note"] = "flip succeeded but the capture returned no frame (session may still be settling — try /flip again or /press)"
        }
        return (200, json(payload))
    }

    /// POST /cancel-download — cancel an in-flight download, as the Cancel button does. Keyed by
    /// `X-Repo` (the download's id, same key `/download` starts it under).
    private func handleCancelDownload(_ req: ParsedRequest) async -> (Int, String) {
        guard let repoID = req.headers["x-repo"], !repoID.isEmpty else {
            return (400, #"{"error":"Pass the repo in an X-Repo header"}"#)
        }
        await MainActor.run { MLXModelDownloader.shared.cancelDownload(modelID: repoID) }
        return (200, json(["repo": repoID, "cancelled": true]))
    }

    /// POST /shoot — the WHOLE shutter path, end to end, without Mark's thumbs.
    ///
    ///   Body:      the photograph bytes (as /look). Required.
    ///   X-Model:   afm|qwen   (optional; default = the loaded seer)
    ///   X-Draw:    true|false (optional; default true — this route exists to exercise frame 3)
    ///   X-Orientation, X-System-Prompt, X-Temperature — as /look.
    ///
    /// **Why this is not `/draw`.** `/draw` runs the drawer in isolation — no eye, no
    /// photograph resident — and it passed while the real shutter crashed. This runs the
    /// exact code a press runs (`Shot.seeThenDraw`, the same function `CameraView.develop`
    /// calls), holds the captured photograph across the draw the way the shutter does, and
    /// **builds the composited frames** so the memory in flight is the memory of a real shot.
    /// The number it reports is therefore the number that decides whether the shutter lives.
    /// It does not save to Photos — that needs a permission prompt and is not memory-relevant.
    private func handleShoot(_ req: ParsedRequest) async -> (Int, String) {
        guard let data = req.bodyData, !data.isEmpty,
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let raw = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return (400, #"{"error":"POST the photograph bytes"}"#)
        }
        let orientation: CGImagePropertyOrientation = {
            if let s = req.headers["x-orientation"], let n = UInt32(s),
               let o = CGImagePropertyOrientation(rawValue: n) { return o }
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
            let n = props?[kCGImagePropertyOrientation] as? UInt32 ?? 1
            return CGImagePropertyOrientation(rawValue: n) ?? .up
        }()
        let photograph = raw.uprighted(orientation)

        // Which eye, and whether to draw. Default to the loaded seer, drawing on.
        let seer: Seer
        switch req.headers["x-model"] {
        case "qwen":         seer = .qwen
        case "afm", "apple": seer = .apple
        default:             seer = await MainActor.run { Settings.shared.seer }
        }
        let drawThird = (req.headers["x-draw"] ?? "true") != "false"

        let availBefore = processAvailableMemoryMB()
        let started = Date()

        // The whole shot, in the lane, exactly as the shutter runs it. `run` can't throw and
        // `seeThenDraw` doesn't throw — a failed drawing comes back as `drawn == nil`.
        //
        // (X-Hand-Prompt is gone — the hand style was deactivated 2026-07-16; the hand draws the
        // eye's words, clean. See Shot / Settings.)
        let sizeOverride = req.headers["x-size"].flatMap { DrawingSize(rawValue: $0) }
        let methodOverride = req.headers["x-upscaler"].flatMap { UpscaleMethod(rawValue: $0) }
        struct ShotOut: Sendable { let words: String; let wordsToHand: String; let outcome: String; let drawn: CGImage? }
        let out = await ModelLane.shared.run("shoot") { () -> ShotOut in
            let (perception, drawnImage, wordsForHand) = await Shot.seeThenDraw(photograph, seer: seer, drawThird: drawThird, sizeOverride: sizeOverride, methodOverride: methodOverride)
            let fullWords = perception.wireText
            // Build the composited frames, so this holds the same memory a real shot holds
            // while everything is still warm — reality's receipt, the words over the world.
            let frames = await MainActor.run {
                let frameTwo = Settings.shared.frameTwoShows == .fullPerception ? fullWords : wordsForHand
                return Darkroom.develop(photograph: photograph,
                                        words: frameTwo,
                                        drawing: drawnImage?.cgImage,   // measure the composite too
                                        place: nil,   // footer text; not memory-relevant
                                        layout: Settings.shared.layout)
            }
            _ = frames.count  // held to end of scope on purpose; this is the memory under test
            return ShotOut(words: fullWords,
                           wordsToHand: wordsForHand,
                           outcome: perception.wireName,
                           drawn: drawnImage?.cgImage)
        }

        let seconds = Date().timeIntervalSince(started)
        let snapshot = MLX.Memory.snapshot()
        var payload: [String: Any] = [
            "shot":              true,
            "seer":              seer == .qwen ? "qwen" : "afm",
            "drewThirdFrame":    out.drawn != nil,
            "outcome":           out.outcome,
            "words":             out.words,
            // What the hand actually drew from — equals `words` unless it was condensed to fit.
            "wordsToHand":       out.wordsToHand,
            "totalSeconds":      round(seconds * 100) / 100,
            // ⭐ The number Mark asked for — the REAL peak, holding a photograph and the
            // composited frames the way the shutter does, not the drawer alone.
            "mlxPeakMB":         Int(Double(snapshot.peakMemory) / 1_048_576),
            "availableMBBefore": availBefore.isInfinite ? "unavailable" : Int(availBefore),
            "availableMBAfter":  processAvailableMemoryMB().isInfinite ? "unavailable" : Int(processAvailableMemoryMB()),
            "log":               MemoryLog.shared.recent(60)
        ]
        if let drawn = out.drawn, let png = try? Self.pngData(drawn) {
            payload["width"] = drawn.width
            payload["height"] = drawn.height
            payload["pngBytes"] = png.count
            payload["pngBase64"] = png.base64EncodedString()
        }
        return (200, json(payload))
    }

    /// POST /draw — frame 3, on demand. Words in, a picture out.
    ///
    ///   Body:       the prompt (UTF-8, raw). Required.
    ///   X-Steps:    4         (optional)
    ///   X-Cfg:      0         (optional)
    ///   X-Seed:     12345     (optional — fix it to compare runs)
    ///   X-Unload:   true      (optional — drop the model after, to measure the handoff)
    ///
    /// **This exists before any UI does, deliberately.** The question frame 3 asks first is
    /// not "where does the picture go on screen" — it is *does MLX draw on an iPhone at all,
    /// how long does it take, and what does it cost in memory*. Nobody on Earth has published
    /// that measurement. A route answers it tonight, repeatably, without Mark's thumbs, and
    /// the shutter path can be built on a known quantity instead of a hope.
    ///
    /// Returns the timings, the memory, and **the picture itself, base64'd into the JSON**.
    /// The antenna's `respond` only speaks JSON; rather than grow a binary path and a second
    /// route for one image, it rides in the body. A 512×512 PNG is a few hundred KB — the
    /// waste is real and the simplicity is worth more. The picture is the entire point of the
    /// route, and a measurement I can't look at is how you get a black square you believe in
    /// for five hours (HISTORY, 2026-07-15).
    private func handleDraw(_ req: ParsedRequest) async -> (Int, String) {
        guard let data = req.bodyData, !data.isEmpty,
              let prompt = String(data: data, encoding: .utf8),
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (400, #"{"error":"POST the prompt as the body"}"#)
        }

        var built = Drawing()
        if let s = req.headers["x-steps"], let v = Int(s) { built.steps = v }
        if let c = req.headers["x-cfg"], let v = Float(c) { built.cfgWeight = v }
        if let s = req.headers["x-seed"], let v = UInt64(s) { built.seed = v }
        // Frozen to a `let` before the lane closure captures it — a captured `var` is a
        // warning today and an error under Swift 6, and this file treats warnings as errors.
        let drawing = built

        // Which developer: `X-Decoder: fast|detailed` forces one for the test; absent → the live
        // setting. Lets the antenna exercise both decode paths (and the memory fallback) directly.
        let decoderOverride = req.headers["x-decoder"].flatMap { DecoderChoice(rawValue: $0) }
        let decoderPreference: DecoderChoice
        if let o = decoderOverride {
            decoderPreference = o
        } else {
            decoderPreference = await MainActor.run { Settings.shared.decoderChoice }
        }

        let availableBefore = processAvailableMemoryMB()
        let started = Date()
        // Through the lane, exactly like a look: one at a time, torn down, settled after.
        // Two `/draw` calls fired at once used to jetsam the process (measured 2026-07-16);
        // now the second waits for the first to finish AND for the phone to reclaim.
        // `run` can't throw, so the throw is captured as a Sendable outcome and rethrown
        // here, preserving the existing do/catch.
        struct DrawOutcome: Sendable { let image: CGImage?; let error: String? }
        let outcome = await ModelLane.shared.run("draw") { () -> DrawOutcome in
            do { return DrawOutcome(image: try await DrawerLoader.shared.draw(drawing, prompt: prompt, decoderPreference: decoderPreference), error: nil) }
            catch { return DrawOutcome(image: nil, error: error.localizedDescription) }
        }
        do {
            guard let image = outcome.image else {
                throw DrawingError.drawFailed(outcome.error ?? "unknown error")
            }
            let seconds = Date().timeIntervalSince(started)

            let png = try Self.pngData(image)
            let snapshot = MLX.Memory.snapshot()
            var payload: [String: Any] = [
                "drew":          true,
                "prompt":        prompt,
                "steps":         drawing.steps,
                "cfgWeight":     drawing.cfgWeight,
                "seed":          drawing.seed.map(String.init) ?? "random",
                "width":         image.width,
                "height":        image.height,
                "totalSeconds":  round(seconds * 100) / 100,
                "secondsPerStep": round(seconds / Double(max(drawing.steps, 1)) * 100) / 100,
                // ⭐ The fork. Draw Things does SD in ~2 GB on a phone; that is the number
                // this is measured against, not a speed.
                "mlxPeakMB":     Int(Double(snapshot.peakMemory) / 1_048_576),
                "mlxActiveMB":   Int(Double(snapshot.activeMemory) / 1_048_576),
                "availableMBBefore": availableBefore.isInfinite ? "unavailable" : Int(availableBefore),
                "availableMBAfter":  processAvailableMemoryMB().isInfinite ? "unavailable" : Int(processAvailableMemoryMB()),
                "pngBytes":      png.count,
                "pngBase64":     png.base64EncodedString()
            ]
            if (req.headers["x-unload"] ?? "false") == "true" {
                await DrawerLoader.shared.unload()
                payload["unloadedAfter"] = true
                payload["availableMBAfterUnload"] = processAvailableMemoryMB().isInfinite
                    ? "unavailable" : Int(processAvailableMemoryMB())
            }
            payload["log"] = MemoryLog.shared.recent(40)
            return (200, json(payload))
        } catch {
            // A refusal is data. Report it rather than swallowing it into a 500.
            return (200, json([
                "drew":  false,
                "error": error.localizedDescription,
                "secondsBeforeFailing": round(Date().timeIntervalSince(started) * 100) / 100,
                "availableMB": processAvailableMemoryMB().isInfinite
                    ? "unavailable" : Int(processAvailableMemoryMB()),
                "log":   MemoryLog.shared.recent(40)
            ]))
        }
    }

    private static func pngData(_ image: CGImage) throws -> Data {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out as CFMutableData, "public.png" as CFString, 1, nil) else {
            throw DrawingError.producedNothing
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw DrawingError.producedNothing }
        return out as Data
    }

    /// GET /disk — how much room is actually on the phone, and what the family is using.
    ///
    /// Added 2026-07-15 at Mark's instruction — *"add whatever tools you need to the
    /// antenna"* — in answer to CC asking him how much free space the phone had. The right
    /// response to a question about a measurable fact is an instrument, not a question.
    ///
    /// **Three numbers, on purpose, because they disagree and the disagreement is the
    /// point.** iOS does not have one idea of "free":
    ///
    ///   - `importantUsageMB` — `volumeAvailableCapacityForImportantUsage`. What iOS will
    ///     actually *give* us for something that matters, **including space it would purge
    ///     on our behalf** (other apps' evictable caches). This is the honest
    ///     "can I download a 2.4 GB model" number, and it is the one the downloader's own
    ///     pre-flight uses.
    ///   - `freeMB` — `volumeAvailableCapacity`. Raw unallocated bytes right now. Always
    ///     smaller. This is closest to what Settings shows.
    ///   - `totalMB` — the volume's size.
    ///
    /// Report all three rather than picking one, because a single number here is exactly
    /// the kind of thing that gets quoted later without its definition. NEXT.md says
    /// "~7 GB free" and does not say which of these it means.
    private func handleDisk() -> (Int, String) {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
            .volumeTotalCapacityKey
        ]
        let v = try? url.resourceValues(forKeys: keys)

        func mb(_ bytes: Int64?) -> Any { bytes.map { Int($0 / 1_048_576) } ?? "unavailable" }

        let repos = SharedModelStore.installedRepos()
        let storeBytes = repos.reduce(Int64(0)) { $0 + SharedModelStore.sizeOnDisk($1) }

        return (200, json([
            "importantUsageMB": mb(v?.volumeAvailableCapacityForImportantUsage),
            "freeMB":           mb(v?.volumeAvailableCapacity.map(Int64.init)),
            "totalMB":          mb(v?.volumeTotalCapacity.map(Int64.init)),
            // What the family is holding, so "where did the disk go" is answerable without
            // a cable. The store is invisible from outside the App Group.
            "storeBytes":       storeBytes,
            "storeMB":          Int(storeBytes / 1_048_576),
            "storeRoot":        SharedModelStore.root.path,
            "models":           repos.map { repo in
                [
                    "repo":      repo,
                    "sizeBytes": SharedModelStore.sizeOnDisk(repo),
                    "sizeMB":    Int(SharedModelStore.sizeOnDisk(repo) / 1_048_576),
                    "claimedBy": SharedModelStore.claimants(modelID: repo)
                ]
            }
        ]))
    }

    /// GET /repo?id=<repo-id> — ask HuggingFace what a repo weighs, **as this app would
    /// fetch it**, before fetching it.
    ///
    /// This is the instrument for the question NEXT.md left open and told us not to guess
    /// at: *"⚠️ Download size UNKNOWN. HuggingFace returned 401 to every attempt to read
    /// SD 2.1 base's file sizes. Don't quote a number — measure it."*
    ///
    /// **Why it lives on the phone rather than in a script on the Mac:** the number that
    /// matters is not "what does this repo contain," it's "what would *our downloader*
    /// pull." Those differ enormously for diffusion repos, which ship the same weights at
    /// several precisions — `matchesMLXPattern` takes every `.safetensors`, so a repo
    /// advertising a 2.4 GB model can cost 12 GB. Asking from inside the app, through the
    /// same filter, is the only version of this question that can't lie.
    ///
    /// `totalMatchedBytes` is therefore the real download. `files` is the itemization, so
    /// a human can see *what* the filter dragged in.
    private func handleRepo(_ req: ParsedRequest) async -> (Int, String) {
        guard let repoID = req.headers["x-repo"], !repoID.isEmpty else {
            return (400, #"{"error":"Pass the repo in an X-Repo header, e.g. X-Repo: stabilityai/sd-turbo"}"#)
        }
        guard let url = URL(string: "https://huggingface.co/api/models/\(repoID)/tree/main?recursive=1") else {
            return (400, json(["error": "Bad repo id: \(repoID)"]))
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 25

        struct TreeEntry: Decodable {
            let type: String
            let path: String
            let size: Int64?
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else {
                // A non-200 is a finding, not a failure — 401 is how HuggingFace reports a
                // repo that has been withdrawn or made private, and that is exactly what
                // happened to SD 2.x. Report it as data.
                return (200, json([
                    "repo":       repoID,
                    "httpStatus": status,
                    "reachable":  false,
                    "body":       String(data: data, encoding: .utf8) ?? ""
                ]))
            }
            let entries = try JSONDecoder().decode([TreeEntry].self, from: data)
            let fileEntries = entries.filter { $0.type == "file" }
            let matched = fileEntries.filter { MLXModelDownloader.matchesDownloadPattern($0.path) }
            let matchedBytes = matched.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
            let allBytes = fileEntries.reduce(Int64(0)) { $0 + ($1.size ?? 0) }

            return (200, json([
                "repo":              repoID,
                "httpStatus":        status,
                "reachable":         true,
                "fileCount":         fileEntries.count,
                "matchedFileCount":  matched.count,
                // The number that decides whether this fits on the phone.
                "totalMatchedBytes": matchedBytes,
                "totalMatchedMB":    Int(matchedBytes / 1_048_576),
                "totalMatchedGB":    (Double(matchedBytes) / 1_073_741_824 * 100).rounded() / 100,
                // Everything in the repo, for contrast — the gap between these two is the
                // filter doing its job (or failing to).
                "totalRepoBytes":    allBytes,
                "totalRepoGB":       (Double(allBytes) / 1_073_741_824 * 100).rounded() / 100,
                "files":             matched
                    .sorted { ($0.size ?? 0) > ($1.size ?? 0) }
                    .map { ["path": $0.path, "sizeBytes": $0.size ?? 0] }
            ]))
        } catch {
            return (200, json([
                "repo":      repoID,
                "reachable": false,
                "error":     error.localizedDescription
            ]))
        }
    }

    /// POST /download — pull a model onto the phone, without Mark's thumbs.
    ///
    ///   X-Repo:    mlx-community/Qwen3.5-2B-MLX-4bit    (required)
    ///   X-Size-GB: 1.75                                  (optional — measured if absent)
    ///   X-Force:   true                                  (optional — skip the fit check)
    ///
    /// Mark's standing directive is that the API does everything a human can. A human taps
    /// Download in Preferences; this is that, repeatably, from a harness.
    ///
    /// **This route also closes a hole the port left open, and the hole is worth naming.**
    /// Hal reads a model's size from its curated catalog and hands it to `startDownload`.
    /// AI Camera has no catalog — it has repo ids — and the port replaced the catalog
    /// lookup with a display name and nothing else. But the downloader's pre-flight refuses
    /// outright when `sizeGB` is nil (*"this model's size couldn't be determined"*). So as
    /// ported, **AI Camera's downloader could never have downloaded anything**: it would
    /// have refused every call. It compiled, which is why nobody saw it. Here the size is
    /// *measured* from HuggingFace instead of declared from a catalog — which is the same
    /// move `ProcessMemoryGuard` makes, and for the same reason: this app adopts rather
    /// than orders, so it can look rather than assume.
    private func handleDownload(_ req: ParsedRequest) async -> (Int, String) {
        guard let repoID = req.headers["x-repo"], !repoID.isEmpty else {
            return (400, #"{"error":"Pass the repo in an X-Repo header"}"#)
        }

        if SharedModelStore.isRepoDownloaded(repoID) {
            return (200, json([
                "repo":     repoID,
                "started":  false,
                "message":  "Already in the shared store.",
                "sizeBytes": SharedModelStore.sizeOnDisk(repoID)
            ]))
        }

        // If the camera knows this model, take the catalog's terms — the same size and the
        // same file allowlist the Download button in the library would use. The antenna
        // must exercise the path a human exercises, not a parallel one that could pass
        // while the real one is broken. That is the whole point of the directive it exists
        // to serve.
        let known = ModelCatalog.model(id: repoID)

        // Size: caller's figure, else the catalog's, else measured from the repo through
        // the same filter the downloader will apply. Never assumed.
        var sizeGB: Double? = req.headers["x-size-gb"].flatMap(Double.init) ?? known?.sizeGB
        var measured = false
        if sizeGB == nil {
            if let bytes = await Self.measureRepoBytes(repoID) {
                sizeGB = Double(bytes) / 1_073_741_824
                measured = true
            }
        }
        guard let sizeGB else {
            return (200, json([
                "repo":    repoID,
                "started": false,
                "error":   "Couldn't measure \(repoID) from HuggingFace, and no X-Size-GB was given. Refusing rather than starting a download that can't be size-checked."
            ]))
        }

        // Fit check before we start. The downloader has its own pre-flight and will refuse
        // too — this one exists to give the *harness* a structured answer instead of a
        // prose error buried in a download state.
        let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let availBytes = (try? cachesURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        let needBytes = Int64(sizeGB * 1.3 * 1_073_741_824)
        let force = (req.headers["x-force"] ?? "false") == "true"
        if !force, let availBytes, availBytes < needBytes {
            return (200, json([
                "repo":            repoID,
                "started":         false,
                "measured":        measured,
                "sizeGB":          (sizeGB * 100).rounded() / 100,
                "needBytes":       needBytes,
                "availableBytes":  availBytes,
                "error":           "Won't fit: needs ~\(Int(Double(needBytes) / 1_073_741_824 * 10) / 10) GB with margin, \(Int(Double(availBytes) / 1_073_741_824 * 10) / 10) GB available. Pass X-Force: true to try anyway."
            ]))
        }

        cameraLog("DOWNLOAD: antenna starting \(repoID) sizeGB=\(sizeGB) measured=\(measured) allowlist=\(known?.fileAllowlist?.count.description ?? "none")")
        // Fire and return. A multi-GB download does not finish inside an HTTP request —
        // poll GET /downloads.
        Task {
            await MLXModelDownloader.shared.startDownload(
                modelID: repoID, repoID: repoID, sizeGB: sizeGB, files: known?.fileAllowlist)
        }

        return (200, json([
            "repo":     repoID,
            "started":  true,
            "measured": measured,
            "inCatalog": known != nil,
            "fileCount": known?.fileAllowlist?.count ?? 0,
            "sizeGB":   (sizeGB * 100).rounded() / 100,
            "message":  "Started. Poll GET /downloads."
        ]))
    }

    /// Total bytes of the files our downloader would actually take from a repo.
    ///
    /// Deliberately applies `matchesDownloadPattern` rather than summing the repo: a
    /// diffusion repo carries the same weights at several precisions, so the repo total and
    /// the download are different numbers and only one of them is ours.
    private static func measureRepoBytes(_ repoID: String) async -> Int64? {
        guard let url = URL(string: "https://huggingface.co/api/models/\(repoID)/tree/main?recursive=1")
        else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        struct TreeEntry: Decodable { let type: String; let path: String; let size: Int64? }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let entries = try? JSONDecoder().decode([TreeEntry].self, from: data)
        else { return nil }
        return entries
            .filter { $0.type == "file" && MLXModelDownloader.matchesDownloadPattern($0.path) }
            .reduce(Int64(0)) { $0 + ($1.size ?? 0) }
    }

    /// GET /downloads — what's in flight, and how far along.
    ///
    /// The downloader's progress lives in `@Published` state a SwiftUI view reads. Without
    /// this route a harness can only watch the disk grow and guess; with it, a download is
    /// observable the way a look already is.
    private func handleDownloads() async -> (Int, String) {
        let states = await MainActor.run { MLXModelDownloader.shared.downloadStates }
        let entries: [[String: Any]] = states.map { id, s in
            var e: [String: Any] = [
                "repo":        id,
                "isDownloading": s.isDownloading,
                "progress":    (s.progress * 1000).rounded() / 1000,
                "message":     s.message
            ]
            if let err = s.error { e["error"] = err }
            if let p = s.localPath { e["localPath"] = p.path }
            e["onDisk"] = SharedModelStore.isRepoDownloaded(id)
            e["sizeBytes"] = SharedModelStore.sizeOnDisk(id)
            return e
        }
        let anyActive = states.values.contains { $0.isDownloading }
        return (200, json([
            "anyActive": anyActive,
            "downloads": entries.sorted { ($0["repo"] as! String) < ($1["repo"] as! String) },
            "log":       MemoryLog.shared.recent(60)
        ]))
    }

    /// POST /release — give up this app's claim on a model, deleting it only if we were the
    /// last app holding it.
    ///
    ///   X-Repo: stabilityai/sd-turbo   (required)
    ///
    /// **Mark's semantics, verbatim (2026-07-15):** *"All the apps should share the same
    /// repository of models. Deleting a model from an app does not delete it from the
    /// repository. Deleting it from the last remaining app to have it in use deletes it
    /// from the repository."* This route is that sentence and nothing more.
    ///
    /// Needed because frame 3 means pulling multi-GB models onto a phone with single-digit
    /// gigabytes free, and NEXT.md's plan is explicit: *"Run the engines one at a time and
    /// delete between."* Doing that by hand, per model, per test, is exactly the kind of
    /// thumb-work the antenna exists to remove.
    ///
    /// ⚠️ **This route deletes files, so it is built the careful way, and the reason is in
    /// this repo's own history.** Hal's `clearHubCache()` did `removeItem` on the *shared*
    /// container and took out every model of every app. The fix Hal's CC landed — after
    /// catching a quieter version of the same bug in AI Camera CC's suggested fix — was to
    /// **ask the ledger what we own rather than infer it from what we can see**, because
    /// `releaseClaim` returns `true` for a model with no manifest entry at all, so a model
    /// a sibling downloaded and we never adopted would look unclaimed and get destroyed.
    /// So: refuse anything not in `modelsClaimedByThisApp()`, and delete only where
    /// `releaseClaim` says we were last. Per-model. Never a bulk wipe.
    private func handleRelease(_ req: ParsedRequest) async -> (Int, String) {
        guard let repoID = req.headers["x-repo"], !repoID.isEmpty else {
            return (400, #"{"error":"Pass the repo in an X-Repo header"}"#)
        }

        // The ledger, not the disk. See the note above — this guard IS the bug fix.
        let ours = SharedModelStore.modelsClaimedByThisApp()
        guard ours.contains(repoID) else {
            return (200, json([
                "repo":     repoID,
                "released": false,
                "deleted":  false,
                "claimedByThisApp": false,
                "claimants": SharedModelStore.claimants(modelID: repoID),
                "message":  "AI Camera has no claim on \(repoID). Refusing — a model this app never adopted is not this app's to delete."
            ]))
        }

        // If we're about to delete the model, make sure we aren't holding it open.
        if repoID == Qwen.repo, await QwenLoader.shared.isLoaded {
            await QwenLoader.shared.unload()
            cameraLog("RELEASE: unloaded \(repoID) before releasing its claim")
        }

        let sizeBefore = SharedModelStore.sizeOnDisk(repoID)
        let wasLast = SharedModelStore.releaseClaim(modelID: repoID)
        var deleted = false
        var deleteError: String?

        if wasLast {
            let dir = SharedModelStore.mlxModelDir(repoID)
            do {
                if FileManager.default.fileExists(atPath: dir.path) {
                    try FileManager.default.removeItem(at: dir)
                    deleted = true
                    cameraLog("RELEASE: last claimant — deleted \(repoID) (\(sizeBefore) bytes)")
                }
            } catch {
                deleteError = error.localizedDescription
                cameraLog("RELEASE: delete FAILED for \(repoID): \(error.localizedDescription)")
            }
        } else {
            cameraLog("RELEASE: released claim on \(repoID); siblings still hold it — kept on disk")
        }

        var payload: [String: Any] = [
            "repo":             repoID,
            "released":         true,
            "claimedByThisApp": true,
            "wasLastClaimant":  wasLast,
            "deleted":          deleted,
            "freedBytes":       deleted ? sizeBefore : 0,
            "remainingClaimants": SharedModelStore.claimants(modelID: repoID)
        ]
        if let deleteError { payload["error"] = deleteError }
        return (200, json(payload))
    }

    /// GET /memory — what the process is holding, and the reclamation curve.
    ///
    /// The instrument for the thing nobody could see. iOS reclaims Mach VM lazily, so
    /// "did the unload work?" is not answerable by reading the code — only by watching
    /// `availableMB` climb over the seconds after a release. That curve decides whether
    /// Mark's three-frame design (capture → words → drawing, each torn down before the
    /// next loads) is survivable, and it is the number that will decide frame 3.
    ///
    /// Serves the log ring too, so a sweep can capture the poll lines without a cable.
    private func handleMemory() async -> (Int, String) {
        let snapshot = MLX.Memory.snapshot()
        let resident = await QwenLoader.shared.isLoaded
        return (200, json([
            // iOS's view — the one that decides whether we get killed.
            "availableMB":  processAvailableMemoryMB().isInfinite
                ? "unavailable" : Int(processAvailableMemoryMB()),
            // MLX's view — the bytes IT thinks it holds. The two disagree on purpose.
            "mlxActiveMB":  Int(Double(snapshot.activeMemory) / 1_048_576.0),
            "mlxCacheMB":   Int(Double(snapshot.cacheMemory) / 1_048_576.0),
            "mlxPeakMB":    Int(Double(snapshot.peakMemory) / 1_048_576.0),
            "qwenResident": resident,
            "qwenRequiredMB": Int(requiredMemoryMBForLoad(repo: Qwen.repo)),
            "log":          MemoryLog.shared.recent(200)
        ]))
    }

    /// POST /unload — drop the eye on demand.
    ///
    /// Mark's standing directive: the API must do everything a human can that Apple's
    /// security policy doesn't block. A human can background the app to force an unload;
    /// this is that, without his thumbs — and it's what lets a harness measure the
    /// reclamation curve repeatedly instead of once.
    private func handleUnload() async -> (Int, String) {
        let before = processAvailableMemoryMB()
        await QwenLoader.shared.unload()
        let after = processAvailableMemoryMB()
        return (200, json([
            "unloaded":       true,
            "availableMBBefore": before.isInfinite ? "unavailable" : Int(before),
            "availableMBAfter":  after.isInfinite ? "unavailable" : Int(after),
            // ⭐ MEASURED 2026-07-15, and it refutes the prediction this line used to carry.
            //
            // This comment said: *"Expect this to be ~0 immediately. That is the lazy-reclaim
            // point, not a failure — poll GET /memory and watch it climb."* That was written
            // the night the instrument was built and before it was ever run. The first run
            // said otherwise:
            //
            //     22:26:14.570  unload ENTRY  active=1642 MB  iosAvail=4362
            //     22:26:14.649  unload EXIT   active=0 MB     iosAvail=6026  | Δ=1664
            //
            // **1,664 MB back in 79 milliseconds** — 93% of what Qwen cost, immediately, not
            // lazily. The lazy-reclaim story is about clean mmap'd pages, which don't count
            // against the dirty-memory limit anyway; MLX's Metal buffers are dirty and freeing
            // them is a real free. So expect this delta to be LARGE and prompt.
            //
            // Which means the handoff at the heart of Mark's three-frame design — tear down
            // frame 2, load frame 3 — is cheap, and `waitForMemoryHeadroom` is a belt to
            // `unload()`'s braces rather than the load-bearing part. Keep the poll (it costs
            // nothing and other workloads may behave differently), but do not design around a
            // slow curve that isn't there. The instrument beat the guess, again.
            "deltaMB":        (before.isInfinite || after.isInfinite) ? "unavailable" : Int(after - before)
        ]))
    }

    /// GET /rotation — the live rotation state of the lens.
    ///
    /// Exists because CC guessed at an orientation bug three times and made it worse
    /// twice. The angles are knowable; read them.
    private func handleRotation() -> (Int, String) {
        guard let lens = Lens.current else {
            return (503, #"{"error":"No lens on screen"}"#)
        }
        return (200, json(lens.diagnostics))
    }

    /// GET /models — what's in the family's shared store, and who claims it.
    ///
    /// This route exists because the store is otherwise invisible from outside: an App
    /// Group container can't be enumerated over `devicectl` by a process that isn't in
    /// the group. Rather than guess at what Hal and Posey have downloaded, we ask the
    /// app, which can actually see it.
    private func handleModels() -> (Int, String) {
        let repos = SharedModelStore.installedRepos()
        let entries: [[String: Any]] = repos.map { repo in
            [
                "repo":       repo,
                "sizeBytes":  SharedModelStore.sizeOnDisk(repo),
                "claimedBy":  SharedModelStore.claimants(modelID: repo)
            ]
        }
        return (200, json([
            // If this is false the entitlement didn't take and we're looking at our own
            // Caches — which looks identical and shares nothing.
            "sharing":  SharedModelStore.isSharing,
            "appGroup": SharedModelStore.appGroupID,
            "root":     SharedModelStore.root.path,
            "thisApp":  SharedModelStore.thisAppID,
            "models":   entries
        ]))
    }

    /// GET /state — what the machine is, and how it's currently set to look.
    private func handleState() -> (Int, String) {
        let readiness = Readiness.current
        let eye = Eye.plain
        return (200, json([
            "ready":        readiness.isReady,
            "readiness":    readiness.wireName,
            "explanation":  readiness.explanation,
            "port":         Int(Self.port),
            "defaultEye": [
                "systemPrompt": eye.systemPrompt,
                "temperature":  eye.temperature,
                "guardrails":   "default"
            ]
        ]))
    }

    /// POST /look — raw image bytes in, a Perception out.
    ///
    /// The body is the image and nothing but the image (same shape as Posey's /import),
    /// so configuration rides in headers:
    ///
    ///   X-Model:         afm|qwen         (optional; default afm)
    ///   X-System-Prompt: <base64 UTF-8>   (optional; base64 because prompts have newlines)
    ///   X-Temperature:   0.9              (optional)
    ///   X-Guardrails:    default|permissive   (optional; AFM only — Qwen has no filter)
    ///   X-Orientation:   1...8            (optional; otherwise read from the file's EXIF)
    ///
    /// Every look goes through ModelLane, so a caller may fire as fast as it likes — the
    /// lane serializes and settles between.
    private func handleLook(_ req: ParsedRequest) async -> (Int, String) {
        guard let data = req.bodyData, !data.isEmpty else {
            return (400, #"{"error":"Empty body — POST the image bytes"}"#)
        }

        // Decode via ImageIO rather than UIImage: it hands us the CGImage *and* the
        // file's own EXIF orientation, so the orientation trap is closed at the source
        // instead of being guessed at.
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let rawImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return (400, #"{"error":"Could not decode that image"}"#)
        }

        let declaredOrientation: CGImagePropertyOrientation = {
            if let raw = req.headers["x-orientation"], let n = UInt32(raw),
               let o = CGImagePropertyOrientation(rawValue: n) { return o }
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
            let raw = props?[kCGImagePropertyOrientation] as? UInt32 ?? 1
            return CGImagePropertyOrientation(rawValue: raw) ?? .up
        }()
        // The antenna's door. Same rule as the shutter: rotate now, so nothing
        // downstream carries an orientation it could forget to apply.
        let cgImage = rawImage.uprighted(declaredOrientation)

        var eye = Eye.plain
        if let b64 = req.headers["x-system-prompt"],
           let d = Data(base64Encoded: b64),
           let prompt = String(data: d, encoding: .utf8) {
            eye.systemPrompt = prompt
        }
        if let t = req.headers["x-temperature"], let v = Double(t) {
            eye.temperature = v
        }
        let guardrailName = req.headers["x-guardrails"] ?? "default"
        if guardrailName == "permissive" {
            eye.guardrails = .permissiveContentTransformations
        }

        // The second eye. Same prompt, same temperature, different machine — so the only
        // variable is the model itself. Guardrails and retry don't apply: Qwen has no
        // filter to get past.
        let modelName = req.headers["x-model"] ?? "afm"
        if modelName == "qwen" {
            let qwen = Qwen(systemPrompt: eye.systemPrompt, temperature: eye.temperature)
            let started = Date()
            let perception = await ModelLane.shared.run("look:qwen") {
                await qwen.look(at: cgImage)
            }
            let now = Date()
            var payload: [String: Any] = [
                "model":        "qwen",
                "repo":         Qwen.repo,
                "outcome":      perception.wireName,
                "text":         perception.wireText,
                "rescued":      false,
                "width":        cgImage.width,
                "height":       cgImage.height,
                "orientation":  Int(declaredOrientation.rawValue),
                "guardrails":   "none",
                "temperature":  eye.temperature,
                "lookSeconds":  round(now.timeIntervalSince(started) * 1000) / 1000,
                "totalSeconds": round(now.timeIntervalSince(started) * 1000) / 1000
            ]
            payload["modelLoaded"] = await QwenLoader.shared.isLoaded
            return (200, json(payload))
        }

        // Retry-on-block is on by default (matching the app); `X-Retry-On-Block: false`
        // turns it off, which is what a characterization sweep wants when it's measuring
        // the raw guardrail rather than the shipping behavior.
        let retryOnBlock = (req.headers["x-retry-on-block"] ?? "true") != "false"

        let frozen = eye
        let started = Date()
        // The whole AFM look — the pre-flight token count AND the look itself — as ONE lane
        // op, so it never overlaps another look or a draw, and settles once when done rather
        // than twice. `lookSeconds` (the look alone) is measured inside; see `AFMLook`.
        struct AFMLook: Sendable { let price: Int?; let look: Look; let lookSeconds: Double }
        let afm = await ModelLane.shared.run("look:afm") { () -> AFMLook in
            let price = await frozen.priceOfLooking(at: cgImage)
            let lookStarted = Date()
            let look = await frozen.lookWithRetry(at: cgImage, retryOnBlock: retryOnBlock)
            return AFMLook(price: price, look: look, lookSeconds: Date().timeIntervalSince(lookStarted))
        }
        let price = afm.price
        let result = afm.look
        let now = Date()

        let shown = result.best
        var payload: [String: Any] = [
            "model":         "afm",
            "outcome":       shown.wireName,
            "text":          shown.wireText,
            "rescued":       result.wasRescued,
            "width":         cgImage.width,
            "height":        cgImage.height,
            "orientation":   Int(declaredOrientation.rawValue),
            "guardrails":    result.retry != nil ? "permissive (retry)" : guardrailName,
            "temperature":   frozen.temperature,
            // Measured separately, unlike the UI's single stopwatch: `lookSeconds` is the
            // look alone (timed inside the lane op), `totalSeconds` includes the pre-flight
            // token count and the lane settle.
            "lookSeconds":   round(afm.lookSeconds * 1000) / 1000,
            "totalSeconds":  round(now.timeIntervalSince(started) * 1000) / 1000
        ]
        if let price { payload["tokensToLook"] = price }
        if case .spoke(_, let tokens) = shown, let tokens { payload["tokensTotal"] = tokens }

        // The block is kept alongside the rescue, never replaced by it. Both are true and
        // both are content — the form letter AND what the machine said once it was
        // finally allowed to look.
        if case .blocked(let explanation, let metadata) = result.first {
            payload["blocked"] = ["text": explanation, "metadata": metadata]
        }

        return (200, json(payload))
    }

    private func json(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict,
                                                     options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return #"{"error":"Could not encode response"}"#
        }
        return str
    }
}

// MARK: — Wire names
//
// Kept next to the routes rather than on the types themselves: these strings are an API
// contract (a script parses them), not part of how the app thinks about a Perception.
// Principle 3 note — `refused` and `blocked` are reported as *outcomes*, not errors, so
// a harness can count them as findings rather than throw them away as failures.

extension Perception {
    // `nonisolated` (both) — pure switches over a nonisolated enum, read from off-main
    // contexts like the ModelLane closure in /shoot. Without it the project's default
    // MainActor isolation makes them main-only and every off-main read warns.
    nonisolated var wireName: String {
        switch self {
        case .spoke:   return "spoke"
        case .refused: return "refused"
        case .blocked: return "blocked"
        case .broke:   return "broke"
        }
    }
    nonisolated var wireText: String {
        switch self {
        case .spoke(let text, _):          return text
        case .refused(let explanation):    return explanation
        case .blocked(let explanation, _): return explanation
        case .broke(let reason):           return reason
        }
    }
}

extension Readiness {
    var wireName: String {
        switch self {
        case .ready:                       return "ready"
        case .deviceNotEligible:           return "deviceNotEligible"
        case .appleIntelligenceNotEnabled: return "appleIntelligenceNotEnabled"
        case .modelNotReady:               return "modelNotReady"
        case .unavailable:                 return "unavailable"
        }
    }
}

// ==== LEGO END: 12 Routes (Dispatch) ====

#endif
