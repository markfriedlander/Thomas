//
//  ThomasAuditTests.swift: Apple's accessibility audit, and a walk of the accessibility tree, on whatever screen of
//  Thomas is in front.
//
//  Modeled on Hal 4's HalWalkTests (Hal4/Hal4/Hal4UITests), at Mark's direction (2026-11-15: "isn't there an automated
//  checker for this that Apple has? I think we're using one for Hal"). The walk and the audit are Hal 4's, with Hal's
//  touch and paste tests left out.
//
//  WHAT IT DOES NOT DO: it never launches, terminates or installs Thomas. It is an independent UI-testing bundle with no
//  target application; it attaches to the Thomas already running (XCUIApplication(bundleIdentifier:), no launch()). The
//  antenna puts each screen in front; these tests only read (a snapshot) and audit. They press nothing.
//
//  HOW IT IS RUN (tools/a11y_audit.py): TEST_RUNNER_THOMAS_SCREEN=<tag> names the screen in the attachments.
//
import XCTest

final class ThomasAuditTests: XCTestCase {

    private static let thomasBundleID = "com.MarkFriedlander.AI-Camera"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Every element of the accessibility tree for the running Thomas, as `walk-<screen>.json`.
    @MainActor
    func testWalk() throws {
        let app = runningThomas()
        let snapshot = try app.snapshot()
        var rows: [[String: Any]] = []
        Self.collect(snapshot, depth: 0, into: &rows)
        try attachJSON(["screen": Self.screenTag, "count": rows.count, "elements": rows], named: "walk-\(Self.screenTag).json")
    }

    /// Apple's accessibility audit on the screen in front (labels, contrast, hit size, Dynamic Type, clipped text and the
    /// rest), as `audit-<screen>.json`. Every issue is recorded and returned as handled, so the test reports what the audit
    /// finds and doesn't fail on it.
    @MainActor
    func testAudit() throws {
        let app = runningThomas()
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
        // Apple's audit often names no element for "Hit area is too small", so list every pressable thing under 44 x 44
        // points from the same tree: our reading, not Apple's (Hal 4's addition).
        var small: [[String: Any]] = []
        if let snapshot = try? app.snapshot() { Self.collectSmall(snapshot, into: &small) }
        try attachJSON(["screen": Self.screenTag, "count": issues.count, "issues": issues,
                        "smallPressables": small], named: "audit-\(Self.screenTag).json")
    }

    // MARK: - Helpers (Hal 4's)

    /// The running Thomas, never a new one. A Thomas that is not running is a failed ground, not something to start.
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
