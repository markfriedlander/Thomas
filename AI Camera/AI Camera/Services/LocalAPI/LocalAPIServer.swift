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
import Network
import Security
import CoreGraphics
import ImageIO

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

// ==== LEGO START: 10 The Look Queue (Serialization) ====

/// Serializes looks so that two never overlap.
///
/// ⚠️ This exists instead of a note telling you to pace your calls.
///
/// Two facts made it necessary. First, the Foundation Models SDK has a
/// `concurrentRequests` error case — AFM rejects overlapping sessions outright. Second,
/// the family's antennas have historically destabilized under rapid back-to-back calls;
/// `posey_test.py` carries the warning *"leave a short gap (~1s) between calls."* Mark's
/// call on 2026-07-14: **fix it in the code rather than in behavior, because instances
/// forget constraints over time.** A rule written in a doc has to be remembered by every
/// future session. A rule written here cannot be forgotten, because overlapping looks
/// are simply unreachable.
///
/// Note this is NOT a bare actor. Actors are re-entrant across `await`: a plain
/// `actor { func look() async }` would happily suspend mid-look and let a second look
/// start, which is precisely the bug we're preventing. Serialization comes from chaining
/// each new task behind the previous one's completion; the actor only protects `tail`.
actor LookQueue {
    static let shared = LookQueue()

    /// Completes when everything enqueued so far has finished.
    private var tail: Task<Void, Never> = Task {}

    /// Run `work` once every previously-enqueued item has finished. FIFO.
    func run<T: Sendable>(_ work: @Sendable @escaping () async -> T) async -> T {
        let previous = tail
        let mine = Task<T, Never> {
            await previous.value
            return await work()
        }
        // Update the tail synchronously, before any suspension, so a second caller
        // entering `run` queues behind `mine` rather than racing it.
        tail = Task { _ = await mine.value }
        return await mine.value
    }
}

// ==== LEGO END: 10 The Look Queue (Serialization) ====

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
        default: return (404, #"{"error":"Not found"}"#)
        }
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
    /// Every look goes through LookQueue, so a caller may fire as fast as it likes.
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
            let perception = await LookQueue.shared.run {
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
        // Serialized: overlapping looks are unreachable. See LookQueue.
        let price = await LookQueue.shared.run { await frozen.priceOfLooking(at: cgImage) }
        let lookStarted = Date()
        let result = await LookQueue.shared.run {
            await frozen.lookWithRetry(at: cgImage, retryOnBlock: retryOnBlock)
        }
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
            // look alone, `totalSeconds` includes the pre-flight token count.
            "lookSeconds":   round(now.timeIntervalSince(lookStarted) * 1000) / 1000,
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
    var wireName: String {
        switch self {
        case .spoke:   return "spoke"
        case .refused: return "refused"
        case .blocked: return "blocked"
        case .broke:   return "broke"
        }
    }
    var wireText: String {
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
