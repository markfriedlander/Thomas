//
//  ThomasAuditTests.swift: Apple's accessibility audit, and a walk of the accessibility tree, on Thomas's screens.
//
//  Modeled on Hal 4's HalWalkTests (Hal4/Hal4/Hal4UITests), at Mark's direction (2026-11-15: "isn't there an automated
//  checker for this that Apple has? I think we're using one for Hal").
//
//  TWO WAYS IN:
//  - testAuditByTaps (the audit of record). Mark, 2026-11-15: any navigation a test does must take the same path a
//    person does, in code and in the interface, so the issues found are the ones a person meets on the way a person
//    goes. So for each screen this test STARTS Thomas fresh (as a person opens it), answers any system permission
//    prompt as a person who wants the camera would, and TAPS its way there, finding every button by its accessibility
//    name (the name VoiceOver reads) and tapping only what is on screen, scrolling the page by hand when it isn't.
//    Before auditing it proves it arrived (something only that screen shows), and before the last tap it proves that
//    proof was NOT already true, so the screen before can never be audited under the target's name. Plan and its
//    independent review: A11Y_AUDIT_BY_TAPS_PLAN.md (repo root, private).
//  - testWalk / testAudit: attach to whatever Thomas screen is in front and read it; they never launch or press.
//
//  HOW IT IS RUN: tools/a11y_audit.py (private). TEST_RUNNER_THOMAS_SCREENS=<tags> picks screens (default all).
//
import XCTest

final class ThomasAuditTests: XCTestCase {

    private static let thomasBundleID = "com.MarkFriedlander.AI-Camera"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - The audit of record: by taps

    /// What identifies an element on screen, by the names a person and VoiceOver use.
    enum Marker: CustomStringConvertible {
        case button(String), buttonPrefix(String), text(String), textPrefix(String), link(String)
        case field(placeholder: String), anyLabel(String)

        var description: String {
            switch self {
            case .button(let s): return "button \"\(s)\""
            case .buttonPrefix(let s): return "button starting \"\(s)\""
            case .text(let s): return "text \"\(s)\""
            case .textPrefix(let s): return "text starting \"\(s)\""
            case .link(let s): return "link \"\(s)\""
            case .field(let p): return "text field \"\(p)\""
            case .anyLabel(let s): return "element \"\(s)\""
            }
        }

        @MainActor func element(in app: XCUIApplication) -> XCUIElement {
            switch self {
            case .button(let s): return app.buttons.matching(NSPredicate(format: "label == %@", s)).firstMatch
            case .buttonPrefix(let s): return app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", s)).firstMatch
            case .text(let s): return app.staticTexts.matching(NSPredicate(format: "label == %@", s)).firstMatch
            case .textPrefix(let s): return app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", s)).firstMatch
            case .link(let s): return app.links.matching(NSPredicate(format: "label == %@", s)).firstMatch
            case .field(let p): return app.textFields.matching(NSPredicate(format: "placeholderValue == %@", p)).firstMatch
            case .anyLabel(let s): return app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", s)).firstMatch
            }
        }
    }

    /// One screen: the taps that reach it from a fresh launch, and what only that screen shows.
    struct Route {
        let tag: String
        let taps: [Marker]
        let proof: [Marker]
        var absent: [Marker] = []
    }

    /// The screens, each reached the way a person reaches it. Names verified against the source and the walks of
    /// 2026-11-14 night; proofs chosen so none is also true on the screen before (independent plan review).
    static let routes: [Route] = [
        Route(tag: "capture", taps: [], proof: [.button("Shutter")], absent: [.anyLabel("dismiss popup")]),
        Route(tag: "privacy", taps: [.buttonPrefix("Privacy:")],
              proof: [.textPrefix("The look"), .anyLabel("dismiss popup")]),
        Route(tag: "prefs-front", taps: [.button("Preferences")], proof: [.text("YOUR CAMERA, AS IT IS SET NOW")]),
        Route(tag: "prefs-lens", taps: [.button("Preferences"), .buttonPrefix("Lens:")], proof: [.text("FRAME 1 · THE LENS")]),
        Route(tag: "prefs-eye", taps: [.button("Preferences"), .buttonPrefix("Eye:")], proof: [.text("FRAME 2 · THE EYE")]),
        Route(tag: "prefs-hand", taps: [.button("Preferences"), .buttonPrefix("Hand:")], proof: [.text("FRAME 3 · THE HAND")]),
        Route(tag: "prefs-print", taps: [.button("Preferences"), .buttonPrefix("Print:")], proof: [.text("THE PRINT")]),
        Route(tag: "prefs-help", taps: [.button("Preferences"), .buttonPrefix("Eye:"), .button("More about temperature")],
              proof: [.button("More in the guide"), .textPrefix("Each time the eye picks its next word")]),
        // Model Library and About are lists, which build their rows only as they scroll into view: a proof at the
        // FOOT of the page ("Clear all family models", "Source code") never appeared at the largest text size though
        // the page had opened (2026-11-15). Proofs are now what each page shows at its top, with its title.
        Route(tag: "modellibrary", taps: [.button("Preferences"), .buttonPrefix("Model Library")],
              proof: [.text("The eye"), .text("Model Library")]),
        Route(tag: "about", taps: [.button("Preferences"), .button("About Thomas")],
              proof: [.text("A camera whose film is language."), .text("About")]),
        Route(tag: "guide", taps: [.button("Preferences"), .buttonPrefix("The Thomas Guide")],
              proof: [.field(placeholder: "Find in the guide"), .text("The Thomas Guide")]),
        Route(tag: "darkroom", taps: [.button("Dark Room")], proof: [.text("THE DARK ROOM")]),
    ]

    /// What happened on one screen, attached as `summary-<tag>.json` the moment the screen is done.
    struct Outcome {
        var tag: String
        var status = "not-run"     // reached | unreachable | wrong-screen | blocked | audit-failed
        var reason = ""
        var taps: [String] = []
        var scrolls = 0
        var alerts: [String] = []
        /// Seconds from each tap until the screen moved (the next button, or the target's proof, appeared).
        var tapSeconds: [Double] = []
        /// Earlier tries of this screen that another app's overlay interrupted (each redone from a fresh launch).
        var interruptions: [String] = []
        var proofAfterAudit: Bool? = nil
        var auditIssues: Int? = nil

        var row: [String: Any] {
            var r: [String: Any] = ["screen": tag, "status": status, "reason": reason, "taps": taps,
                                    "scrolls": scrolls, "alerts": alerts, "tapSeconds": tapSeconds,
                                    "interruptions": interruptions]
            if let p = proofAfterAudit { r["proofAfterAudit"] = p }
            if let n = auditIssues { r["auditIssues"] = n }
            return r
        }
    }

    @MainActor
    func testAuditByTaps() throws {
        continueAfterFailure = true   // one unreachable screen must not stop the rest; nothing here asserts blindly
        let env = ProcessInfo.processInfo.environment
        let wanted = (env["THOMAS_SCREENS"] ?? "all").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let known = Set(Self.routes.map(\.tag))
        let unknown = wanted.filter { $0 != "all" && !known.contains($0) }
        guard unknown.isEmpty else {
            try attachJSON(["error": "unknown screens", "unknown": unknown, "known": Self.routes.map(\.tag)],
                           named: "run-summary.json")
            XCTFail("Unknown screen names: \(unknown). Known: \(Self.routes.map(\.tag))")
            return
        }
        // Self-tests of this tool (the plan's "prove it tells the truth"); never set for a real audit.
        let skipLastTap = env["THOMAS_SKIP_LAST_TAP"] == "1"   // must give wrong-screen
        let misspell = env["THOMAS_MISSPELL_LAST_TAP"] == "1"  // must give unreachable
        // The last tap goes to this text instead (an inert label on the screen before): must give "did not move".
        let deadLastTap = env["THOMAS_DEAD_LAST_TAP"].flatMap { $0.isEmpty ? nil : $0 }
        // Seconds to let Thomas settle after each launch before the first tap: like a person waiting for it to be
        // ready. The runner sets 30 on a Simulator (it dropped taps in its first seconds, 2026-11-15) and 0 on a
        // real device, where Mark's own taps and clicks reached first time. One TEST tap on the phone that day moved
        // nothing (a Debug build with a touch recorder on), so a real device is not assumed perfect: a tap that
        // moves nothing fails the screen, wherever it happens.
        let settle = Double(env["THOMAS_SETTLE_SECONDS"] ?? "") ?? 0

        // Which build is RUNNING, read from the app itself before any screen is audited (independent tool review,
        // 2026-11-15: xcodebuild's test step had silently installed the Debug build over the App Store one, and a file
        // on the Mac said "Release"). The runner compares this with the build it was asked for and fails a mismatch.
        let build = runningBuild(settle: settle)
        try attachJSON(build, named: "build-seen.json")

        let routes = Self.routes.filter { wanted.contains("all") || wanted.contains($0.tag) }
        var outcomes: [Outcome] = []
        for route in routes {
            // A tap that lands on ANOTHER app's overlay (Mark's Live Activities, which drop over the top of the screen
            // when a score changes, even in Do Not Disturb) sends Thomas to the background; that screen is redone from
            // a fresh launch, at most twice, and every interruption is recorded. Not a second tap on Thomas: the tap
            // never reached Thomas (2026-11-15: Apple Sports opened twice; Mark: "work around them").
            var interruptions: [String] = []
            var outcome = visit(route, skipLastTap: skipLastTap, misspell: misspell, deadLastTap: deadLastTap,
                                settle: settle)
            while outcome.status == "interrupted" && interruptions.count < 2 {
                interruptions.append(outcome.reason)
                outcome = visit(route, skipLastTap: skipLastTap, misspell: misspell, deadLastTap: deadLastTap,
                                settle: settle)
            }
            if outcome.status == "interrupted" { interruptions.append(outcome.reason) }
            outcome.interruptions = interruptions
            outcomes.append(outcome)
            try attachJSON(outcome.row, named: "summary-\(route.tag).json")
        }
        var run: [String: Any] = ["screens": outcomes.map(\.row),
                                  "selfTest": skipLastTap ? "skip-last-tap" : (misspell ? "misspell-last-tap"
                                                : (deadLastTap != nil ? "dead-last-tap"
                                                : (env["THOMAS_ANSWER_NOTHING"] == "1" ? "no-answers" : "none")))]
        run["buildSeen"] = build["build"]
        Self.leaveThomasInFront()
        run["device"] = UIDevice.current.name
        run["system"] = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        try attachJSON(run, named: "run-summary.json")
        let notReached = outcomes.filter { $0.status != "reached" }
        if !notReached.isEmpty {
            XCTFail("Not audited: " + notReached.map { "\($0.tag) (\($0.status): \($0.reason))" }.joined(separator: "; "))
        }
    }

    /// At the end of a run, Thomas in front (not whatever app an overlay's stolen tap opened on Mark's phone).
    @MainActor
    static func leaveThomasInFront() {
        let app = XCUIApplication(bundleIdentifier: thomasBundleID)
        if app.state != .runningForeground { app.activate() }
    }

    /// Thomas, launched at the text size the run asks for. TEST_RUNNER_THOMAS_CONTENT_SIZE (e.g.
    /// UICTContentSizeCategoryAccessibilityXXXL) makes THOMAS ALONE use that size, through the launch argument UIKit
    /// reads for it, so the largest sizes can be audited on Mark's phone without touching his phone's own setting
    /// (2026-11-15). Unset: the device's own size.
    @MainActor
    static func thomas() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: thomasBundleID)
        if let size = ProcessInfo.processInfo.environment["THOMAS_CONTENT_SIZE"], !size.isEmpty {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", size]
        }
        return app
    }

    /// Which build is running, read from the app: a fresh launch, a tap on the gear (a person's path), then a look
    /// for the developer card at the foot of Preferences. Only a Debug build has it ("Antenna (Debug)", compiled out
    /// of Release); it sits in a plain stack, so it is in the accessibility tree even while scrolled out of view.
    /// "Debug" or "Release" only when the look could be made; "unknown" (with the reason) when Preferences never
    /// opened, which the runner treats as a failure: a build it cannot see is not a build it can vouch for.
    @MainActor
    private func runningBuild(settle: Double) -> [String: Any] {
        var scratch = Outcome(tag: "build-check")
        let app = Self.thomas()
        app.launch()
        guard app.wait(for: .runningForeground, timeout: 15) else {
            return ["build": "unknown", "reason": "Thomas did not come to the foreground"]
        }
        var clear = answerSystemAlerts(into: &scratch, settle: 2.0)
        if clear && settle > 0 {
            RunLoop.current.run(until: Date().addingTimeInterval(settle))
            clear = answerSystemAlerts(into: &scratch, settle: 0)
        }
        guard clear else {
            attachScreenshot(named: "build-check-BLOCKED.png")
            return ["build": "unknown", "reason": "a system prompt the test has no answer for is up",
                    "alerts": scratch.alerts]
        }
        let gear = Marker.button("Preferences").element(in: app)
        guard gear.waitForExistence(timeout: 5), gear.isHittable else {
            return ["build": "unknown", "reason": "no Preferences button on screen", "alerts": scratch.alerts]
        }
        gear.tap()
        let front = Marker.text("YOUR CAMERA, AS IT IS SET NOW").element(in: app)
        guard front.waitForExistence(timeout: 5) else {
            attachScreenshot(named: "build-check-WRONG.png")
            return ["build": "unknown", "reason": "a tap on Preferences did not open it", "alerts": scratch.alerts]
        }
        let card = Marker.anyLabel("Antenna (Debug)").element(in: app)
        // The page is fully built once its front text exists; a short wait more guards a late row.
        let debug = card.waitForExistence(timeout: 2)
        return ["build": debug ? "Debug" : "Release",
                "evidence": debug ? "the Debug-only \"Antenna (Debug)\" card is in Preferences"
                                  : "no \"Antenna (Debug)\" card in Preferences (it exists only in Debug)",
                "alerts": scratch.alerts]
    }

    /// One screen, from a fresh launch to its audit. Never throws: every way it can go wrong is an outcome.
    @MainActor
    private func visit(_ route: Route, skipLastTap: Bool, misspell: Bool, deadLastTap: String?,
                       settle: Double) -> Outcome {
        var out = Outcome(tag: route.tag)
        // Every way a screen can fail leaves a picture of where the test was (independent tool review, 2026-11-15:
        // an unreachable screen used to return before any screenshot).
        func fail(_ status: String, _ reason: String) -> Outcome {
            out.status = status; out.reason = reason
            attachScreenshot(named: "screen-\(route.tag)-\(status.uppercased()).png")
            return out
        }
        let app = Self.thomas()
        app.launch()   // a fresh start, as a person opens the app (each screen starts clean)
        guard app.wait(for: .runningForeground, timeout: 15) else {
            return fail("unreachable", "Thomas did not come to the foreground after launch")
        }
        let blocked = "a system prompt the test has no answer for is up (see alerts)"
        guard answerSystemAlerts(into: &out, settle: 2.0) else { return fail("blocked", blocked) }
        if settle > 0 {
            RunLoop.current.run(until: Date().addingTimeInterval(settle))
            guard answerSystemAlerts(into: &out, settle: 0) else { return fail("blocked", blocked) }
        }

        var taps = route.taps
        if misspell, let last = taps.popLast() { taps.append(Self.misspelled(last)) }
        if let dead = deadLastTap, !taps.isEmpty { taps[taps.count - 1] = .text(dead) }
        for (i, marker) in taps.enumerated() {
            let isLast = i == taps.count - 1
            if isLast && !route.proof.isEmpty && proofHolds(route, in: app) {
                // The guard: the target's proof must NOT be true before its last tap, or we would audit the screen
                // before under the target's name.
                return fail("wrong-screen", "the proof was already true before the last tap (\(marker)); proof not specific")
            }
            if isLast && skipLastTap { break }
            guard answerSystemAlerts(into: &out, settle: 0) else { return fail("blocked", blocked) }
            let el = marker.element(in: app)
            if !el.waitForExistence(timeout: 5) {
                return fail("unreachable", "no \(marker) on screen to tap")
            }
            if !el.isHittable, let why = scrollUntilHittable(el, in: app, outcome: &out) {
                return fail("unreachable", "\(marker) exists but could not be brought on screen: \(why)")
            }
            let before = screenNames(app)
            el.tap()
            let tapped = Date()
            let interrupted = "another app came to the front after the tap on \(marker) (a system overlay, such as a "
                + "Live Activity, took the tap)"
            out.taps.append(marker.description)
            // Did the tap move the screen? The next button, or for the last tap the screen's proof, should appear.
            // ONE tap, never a second: a tap that moves nothing is a finding, and a second try would hide it (and
            // could land on whatever the first tap opened late). The independent tool review, 2026-11-15.
            let moved: () -> Bool = {
                if isLast { return self.proofHolds(route, in: app) }
                return taps[i + 1].element(in: app).exists
            }
            // While waiting, a system prompt that appears is answered (or blocks the screen), not left to sit
            // over the page: prompts used to be checked only at fixed points (independent tool review).
            let waitLimit: TimeInterval = 10
            let deadline = tapped.addingTimeInterval(waitLimit)
            var didMove = false
            repeat {
                if app.state != .runningForeground { return fail("interrupted", interrupted) }
                if moved() { didMove = true; break }
                guard answerSystemAlerts(into: &out, settle: 0) else { return fail("blocked", blocked) }
            } while Date() < deadline
            if app.state != .runningForeground { return fail("interrupted", interrupted) }
            if !didMove {
                // Say what actually happened (independent tool review: "no button X" was reported when the real
                // cause was a tap that moved nothing; and on 2026-11-15 "did not move" was reported for pages
                // that HAD opened, whose proof was wrong).
                let expected = isLast ? "the screen's proof (\(route.proof.map(\.description).joined(separator: ", ")))"
                                      : "\(taps[i + 1])"
                if screenNames(app) == before {
                    return fail("unreachable", "the tap on \(marker) did not move the screen (waited \(Int(waitLimit)) s, "
                                + "tapped once; nothing on screen changed)")
                }
                return fail("wrong-screen", "the tap on \(marker) changed the screen, but \(expected) never appeared "
                            + "in \(Int(waitLimit)) s (tapped once): it went somewhere else, or the test's marker is "
                            + "wrong; see the picture")
            }
            out.tapSeconds.append((Date().timeIntervalSince(tapped) * 100).rounded() / 100)
        }

        guard answerSystemAlerts(into: &out, settle: 0) else { return fail("blocked", blocked) }
        guard waitForProof(route, in: app, timeout: 5) else {
            return fail("wrong-screen", "after the taps, missing: " + route.proof.filter { !$0.element(in: app).exists }
                .map(\.description).joined(separator: ", ")
                + route.absent.filter { $0.element(in: app).exists }.map { "; present but must not be: \($0)" }.joined())
        }
        attachScreenshot(named: "screen-\(route.tag).png")

        do {
            let issues = try auditRows(app)
            out.auditIssues = (issues["issues"] as? [[String: Any]])?.count
            try attachJSON(issues.merging(["screen": route.tag]) { a, _ in a }, named: "audit-\(route.tag).json")
            let walk = try walkRows(app)
            try attachJSON(walk.merging(["screen": route.tag]) { a, _ in a }, named: "walk-\(route.tag).json")
        } catch {
            return fail("audit-failed", "\(error)")
        }
        // Still the same screen after the audit? (An audit that moved the screen would have read two screens.)
        out.proofAfterAudit = proofHolds(route, in: app)
        if out.proofAfterAudit != true { return fail("wrong-screen", "the proof no longer held after the audit") }
        out.status = "reached"
        return out
    }

    /// The names of what is on screen now (texts and buttons), to tell a tap that moved nothing from one that
    /// moved the screen somewhere unexpected.
    @MainActor
    private func screenNames(_ app: XCUIApplication) -> Set<String> {
        guard let snap = try? app.snapshot() else { return [] }
        var names = Set<String>()
        func visit(_ n: XCUIElementSnapshot) {
            if (n.elementType == .staticText || n.elementType == .button) && !n.label.isEmpty {
                names.insert("\(n.elementType.rawValue):\(n.label)")
            }
            n.children.forEach(visit)
        }
        visit(snap)
        return names
    }

    @MainActor
    private func proofHolds(_ route: Route, in app: XCUIApplication) -> Bool {
        route.proof.allSatisfy { $0.element(in: app).exists } && !route.absent.contains { $0.element(in: app).exists }
    }

    @MainActor
    private func waitForProof(_ route: Route, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if proofHolds(route, in: app) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return false
    }

    /// Answers a system permission prompt the way a person who wants the camera to work does, and records it
    /// (each answer changes a setting on the device; the runner lists them). Checks Springboard directly (not an
    /// interruption monitor, which only fires on an interaction). Returns false, with the prompt's title and buttons
    /// recorded in `out.alerts`, when a prompt is up that it has no answer for: the screen is then blocked, and the
    /// caller fails it (independent tool review, 2026-11-15: such a prompt used to be left up and unrecorded).
    @MainActor @discardableResult
    private func answerSystemAlerts(into out: inout Outcome, settle: TimeInterval) -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(settle)
        repeat {
            let alert = springboard.alerts.firstMatch
            if alert.exists {
                let title = alert.label
                // The first matching button that is on screen: the camera alert holds more than one element
                // named "Allow", and tapping by name alone failed on the phone (2026-11-15).
                var answered = false
                // Self-test "no-answers" (THOMAS_ANSWER_NOTHING=1): knows no answer, so any prompt must block.
                let choices = ProcessInfo.processInfo.environment["THOMAS_ANSWER_NOTHING"] == "1"
                    ? [] : ["Allow While Using App", "Allow", "OK"]
                for choice in choices {
                    let b = alert.buttons.matching(NSPredicate(format: "label == %@", choice))
                        .allElementsBoundByIndex.first { $0.exists && $0.isHittable }
                    if let b { b.tap(); out.alerts.append("\(title) -> \(choice)"); answered = true; break }
                }
                if !answered {
                    let buttons = alert.buttons.allElementsBoundByIndex.map(\.label)
                    out.alerts.append("UNANSWERED: \(title) [buttons: \(buttons.joined(separator: ", "))]")
                    return false
                }
                RunLoop.current.run(until: Date().addingTimeInterval(1.0))
                continue
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return true
    }

    /// Scrolls the page the way a person does, a slow upward drag from the left margin (clear of the prompt box,
    /// which scrolls on its own), until the element is on screen. Returns nil when it is, else why not.
    /// DOWN THE PAGE ONLY: every page here is opened fresh at its top, so what is off screen is below. A downward
    /// drag at the top of a sheet (Preferences is a sheet on iPhone and iPad) pulls the sheet closed, so the test
    /// never makes one (independent tool review, 2026-11-15: the old scroll-back could close it and report the wrong
    /// reason). It stops when the page stops moving (its end), and notices if the element is gone. Every drag counts.
    @MainActor
    private func scrollUntilHittable(_ el: XCUIElement, in app: XCUIApplication, outcome: inout Outcome) -> String? {
        for _ in 0..<15 {
            let before = el.frame
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.75))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.40))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
            outcome.scrolls += 1
            guard el.exists else { return "it disappeared while scrolling (the page closed or changed)" }
            if el.isHittable { return nil }
            if el.frame == before { return "the page stopped moving (its end) with the element still off screen" }
        }
        return "still off screen after 15 drags down the page"
    }

    private static func misspelled(_ m: Marker) -> Marker {
        switch m {
        case .button(let s): return .button(s + "zz")
        case .buttonPrefix(let s): return .buttonPrefix("zz" + s)
        default: return .button("zz-misspelled")
        }
    }

    @MainActor
    private func attachScreenshot(named name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: - Real touch areas of Apple's own controls (group B of the fix list, 2026-11-15)

    /// One of Apple's own controls, the taps that reach it, and how to tell it responded (and undo that).
    struct TouchTarget {
        let name: String
        let taps: [Marker]
        let element: (XCUIApplication) -> XCUIElement
        /// A snapshot of the control's state before a tap; `responded` compares against it.
        let state: (XCUIApplication) -> String
        /// Puts it back as it was, after a tap that responded (Mark's settings are never left changed).
        let undo: (XCUIApplication, XCUIElement) -> Void
    }

    /// For each kind of Apple control the audit's size list named (the top bar's Close and "?", the on/off switch,
    /// the 4:3 / 16:9 control), whether a REAL tap lands just inside the edge of a 44 x 44 pt zone around it, on
    /// every side where the control is drawn smaller than 44. The accessibility frame is what the size list
    /// measured; for Apple's controls the area a finger can hit may be larger, and only a tap shows it.
    /// One fresh launch per tap point; anything a tap changed is put back at once. Attaches touch-areas.json.
    @MainActor
    func testTouchAreas() throws {
        continueAfterFailure = true
        // The "?" card is open when its "Done" is on screen (neither page has another "Done" without a keyboard).
        let helpOpen: (XCUIApplication) -> String = { app in
            app.buttons.matching(NSPredicate(format: "label == %@", "Done")).firstMatch.exists ? "open" : "closed"
        }
        let closeHelp: (XCUIApplication, XCUIElement) -> Void = { app, _ in
            let done = app.buttons.matching(NSPredicate(format: "label == %@", "Done")).firstMatch
            if done.exists { done.tap() }
        }
        let prefsShowing: (XCUIApplication) -> String = { app in
            Marker.text("YOUR CAMERA, AS IT IS SET NOW").element(in: app).exists ? "open" : "closed"
        }
        let roomShowing: (XCUIApplication) -> String = { app in
            Marker.text("THE DARK ROOM").element(in: app).exists ? "open" : "closed"
        }
        let targets: [TouchTarget] = [
            TouchTarget(name: "Preferences \"?\" (About Preferences)", taps: [.button("Preferences")],
                        element: { Marker.button("About Preferences").element(in: $0) }, state: helpOpen, undo: closeHelp),
            TouchTarget(name: "Preferences Close", taps: [.button("Preferences")],
                        element: { Marker.button("Close").element(in: $0) }, state: prefsShowing, undo: { _, _ in }),
            TouchTarget(name: "Dark Room \"?\" (About the Dark Room)", taps: [.button("Dark Room")],
                        element: { Marker.button("About the Dark Room").element(in: $0) }, state: helpOpen, undo: closeHelp),
            TouchTarget(name: "Dark Room Close", taps: [.button("Dark Room")],
                        element: { Marker.button("Close").element(in: $0) }, state: roomShowing, undo: { _, _ in }),
            TouchTarget(name: "Switch (Stamp raw coordinates)", taps: [.button("Preferences"), .buttonPrefix("Lens:")],
                        element: { $0.switches.matching(NSPredicate(format: "label == %@", "Stamp raw coordinates")).firstMatch },
                        state: { app in
                            "\(app.switches.matching(NSPredicate(format: "label == %@", "Stamp raw coordinates")).firstMatch.value ?? "")"
                        },
                        undo: { _, el in el.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap() }),
            TouchTarget(name: "Slider (Temperature)", taps: [.button("Preferences"), .buttonPrefix("Eye:")],
                        element: { $0.sliders.matching(NSPredicate(format: "label == %@", "Temperature")).firstMatch },
                        state: { app in
                            "\(app.sliders.matching(NSPredicate(format: "label == %@", "Temperature")).firstMatch.value ?? "")"
                        },
                        undo: { _, _ in }),   // the slider is put back from its own reading, below
            // The guide's search field: focused (keyboard up) when the tap reached it. Each tap point starts fresh.
            TouchTarget(name: "Search field (Find in the guide)", taps: [.button("Preferences"), .buttonPrefix("The Thomas Guide")],
                        element: { Marker.field(placeholder: "Find in the guide").element(in: $0) },
                        state: { app in app.keyboards.count > 0 ? "focused" : "not focused" },
                        undo: { _, _ in }),
            // The segment NOT chosen (tapping the chosen one changes nothing, so it could never respond).
            TouchTarget(name: "Picture shape segment (the one not chosen)", taps: [.button("Preferences"), .buttonPrefix("Lens:")],
                        element: { app in
                            let four = Marker.button("4:3").element(in: app)
                            return four.isSelected ? Marker.button("16:9").element(in: app) : four
                        },
                        state: { app in Marker.button("4:3").element(in: app).isSelected ? "4:3" : "16:9" },
                        undo: { app, _ in
                            // Back to whichever it was: tap the centre of the segment that was selected before.
                            let four = Marker.button("4:3").element(in: app)
                            let sixteen = Marker.button("16:9").element(in: app)
                            (four.isSelected ? sixteen : four).tap()
                        }),
        ]
        var rows: [[String: Any]] = []
        var interruptedPoints: [String] = []
        // TEST_RUNNER_THOMAS_TOUCH_ONLY=<words>: only the controls whose name contains one of them (comma-separated).
        let only = (ProcessInfo.processInfo.environment["THOMAS_TOUCH_ONLY"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for target in targets where only.isEmpty || only.contains(where: { target.name.contains($0) }) {
            // Find the control once to learn its frame.
            guard let probe = reach(target) else {
                rows.append(["control": target.name, "error": "could not reach it: \(lastReachFailure)"]); continue
            }
            let frame = probe.frame
            // The switch's row spans the card; its knob sits at the right end. Test the knob's column.
            let isSwitch = target.name.hasPrefix("Switch")
            let isSlider = target.name.hasPrefix("Slider")
            let isSetting = isSwitch || isSlider || target.name.hasPrefix("Picture shape")
            // A slider is grabbed by its knob: test around the knob, where the current value puts it (the track
            // has about 14 pt of inset at each end).
            // The slider reports its real value (e.g. "0.6"), not a percentage (read from the phone's walk,
            // 2026-11-15); Temperature runs 0...1.5 (Preferences.swift).
            let sliderPos = isSlider ? (Double("\(probe.value ?? "")") ?? 0) / Self.temperatureMax : 0
            let cx = isSwitch ? frame.maxX - 31 : (isSlider ? frame.minX + 14 + (frame.width - 28) * sliderPos : frame.midX)
            let cy = frame.midY
            // First the CENTRE, which must respond: a check that has never seen a response can't be trusted when it
            // reports none (a touch-check run on 2026-11-15 reported "no response" everywhere with no control).
            var points: [(String, CGFloat, CGFloat)] = [("centre (control)", cx, cy)]
            if frame.height < 44 { points += [("above", cx, cy - 21), ("below", cx, cy + 21)] }
            if !isSwitch && !isSlider && frame.width < 44 { points += [("left", cx - 21, cy), ("right", cx + 21, cy)] }
            var results: [[String: Any]] = []
            for (side, x, y) in points {
              var attempt = 0
              while true {
                attempt += 1
                guard let el = reach(target) else {
                    // Redo only when another app's overlay interrupted the way there; any other failure is reported.
                    if lastReachFailure.contains("another app") && attempt < 3 {
                        interruptedPoints.append("\(target.name) \(side) (on the way)"); continue
                    }
                    results.append(["side": side, "error": "could not reach: \(lastReachFailure)"]); break
                }
                let app = XCUIApplication(bundleIdentifier: Self.thomasBundleID)
                let before = target.state(app)
                let point = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
                if isSlider {
                    // A finger presses beside the knob and drags it 60 pt to the right.
                    point.press(forDuration: 0.15, thenDragTo: point.withOffset(CGVector(dx: 60, dy: 0)))
                } else {
                    point.tap()
                }
                RunLoop.current.run(until: Date().addingTimeInterval(1.5))
                if app.state != .runningForeground {
                    // Another app's overlay took the tap: no reading of Thomas means anything; redo this point.
                    interruptedPoints.append("\(target.name) \(side)")
                    if attempt < 3 { continue }
                    results.append(["side": side, "error": "interrupted 3 times by another app's overlay"])
                    break
                }
                let after = target.state(app)
                let responded = after != before
                if responded {
                    if isSlider, let was = Double(before) {
                        // Back to its exact reading, in small checked moves (one adjust alone missed, 2026-11-15).
                        _ = setSlider(el, to: was)
                    } else {
                        target.undo(app, el)
                    }
                    RunLoop.current.run(until: Date().addingTimeInterval(1.0))
                }
                var row: [String: Any] = ["side": side, "point": ["x": Int(x), "y": Int(y)], "responded": responded,
                                          "before": before, "after": after]
                // A setting the tap changed must be back as it was (a closed page or card changes no setting).
                if isSetting && responded { row["settingPutBack"] = target.state(app) == before }
                results.append(row)
                break
              }
            }
            rows.append(["control": target.name, "frame": Self.frameRow(frame), "taps": results])
        }
        Self.leaveThomasInFront()
        try attachJSON(["touchAreas": rows, "interrupted": interruptedPoints], named: "touch-areas.json")
    }

    /// Why the last `reach` failed (with a picture attached), for touch-areas.json.
    private var lastReachFailure = ""

    /// The Temperature slider's top (Preferences.swift: `in: 0...1.5`).
    static let temperatureMax = 1.5

    /// A fresh launch and the taps to a touch target; the control, on screen, or nil (the reason in
    /// `lastReachFailure`, and a screenshot named touch-unreachable-<n>.png).
    @MainActor
    private func reach(_ target: TouchTarget) -> XCUIElement? {
        func failed(_ why: String) -> XCUIElement? {
            reachFailures += 1
            lastReachFailure = why + " (picture: touch-unreachable-\(reachFailures).png)"
            attachScreenshot(named: "touch-unreachable-\(reachFailures).png")
            return nil
        }
        let app = Self.thomas()
        app.launch()
        guard app.wait(for: .runningForeground, timeout: 15) else { return failed("Thomas did not come to the foreground") }
        var scratch = Outcome(tag: "touch")
        guard answerSystemAlerts(into: &scratch, settle: 2.0) else {
            return failed("a system prompt it has no answer for: \(scratch.alerts.joined(separator: "; "))")
        }
        for marker in target.taps {
            let el = marker.element(in: app)
            guard el.waitForExistence(timeout: 5) else { return failed("no \(marker) on screen") }
            // Scrolled to, as a person does, when it is further down the page (the guide's row, 2026-11-15).
            if !el.isHittable, let why = scrollUntilHittable(el, in: app, outcome: &scratch) {
                return failed("\(marker) could not be brought on screen: \(why)")
            }
            el.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            if app.state != .runningForeground { return failed("another app came to the front after the tap on \(marker)") }
        }
        let el = target.element(app)
        guard el.waitForExistence(timeout: 5) else { return failed("the control is not on screen") }
        if !el.isHittable, let why = scrollUntilHittable(el, in: app, outcome: &scratch) {
            return failed("the control could not be brought on screen: \(why)")
        }
        return el
    }
    private var reachFailures = 0

    /// Puts the Temperature slider at TEST_RUNNER_THOMAS_SET_TEMPERATURE exactly (e.g. 0.6), the way a finger does,
    /// in small moves, reading the slider after each; attaches set-temperature.json with every reading. Written to
    /// put Mark's setting back after a touch check's undo missed (2026-11-15: 0.6 was left at 0.9).
    @MainActor
    func testSetTemperature() throws {
        let target = Double(ProcessInfo.processInfo.environment["THOMAS_SET_TEMPERATURE"] ?? "") ?? -1
        var log: [String: Any] = ["target": target]
        defer { try? attachJSON(log, named: "set-temperature.json") }
        guard target >= 0 else { log["error"] = "no target"; return }
        let reachEye = TouchTarget(name: "Slider", taps: [.button("Preferences"), .buttonPrefix("Eye:")],
                                   element: { $0.sliders.matching(NSPredicate(format: "label == %@", "Temperature")).firstMatch },
                                   state: { _ in "" }, undo: { _, _ in })
        guard let slider = reach(reachEye) else { log["error"] = "could not reach: \(lastReachFailure)"; return }
        let (ok, readings) = setSlider(slider, to: target)
        log["readings"] = readings
        log["final"] = "\(slider.value ?? "")"
        log["ok"] = ok
    }

    /// Moves the Temperature slider to `target` the way a finger does: press the knob where its value puts it and
    /// drag a short distance, reading the value after every drag, notch by notch (0.05). `adjust(toNormalizedSlider
    /// Position:)` overshot back and forth (0.5 / 0.7) on the phone, 2026-11-15, so it is not used. Returns whether
    /// it reads `target` at the end, and every reading.
    @MainActor
    func setSlider(_ slider: XCUIElement, to target: Double) -> (Bool, [String]) {
        func reading() -> Double? { Double("\(slider.value ?? "")") }
        var readings: [String] = ["start \(slider.value ?? "")"]
        var ptsPerNotch: CGFloat = (slider.frame.width - 28) * 0.05 / CGFloat(Self.temperatureMax)
        for _ in 0..<20 {
            guard let now = reading() else { readings.append("no reading"); break }
            if abs(now - target) < 0.001 { break }
            let notches = (target - now) / 0.05
            let f = slider.frame
            let knobX = 14 + (f.width - 28) * CGFloat(now / Self.temperatureMax)
            let start = slider.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: knobX, dy: f.height / 2))
            // Move at most two notches per drag, so an error never runs far.
            let move = CGFloat(max(-2, min(2, notches))) * ptsPerNotch
            start.press(forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: move, dy: 0)),
                        withVelocity: .slow, thenHoldForDuration: 0.2)
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            let after = reading() ?? now
            readings.append(String(format: "%.2f: drag %.1f pt -> %@", now, move, "\(slider.value ?? "")"))
            // Learn the real distance per notch from what the drag did.
            let moved = (after - now) / 0.05
            if abs(moved) >= 1 { ptsPerNotch = abs(move / CGFloat(moved)) }
        }
        return ((reading().map { abs($0 - target) < 0.001 }) ?? false, readings)
    }

    // MARK: - Attach-only tests (whatever is in front)

    /// Every element of the accessibility tree for the running Thomas, as `walk-<screen>.json`.
    @MainActor
    func testWalk() throws {
        let app = runningThomas()
        try attachJSON(try walkRows(app).merging(["screen": Self.screenTag]) { a, _ in a },
                       named: "walk-\(Self.screenTag).json")
    }

    /// Apple's accessibility audit on the screen in front, as `audit-<screen>.json`.
    @MainActor
    func testAudit() throws {
        let app = runningThomas()
        try attachJSON(try auditRows(app).merging(["screen": Self.screenTag]) { a, _ in a },
                       named: "audit-\(Self.screenTag).json")
    }

    // MARK: - Shared helpers (Hal 4's walk and audit)

    /// Apple's accessibility audit (labels, contrast, hit size, Dynamic Type, clipped text and the rest). Every issue
    /// is recorded and returned as handled, so the audit reports what it finds and doesn't fail on it. Also lists
    /// every pressable thing under 44 x 44 pt from the same tree (Hal 4's addition; our reading, not Apple's).
    @MainActor
    func auditRows(_ app: XCUIApplication) throws -> [String: Any] {
        var issues: [[String: Any]] = []
        try app.performAccessibilityAudit(for: .all) { issue in
            var row: [String: Any] = [
                "type": issue.auditType.rawValue,
                "summary": issue.compactDescription,
                "detail": issue.detailedDescription,
                "issue": String(reflecting: issue),
            ]
            if let element = issue.element {
                row["element"] = [
                    "label": element.label,
                    "identifier": element.identifier,
                    "kind": Self.kindName(element.elementType),
                    "frame": Self.frameRow(element.frame),
                ]
            }
            issues.append(row)
            return true
        }
        var small: [[String: Any]] = []
        if let snapshot = try? app.snapshot() { Self.collectSmall(snapshot, into: &small) }
        return ["count": issues.count, "issues": issues, "smallPressables": small]
    }

    /// Every element of the accessibility tree.
    @MainActor
    func walkRows(_ app: XCUIApplication) throws -> [String: Any] {
        let snapshot = try app.snapshot()
        var rows: [[String: Any]] = []
        Self.collect(snapshot, depth: 0, into: &rows)
        return ["count": rows.count, "elements": rows]
    }

    /// The running Thomas, never a new one (attach-only tests).
    @MainActor
    func runningThomas() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: Self.thomasBundleID)
        // A failure, not a skip: a walk of no Thomas must never read as a walk that found nothing.
        XCTAssertNotEqual(app.state, .notRunning, "Thomas is not running. Launch it first; this test never launches it.")
        return app
    }

    static var screenTag: String {
        let raw = ProcessInfo.processInfo.environment["THOMAS_SCREEN"] ?? "screen"
        let safe = raw.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return safe.isEmpty ? "screen" : safe
    }

    func attachJSON(_ object: [String: Any], named name: String) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    static func collect(_ node: XCUIElementSnapshot, depth: Int, into rows: inout [[String: Any]]) {
        var row: [String: Any] = [
            "depth": depth,
            "kind": kindName(node.elementType),
            "label": node.label,
            "title": node.title,
            "identifier": node.identifier,
            "enabled": node.isEnabled,
            "selected": node.isSelected,
            "frame": frameRow(node.frame),
        ]
#if !os(macOS)
        row["focused"] = node.hasFocus  // the macOS SDK has no focus attribute on a snapshot
#endif
        if let value = node.value { row["value"] = "\(value)" }
        if let placeholder = node.placeholderValue { row["placeholder"] = placeholder }
        rows.append(row)
        for child in node.children { collect(child, depth: depth + 1, into: &rows) }
    }

    /// Every button, switch, text field and the like whose frame is under 44 by 44 points (Apple's guideline for a
    /// target a finger can hit), with its name and place.
    private static func collectSmall(_ node: XCUIElementSnapshot, into rows: inout [[String: Any]]) {
        let pressable: Set<XCUIElement.ElementType> = [.button, .switch, .slider, .stepper, .textField, .secureTextField,
                                                       .searchField, .textView, .menuItem, .link]
        if pressable.contains(node.elementType), node.frame.width < 44 || node.frame.height < 44 {
            rows.append(["kind": kindName(node.elementType), "label": node.label, "identifier": node.identifier,
                         "frame": frameRow(node.frame)])
        }
        for child in node.children { collectSmall(child, into: &rows) }
    }

    private static func frameRow(_ frame: CGRect) -> [String: Int] {
        ["x": Int(frame.origin.x.rounded()), "y": Int(frame.origin.y.rounded()),
         "w": Int(frame.size.width.rounded()), "h": Int(frame.size.height.rounded())]
    }

    /// The element kinds a screen reader tells apart, named as Hal 4's walk names them.
    private static func kindName(_ type: XCUIElement.ElementType) -> String {
        switch type {
        case .button: return "button"
        case .link: return "link"
        case .staticText: return "text"
        case .textField: return "textField"
        case .secureTextField: return "secureField"
        case .textView: return "textEditor"
        case .searchField: return "searchField"
        case .image: return "image"
        case .switch: return "switch"
        case .slider: return "slider"
        case .stepper: return "stepper"
        case .picker, .pickerWheel: return "picker"
        case .menu, .menuItem, .menuButton: return "menu"
        case .cell: return "row"
        case .table, .collectionView, .scrollView: return "list"
        case .navigationBar, .toolbar, .tabBar: return "bar"
        case .alert, .sheet, .popover: return "layer"
        case .window: return "window"
        case .application: return "application"
        case .other: return "other"
        default: return "type\(type.rawValue)"
        }
    }
}
