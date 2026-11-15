//
//  Guide.swift
//  Thomas
//
//  The Thomas Guide, read inside the app: Hal's guide reader and Markdown renderer, copied from Hal
//  Universal (Mark, 2026-11-15), reading THOMAS_GUIDE.md from the app bundle. Search is keyword
//  find-in-page, as in Hal: Thomas has no embedder, and the guide's terms appear verbatim.
//

import SwiftUI
import Combine

// ==== LEGO START: 42 MarkdownView (Block-Level Markdown Renderer) ====
//
// Copied from Hal Universal (ChatViews.swift, LEGO 56) on 2026-11-15, at Mark's request ("you can probably
// lift the code from Hal to use the reader that we built there"), unchanged, so the studio has one renderer
// and a fix in either app can be carried to the other. Only Hal's search-highlight color, defined elsewhere
// in Hal, is added at the end of this block.

// MARK: - Markdown Block Renderer
// Parses markdown into typed blocks and renders each as a distinct SwiftUI view.
// Handles headers, lists, code blocks, and paragraphs. Inline styles (bold, italic,
// inline code) within each block are handled by AttributedString.
// Zero third-party dependencies.

private enum MDBlock {
    case heading(String, level: Int)
    case paragraph(String)
    case unorderedItem(String)
    case orderedItem(String, number: Int)
    case codeBlock(String)
    case table(header: [String], rows: [[String]])
    case rule
}

struct MarkdownView: View {
    let text: String
    // Chat display appearance, passed down from ChatBubbleView. Defaults reproduce the
    // historical look (body ≈ .title3 at 20pt, line spacing 6). Headings scale with the
    // body via `sizeRatio` so their proportions hold at any chosen text size.
    var bodyPointSize: CGFloat = 20
    var lineSpacing: CGFloat = 6
    // Optional find-in-page term. When non-empty, every case-insensitive occurrence
    // in rendered prose, table cells, and code gets a highlight background so search
    // matches stand out. Empty = no highlighting (the normal chat path). Used by the
    // in-app Guide reader; chat passes nothing and is unaffected.
    var highlight: String = ""
    private var sizeRatio: CGFloat { bodyPointSize / 20.0 }

    /// Apply a highlight background to every case-insensitive occurrence of `highlight`
    /// in an already-built AttributedString. No-op when `highlight` is empty. Shared by
    /// the prose (`inlineText`) and code paths so what's counted and what's lit agree.
    private func applyHighlight(_ attr: inout AttributedString) {
        let needle = highlight.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return }
        var searchStart = attr.startIndex
        while searchStart < attr.endIndex,
              let r = attr[searchStart...].range(of: needle, options: .caseInsensitive) {
            attr[r].backgroundColor = Color.searchHighlight
            searchStart = r.upperBound
        }
    }

    var body: some View {
        let blocks = parseBlocks(text)
        VStack(alignment: .leading, spacing: 10) {
            if blocks.isEmpty && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Defensive fallback: parseBlocks returned nothing for non-empty input.
                // Should never happen in normal use, but if it does, render the raw text
                // so the user sees SOMETHING rather than empty space with just a footer.
                // This addresses the "footer visible but text missing after reload" report.
                Text(text)
                    .font(.system(size: bodyPointSize))
                    .lineSpacing(lineSpacing)
                    .foregroundColor(.primary)
            } else {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MDBlock) -> some View {
        switch block {
        case .heading(let s, let level):
            headingView(s, level: level)
        case .paragraph(let s):
            inlineText(s)
                .font(.system(size: bodyPointSize))
                .lineSpacing(lineSpacing)
                .foregroundColor(.primary)
        case .unorderedItem(let s):
            HStack(alignment: .top, spacing: 8) {
                Text("\u{2022}")
                    .font(.system(size: bodyPointSize))
                    .foregroundColor(.secondary)
                inlineText(s)
                    .font(.system(size: bodyPointSize))
                    .lineSpacing(lineSpacing)
                    .foregroundColor(.primary)
            }
        case .orderedItem(let s, let number):
            HStack(alignment: .top, spacing: 6) {
                Text("\(number).")
                    .font(.system(size: bodyPointSize))
                    .foregroundColor(.secondary)
                    .frame(minWidth: 24, alignment: .trailing)
                inlineText(s)
                    .font(.system(size: bodyPointSize))
                    .lineSpacing(lineSpacing)
                    .foregroundColor(.primary)
            }
        case .codeBlock(let code):
            // Render fenced code as a distinct block, not "just small type":
            //  - a readable monospaced size that scales with the chosen body size
            //    (was .caption, which read as tiny),
            //  - a systemGray5 fill that stays visibly distinct in BOTH light and
            //    dark (systemGray6 was ~invisible against the dark chat background),
            //  - a hairline border so the box reads as a box regardless of contrast,
            //  - horizontal scroll so long lines keep their formatting instead of
            //    wrapping mid-token,
            //  - selectable text so the user can copy a snippet.
            ScrollView(.horizontal, showsIndicators: false) {
                codeText(code)
                    .font(.system(size: max(13, bodyPointSize * 0.82), design: .monospaced))
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.systemGray5))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.15), lineWidth: 1)
            )
        case .table(let header, let rows):
            tableView(header: header, rows: rows)
        case .rule:
            Divider().padding(.vertical, 2)
        }
    }

    // Fenced-code text with optional find-in-page highlighting. Plain (no inline
    // markdown), so backticks/asterisks in code stay literal; the monospaced font
    // is applied by the caller's .font modifier.
    private func codeText(_ code: String) -> Text {
        var attr = AttributedString(code)
        applyHighlight(&attr)
        return Text(attr)
    }

    // Render a GFM table as an aligned Grid inside a horizontal scroll (wide tables,
    // like the Command Reference, scroll rather than crush their columns). Header row
    // is semibold; a hairline separates it from the body. Cells go through inlineText
    // so inline code / bold and search highlighting work inside a table too.
    @ViewBuilder
    private func tableView(header: [String], rows: [[String]]) -> some View {
        let cols = max(header.count, rows.map(\.count).max() ?? 0)
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    ForEach(0..<max(cols, 1), id: \.self) { c in
                        inlineText(c < header.count ? header[c] : "")
                            .font(.system(size: bodyPointSize * 0.88, weight: .semibold))
                            .foregroundColor(.primary)
                    }
                }
                Divider().gridCellColumns(max(cols, 1))
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(0..<max(cols, 1), id: \.self) { c in
                            inlineText(c < row.count ? row[c] : "")
                                .font(.system(size: bodyPointSize * 0.88))
                                .foregroundColor(.primary)
                                .lineSpacing(lineSpacing * 0.5)
                        }
                    }
                }
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func headingView(_ s: String, level: Int) -> some View {
        switch level {
        case 1:
            inlineText(s).font(.system(size: 22 * sizeRatio, weight: .bold)).foregroundColor(.primary).padding(.top, 4)
        case 2:
            inlineText(s).font(.system(size: 20 * sizeRatio, weight: .bold)).foregroundColor(.primary).padding(.top, 4)
        case 3:
            inlineText(s).font(.system(size: 17 * sizeRatio, weight: .semibold)).foregroundColor(.primary).padding(.top, 2)
        default:
            inlineText(s).font(.footnote.bold()).foregroundColor(.secondary)
        }
    }

    // Render a string with inline markdown (bold, italic, inline code, links).
    private func inlineText(_ s: String) -> Text {
        if var attr = try? AttributedString(
            markdown: s,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            // Give inline code spans (`like this`) a distinct look instead of
            // leaving them as ordinary prose: a monospaced font sized to sit with
            // the surrounding text, and a faint theme-aware highlight behind the
            // glyphs so `code` reads as code mid-sentence. AttributedString parses
            // backticks into an `.code` inline intent; we restyle those runs.
            for run in attr.runs where run.inlinePresentationIntent?.contains(.code) == true {
                attr[run.range].font = .system(size: bodyPointSize * 0.92, design: .monospaced)
                attr[run.range].backgroundColor = Color.primary.opacity(0.12)
            }
            applyHighlight(&attr)
            return Text(attr)
        }
        var plain = AttributedString(s)
        applyHighlight(&plain)
        return Text(plain)
    }

    // Parse a markdown string into an ordered sequence of typed blocks.
    private func parseBlocks(_ source: String) -> [MDBlock] {
        var blocks: [MDBlock] = []
        var codeAccum: [String]? = nil
        var afterBlank = false

        // Split a "| a | b |" line into trimmed cells, dropping the edge pipes.
        func tableCells(_ s: String) -> [String] {
            var line = s.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("|") { line.removeFirst() }
            if line.hasSuffix("|") { line.removeLast() }
            return line.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        // A GFM separator row: every cell is only dashes/colons/spaces and has a dash.
        func isSeparatorRow(_ s: String) -> Bool {
            let cells = tableCells(s)
            guard !cells.isEmpty else { return false }
            return cells.allSatisfy { cell in
                !cell.isEmpty && cell.contains("-") && cell.allSatisfy { $0 == "-" || $0 == ":" || $0 == " " }
            }
        }

        // Index-based so a table can look ahead one line for its separator row.
        let lines = source.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]

            // Code fence toggle
            if line.hasPrefix("```") {
                if let acc = codeAccum {
                    blocks.append(.codeBlock(acc.joined(separator: "\n")))
                    codeAccum = nil
                } else {
                    codeAccum = []
                }
                i += 1; continue
            }
            // Accumulate inside a code block
            if codeAccum != nil {
                codeAccum!.append(line)
                i += 1; continue
            }

            let t = line.trimmingCharacters(in: .whitespaces)
            // A blank line ends a paragraph (Markdown's rule). Hal's original only skipped it, so separate
            // paragraphs were glued into one (found 2026-11-15 rendering the Thomas Guide; noted for Hal).
            if t.isEmpty { afterBlank = true; i += 1; continue }
            defer { afterBlank = false }

            // Headings: count leading # characters
            if t.first == "#" {
                let level = t.prefix(while: { $0 == "#" }).count
                let body = String(t.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(body, level: min(level, 4)))
                i += 1; continue
            }

            // GFM table: a "|"-bearing row immediately followed by a separator row.
            // Consume the header + separator + every following pipe row (until a blank
            // or non-pipe line). A "|" line without a separator underneath falls through
            // and renders as an ordinary paragraph (raw pipes), never lost.
            if t.contains("|"), i + 1 < lines.count, isSeparatorRow(lines[i + 1]) {
                let header = tableCells(t)
                var rows: [[String]] = []
                var j = i + 2
                while j < lines.count {
                    let rt = lines[j].trimmingCharacters(in: .whitespaces)
                    if rt.isEmpty || !rt.contains("|") { break }
                    rows.append(tableCells(rt))
                    j += 1
                }
                blocks.append(.table(header: header, rows: rows))
                i = j; continue
            }

            // Horizontal rule: a line of 3+ identical -, *, or _ and nothing else.
            if t.count >= 3, let f = t.first, f == "-" || f == "*" || f == "_", t.allSatisfy({ $0 == f }) {
                blocks.append(.rule)
                i += 1; continue
            }

            // Unordered list: starts with "- " or "* "
            if t.hasPrefix("- ") || t.hasPrefix("* ") {
                blocks.append(.unorderedItem(String(t.dropFirst(2))))
                i += 1; continue
            }

            // Ordered list: starts with one or more digits followed by ". "
            let leadingDigits = t.prefix(while: { $0.isNumber })
            if !leadingDigits.isEmpty {
                let afterDigits = t.dropFirst(leadingDigits.count)
                if afterDigits.hasPrefix(". ") {
                    let number = Int(String(leadingDigits)) ?? 1
                    let body = String(afterDigits.dropFirst(2))
                    blocks.append(.orderedItem(body, number: number))
                    i += 1; continue
                }
            }

            // Paragraph: merge consecutive non-blank, non-list lines (soft-wrap), never across a blank line
            if !afterBlank, case .paragraph(let prev) = blocks.last {
                blocks[blocks.count - 1] = .paragraph(prev + " " + t)
            } else {
                blocks.append(.paragraph(t))
            }
            i += 1
        }

        // Flush unclosed code block
        if let acc = codeAccum {
            blocks.append(.codeBlock(acc.joined(separator: "\n")))
        }

        return blocks
    }
}

extension Color {
    /// The find-in-page highlight (Hal's, ChatViews.swift).
    static let searchHighlight = Color.accentColor.opacity(0.4)
}

// ==== LEGO END: 42 MarkdownView (Block-Level Markdown Renderer) ====


// ==== LEGO START: 43 GuideReaderView (The Thomas Guide, In-App) ====
//
// Hal's GuideReaderView (LEGO 66 there), copied 2026-11-15 with only these changes: the search query lives
// on `GuideState` (Thomas has no ChatViewModel) so the antenna can drive it; it reads THOMAS_GUIDE.md and is
// titled "The Thomas Guide"; and it can open at a section, for the "?" cards' "More in the guide" links.

/// Whether the guide is open, where, and its find-in-page query: one place the screens and the antenna share.
@MainActor @Observable final class GuideState {
    static let shared = GuideState()
    var query = ""
    private init() {}
}

/// Keyword find-in-page bar pinned to the top of the reader. Pure bindings and
/// callbacks, no search logic (that lives in GuideReaderView), mirroring Posey's
/// SearchBarView. Dismissal of the whole reader is the navigation bar's Done, so this
/// bar carries only the query, the match readout, and next/prev.
private struct GuideSearchBar: View {
    @Binding var query: String
    let matchCount: Int
    /// 0-based position within the matches, nil when there is no query / no match.
    let currentMatchPosition: Int?
    let onPrevious: () -> Void
    let onNext: () -> Void

    @FocusState private var isFieldFocused: Bool

    private var hasQuery: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var matchLabel: String {
        guard hasQuery else { return "" }
        if matchCount == 0 { return "No matches" }
        let ordinal = (currentMatchPosition ?? 0) + 1
        return "\(ordinal) of \(matchCount)"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.footnote)
                .foregroundStyle(.secondary)

            TextField("Find in the guide", text: $query)
                // A tap anywhere on the bar's height focuses the field: the field itself is 28 pt, with space around
                // it that looked like field but took no tap (phone audit, 2026-11-15, item 67). A taller frame alone
                // grew only the space, not the field (re-audit), so the space behind the field takes the tap and
                // focuses it. The bar's padding gives the height back, so the bar looks the same.
                .frame(minHeight: 46)
                .background(Color.clear.contentShape(Rectangle()).onTapGesture { isFieldFocused = true })
                .focused($isFieldFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { isFieldFocused = false }

            if hasQuery {
                Text(matchLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()

                if matchCount > 0 {
                    Button(action: onPrevious) {
                        Image(systemName: "chevron.up")
                            .font(.footnote.weight(.semibold))
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel("Previous match")

                    Button(action: onNext) {
                        Image(systemName: "chevron.down")
                            .font(.footnote.weight(.semibold))
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel("Next match")
                }

                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .tint(.primary)
        .padding(.horizontal, 16)
        .padding(.vertical, 1)   // was 10 around a 28 pt field (48 pt); now 1 around the 46 pt field (48 pt)
        .background(.regularMaterial)
    }
}

struct GuideReaderView: View {
    @Environment(\.dismiss) private var dismiss
    // Query lives on GuideState so the antenna (POST /open X-Screen: guide, X-Query) can drive find-in-page
    // for headless verification, not just a human typing. Reset on close. (Hal keeps it on its ChatViewModel.)
    @State private var guide = GuideState.shared
    /// The guide's body size follows the reader's text-size setting (17 pt at the standard size, like body
    /// text). Hal passes a size its own slider picks; Thomas has no slider, so it takes the system's
    /// (accessibility audit, 2026-11-15: the guide's text didn't grow at all).
    @ScaledMetric(relativeTo: .body) private var guideBodySize: CGFloat = 17
    /// 0-based index INTO `matchIndices` (which chunk of the matching set we are on).
    @State private var currentMatch: Int? = nil

    // The guide split once into heading-delimited chunks. Each chunk is a scroll
    // target (its index is its `.id`) and the unit of a keyword match, the same
    // container-level model Posey uses (it matches whole segments, not occurrences).
    private let chunks: [String]
    /// GitHub-style anchor slug -> chunk index, so an internal cross-reference like
    /// "[Safe and Advanced](#safe-and-advanced)" scrolls to that section on tap.
    private let anchorToChunk: [String: Int]

    /// A section to open at (a heading's anchor, e.g. "the-developer-tray"), from a "?" card's link.
    private let openAt: String?

    init(openAt: String? = nil) {
        let loaded = Self.loadChunks()
        chunks = loaded
        anchorToChunk = Self.buildAnchorMap(loaded)
        self.openAt = openAt
    }

    private var trimmedQuery: String { guide.query.trimmingCharacters(in: .whitespaces) }

    /// Indices of the chunks that contain the query (case-insensitive). Cheap to
    /// recompute for ~80 chunks; kept as a computed value so it always tracks `query`.
    private var matchIndices: [Int] {
        guard !trimmedQuery.isEmpty else { return [] }
        return chunks.indices.filter { chunks[$0].localizedCaseInsensitiveContains(trimmedQuery) }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(chunks.indices, id: \.self) { i in
                            MarkdownView(text: chunks[i], bodyPointSize: guideBodySize, lineSpacing: 5, highlight: trimmedQuery)
                                .id(i)
                                .padding(.horizontal, 16)
                        }
                    }
                    .padding(.vertical, 16)
                    // A reading column in a wide window (Mac, iPad), as Thomas's other screens (2026-11-15).
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    GuideSearchBar(
                        query: $guide.query,
                        matchCount: matchIndices.count,
                        currentMatchPosition: currentMatch,
                        onPrevious: { step(-1, proxy: proxy) },
                        onNext: { step(1, proxy: proxy) }
                    )
                }
                .onChange(of: guide.query) { _, _ in
                    let matches = matchIndices
                    if let first = matches.first {
                        currentMatch = 0
                        scroll(to: first, proxy: proxy)
                    } else {
                        currentMatch = nil
                    }
                }
                .onAppear {
                    // Open at a section (a "?" card's link), or at the first match of a query set before
                    // the guide appeared (the antenna's X-Query), since onChange won't fire for that one.
                    if let first = matchIndices.first {
                        currentMatch = 0
                        DispatchQueue.main.async { proxy.scrollTo(first, anchor: .top) }
                    } else if let a = openAt?.lowercased(), let idx = anchorToChunk[a] {
                        DispatchQueue.main.async { proxy.scrollTo(idx, anchor: .top) }
                    }
                }
                .onDisappear {
                    guide.query = ""
                    currentMatch = nil
                }
                // Intercept taps on markdown links. An internal cross-reference
                // ("#section") scrolls to that chunk; external URLs (http/https/mailto)
                // open normally; anything else relative is swallowed so a stray link
                // can't open garbage.
                .environment(\.openURL, OpenURLAction { url in
                    let raw = url.fragment ?? (url.absoluteString.hasPrefix("#") ? String(url.absoluteString.dropFirst()) : "")
                    let anchor = raw.lowercased()
                    if !anchor.isEmpty, let idx = anchorToChunk[anchor] {
                        scroll(to: idx, proxy: proxy)
                        return .handled
                    }
                    return url.scheme == nil ? .handled : .systemAction
                })
            }
            .navigationTitle("The Thomas Guide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// Advance the current match by `direction` (+1 next, -1 previous), wrapping, and
    /// scroll its chunk into view. No-op when there are no matches.
    private func step(_ direction: Int, proxy: ScrollViewProxy) {
        let matches = matchIndices
        guard !matches.isEmpty else { return }
        let base = currentMatch ?? (direction > 0 ? -1 : 0)
        let next = ((base + direction) % matches.count + matches.count) % matches.count
        currentMatch = next
        scroll(to: matches[next], proxy: proxy)
    }

    private func scroll(to chunkIndex: Int, proxy: ScrollViewProxy) {
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo(chunkIndex, anchor: .top)
        }
    }

    /// GitHub-style heading slug: lowercased, non-alphanumerics dropped, runs of
    /// spaces/hyphens collapsed to a single hyphen, trimmed. "Safe and Advanced"
    /// becomes "safe-and-advanced", matching the anchors written in the guide.
    private static func slug(_ heading: String) -> String {
        var out = ""
        for ch in heading.lowercased() {
            if ch.isLetter || ch.isNumber { out.append(ch) }
            else if ch == " " || ch == "-" || ch == "_" { out.append("-") }
        }
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Map each chunk's first heading's anchor -> its index. First writer wins, so a
    /// repeated heading resolves to its first occurrence (as a browser would).
    private static func buildAnchorMap(_ chunks: [String]) -> [String: Int] {
        var map: [String: Int] = [:]
        for (i, chunk) in chunks.enumerated() {
            guard let headingLine = chunk.split(separator: "\n").first(where: { $0.hasPrefix("#") }) else { continue }
            var text = String(headingLine)
            while text.first == "#" { text.removeFirst() }
            let anchor = slug(text.trimmingCharacters(in: .whitespaces))
            if !anchor.isEmpty, map[anchor] == nil { map[anchor] = i }
        }
        return map
    }

    /// Load the bundled guide and split it into heading-delimited chunks: every line
    /// that is a heading of level >= 2 ("## " ... "###### ") starts a new chunk, and
    /// the title + intro before the first such heading is the opening chunk. Blank /
    /// whitespace-only chunks are dropped. Fenced code is respected so a "###" inside
    /// a code block never splits a chunk.
    private static func loadChunks() -> [String] {
        guard let path = Bundle.main.path(forResource: "THOMAS_GUIDE", ofType: "md"),
              let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            return ["# The Thomas Guide\n\nThe guide could not be loaded on this build."]
        }
        func isHeading(_ line: String) -> Bool {
            var h = 0
            for c in line { if c == "#" { h += 1 } else { break } }
            return h >= 2 && line.dropFirst(h).first == " "
        }
        var chunks: [String] = []
        var current: [String] = []
        var inFence = false
        for line in raw.components(separatedBy: "\n") {
            if line.hasPrefix("```") { inFence.toggle() }
            if !inFence, isHeading(line), !current.isEmpty {
                chunks.append(current.joined(separator: "\n"))
                current = []
            }
            current.append(line)
        }
        if !current.isEmpty { chunks.append(current.joined(separator: "\n")) }
        return chunks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

// ==== LEGO END: 43 GuideReaderView (The Thomas Guide, In-App) ====
