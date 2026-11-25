import Foundation

/// Plain text from Markdown, for "Ignore Markdown Syntax When Copying": the markup goes, the words stay.
/// - Blocks: heading #s, setext underlines, rules, quote >s, bullets and task boxes, fence lines and table
///   separator rows are removed; table cells become tab-separated; ordered-list numbers stay.
/// - Inline: emphasis, strikethrough and code delimiters, links (their text stays), unresolved images (their
///   alt text stays), autolink brackets and escape backslashes are removed.
/// Code (fenced blocks and code spans) is kept exactly as written. Uses the editor's own patterns
/// (`SyntaxHighlighter`), so what is stripped is what the editor shows as syntax.
enum MarkdownStripper {
    private typealias H = SyntaxHighlighter

    private static let listMarker = H.regex(#"^([ \t]*)(?:[-*+]|(\d{1,9}[.)]))([ \t]+)(?:\[[ xX]\][ \t]+)?"#)
    private static let link = H.regex(#"!?\[([^\]\n]*)\]\([^)\n]*\)"#)
    private static let angleAutolink = H.regex(#"<((?:https?://|mailto:)[^>\s]+)>"#)
    private static let strike = H.regex(#"(?<!\\)~~(?=\S)(.+?)(?<=\S)~~"#)
    private static let escaped = H.regex(#"\\([\\`*_{}\[\]()#+\-.!|~<>])"#)
    private static let codeToken = H.regex("\u{E010}(\\d+)\u{E011}")

    static func strip(_ markdown: String) -> String {
        let string = markdown as NSString
        let fences = H.fencedBlocks(in: string)
        let fenceLines = Set(fences.flatMap(\.fenceLines).map(\.location))

        var output = ""
        var run: [Line] = [] // consecutive lines outside code blocks
        func flush() {
            output += stripBlocks(run)
            run = []
        }
        var start = 0
        while start < string.length {
            var end = 0, contentsEnd = 0
            string.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: start, length: 0))
            let line = Line(text: string.substring(with: NSRange(location: start, length: contentsEnd - start)),
                            terminator: string.substring(with: NSRange(location: contentsEnd, length: end - contentsEnd)))
            if fenceLines.contains(start) {
                flush() // a fence line goes entirely
            } else if fences.contains(where: { NSLocationInRange(start, $0.range) }) {
                flush()
                output += line.text + line.terminator // code stays exactly as written
            } else {
                run.append(line)
            }
            start = end
        }
        flush()
        return output
    }

    private struct Line {
        var text: String
        var terminator: String
    }

    // MARK: Blocks

    private static func stripBlocks(_ lines: [Line]) -> String {
        func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
            regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
        }
        func isBlank(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespaces).isEmpty }

        // Tables: a header row followed by a separator row, then rows until a line without a pipe.
        var tableRows = Set<Int>(), separators = Set<Int>()
        var index = 0
        while index + 1 < lines.count {
            if lines[index].text.contains("|"), matches(H.tableSeparator, lines[index + 1].text) {
                tableRows.insert(index)
                separators.insert(index + 1)
                var row = index + 2
                while row < lines.count, lines[row].text.contains("|"), !isBlank(lines[row].text) {
                    tableRows.insert(row)
                    row += 1
                }
                index = row
            } else {
                index += 1
            }
        }

        var output = ""
        for (index, line) in lines.enumerated() {
            let text = line.text
            if separators.contains(index) || matches(H.rule, text) { continue }
            if matches(H.setextUnderline, text), index > 0, !isBlank(lines[index - 1].text) { continue }

            let result: String
            if tableRows.contains(index) {
                result = tableRow(text)
            } else if let heading = H.atxHeading.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
                result = (text as NSString).substring(with: heading.range(at: 2))
            } else {
                result = listItem(H.quote.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length),
                                                                   withTemplate: ""))
            }
            output += inline(result) + line.terminator
        }
        return output
    }

    /// `  - [ ] item` → `  item`; `1. [x] step` → `1. step` (numbers are content, bullets and boxes are not).
    private static func listItem(_ text: String) -> String {
        let ns = text as NSString
        guard let match = listMarker.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return text }
        let indent = ns.substring(with: match.range(at: 1))
        let number = match.range(at: 2).location == NSNotFound ? "" : ns.substring(with: match.range(at: 2)) + ns.substring(with: match.range(at: 3))
        return indent + number + ns.substring(from: NSMaxRange(match.range))
    }

    /// `| a | b |` → `a\tb`.
    private static func tableRow(_ text: String) -> String {
        var row = text.trimmingCharacters(in: .whitespaces)
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|"), !row.hasSuffix("\\|") { row.removeLast() }
        let ns = row as NSString
        var cells: [String] = []
        var cursor = 0
        for pipe in H.pipe.matches(in: row, range: NSRange(location: 0, length: ns.length)) {
            cells.append(ns.substring(with: NSRange(location: cursor, length: pipe.range.location - cursor)))
            cursor = NSMaxRange(pipe.range)
        }
        cells.append(ns.substring(from: cursor))
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\t")
    }

    // MARK: Inline

    static func inline(_ text: String) -> String {
        // Code spans first: their content is set aside so nothing inside them is touched.
        var codes: [String] = []
        var result = replace(H.codeSpan, in: text) { match, ns in
            codes.append(ns.substring(with: match.range(at: 2)))
            return "\u{E010}\(codes.count - 1)\u{E011}"
        }
        result = replace(link, in: result) { match, ns in ns.substring(with: match.range(at: 1)) }
        result = replace(angleAutolink, in: result) { match, ns in ns.substring(with: match.range(at: 1)) }
        for _ in 0..<3 { // nested emphasis (***both***, **bold *italic***) unwraps one level per round
            let before = result
            for regex in [H.boldStars, H.boldUnderscores, strike] {
                result = replace(regex, in: result) { match, ns in ns.substring(with: match.range(at: 1)) }
            }
            result = replace(H.italic, in: result) { match, ns in
                ns.substring(with: match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2))
            }
            if result == before { break }
        }
        result = replace(escaped, in: result) { match, ns in ns.substring(with: match.range(at: 1)) }
        return replace(codeToken, in: result) { match, ns in
            // Only tokens made above; the same characters typed into the text stay as they are.
            let index = Int(ns.substring(with: match.range(at: 1))) ?? -1
            return codes.indices.contains(index) ? codes[index] : ns.substring(with: match.range)
        }
    }

    /// Replaces each match with `transform`'s result, inserted literally.
    private static func replace(_ regex: NSRegularExpression, in text: String,
                                _ transform: (NSTextCheckingResult, NSString) -> String) -> String {
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += transform(match, ns)
            cursor = NSMaxRange(match.range)
        }
        return result + ns.substring(from: cursor)
    }
}

extension Fragment {
    /// The same content with Markdown syntax removed from the text; images are untouched. The text is
    /// stripped as a whole (images stand in as tokens), so syntax around an image is read in context.
    func strippingMarkdown() -> Fragment {
        func token(_ index: Int) -> String { "\u{E020}\(index)\u{E021}" }
        let joined = segments.enumerated().map { index, segment in segment.image == nil ? segment.text ?? "" : token(index) }.joined()
        var rest = Substring(MarkdownStripper.strip(joined))
        var result: [Segment] = []
        for (index, segment) in segments.enumerated() where segment.image != nil {
            guard let found = rest.range(of: token(index)) else {
                // Syntax swallowed an image token (very unusual): strip each text run on its own instead.
                var copy = self
                copy.segments = segments.map { $0.image == nil ? Segment(text: MarkdownStripper.strip($0.text ?? "")) : $0 }
                return copy
            }
            if found.lowerBound > rest.startIndex { result.append(Segment(text: String(rest[..<found.lowerBound]))) }
            result.append(segment)
            rest = rest[found.upperBound...]
        }
        if !rest.isEmpty { result.append(Segment(text: String(rest))) }
        var copy = self
        copy.segments = result
        return copy
    }
}
