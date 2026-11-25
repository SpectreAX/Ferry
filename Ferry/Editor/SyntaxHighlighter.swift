import AppKit

extension NSAttributedString.Key {
    /// Markup that "Hide Markdown Syntax" may hide: heading #s, emphasis and code delimiters, link brackets
    /// and targets, escapes. Structural markers (lists, quotes, fences, rules, tables) only get dimmed.
    static let ferryHideableMarker = NSAttributedString.Key("dev.spectreax.ferry.hideableMarker")
}

/// Markdown styling (CommonMark + GFM) by font and color only: the text is never changed.
/// Headings, emphasis, strikethrough, code (inline and fenced), quotes, lists and tasks, links and
/// autolinks, rules, tables, HTML and escapes. Markup characters are dimmed; nothing is styled inside code.
/// Callers must not restyle while an input method has marked text.
final class SyntaxHighlighter {
    struct Fence: Equatable {
        var range: NSRange      // the whole block, fence lines included
        var fenceLines: [NSRange]
    }

    private var fenceLineCount = -1

    /// Restyles the whole document.
    func highlightAll(_ storage: NSTextStorage) {
        let fences = Self.fencedBlocks(in: storage.string as NSString)
        fenceLineCount = fences.reduce(0) { $0 + $1.fenceLines.count }
        Self.style(storage, in: NSRange(location: 0, length: storage.length), fences: fences)
    }

    /// Restyles what an edit can affect: the edited paragraphs plus one on each side (setext headings),
    /// whole code blocks they touch, or everything when a code fence line was added or removed.
    func update(_ storage: NSTextStorage, edited range: NSRange) {
        let string = storage.string as NSString
        let fences = Self.fencedBlocks(in: string)
        let count = fences.reduce(0) { $0 + $1.fenceLines.count }
        guard count == fenceLineCount else {
            fenceLineCount = count
            return Self.style(storage, in: NSRange(location: 0, length: string.length), fences: fences)
        }
        let location = min(range.location, string.length)
        var affected = string.paragraphRange(for: NSRange(location: location, length: min(range.length, string.length - location)))
        if affected.location > 0 {
            affected = NSUnionRange(affected, string.paragraphRange(for: NSRange(location: affected.location - 1, length: 0)))
        }
        if NSMaxRange(affected) < string.length {
            affected = NSUnionRange(affected, string.paragraphRange(for: NSRange(location: NSMaxRange(affected), length: 0)))
        }
        for fence in fences where NSIntersectionRange(fence.range, affected).length > 0 || NSLocationInRange(affected.location, fence.range) {
            affected = NSUnionRange(affected, fence.range)
        }
        Self.style(storage, in: affected, fences: fences)
    }

    // MARK: Fenced code blocks

    private static let fenceLine = try! NSRegularExpression(pattern: #"^ {0,3}(`{3,}|~{3,})(.*)$"#)

    /// ``` or ~~~ blocks; an unclosed fence runs to the end of the document.
    static func fencedBlocks(in string: NSString) -> [Fence] {
        var fences: [Fence] = []
        var open: (start: Int, line: NSRange, marker: String)?
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byLines, .substringNotRequired]) {
            _, line, enclosing, _ in
            let text = string.substring(with: line)
            guard let match = fenceLine.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else { return }
            let marker = (text as NSString).substring(with: match.range(at: 1))
            let rest = (text as NSString).substring(with: match.range(at: 2))
            if let current = open {
                // Closes with the same character, at least as long, and nothing after it.
                guard marker.first == current.marker.first, marker.count >= current.marker.count,
                      rest.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                fences.append(Fence(range: NSRange(location: current.start, length: NSMaxRange(enclosing) - current.start),
                                    fenceLines: [current.line, line]))
                open = nil
            } else if !(marker.first == "`" && rest.contains("`")) {
                open = (line.location, line, marker)
            }
        }
        if let current = open {
            fences.append(Fence(range: NSRange(location: current.start, length: string.length - current.start), fenceLines: [current.line]))
        }
        return fences
    }

    // MARK: Styling

    static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    // Block level, matched per line.
    static let atxHeading = regex(#"^ {0,3}(#{1,6})(?:[ \t]+|$)(.*?)(?:[ \t]+#+)?[ \t]*$"#)
    static let setextUnderline = regex(#"^ {0,3}(=+|-+)[ \t]*$"#)
    static let rule = regex(#"^ {0,3}(?:(?:\*[ \t]*){3,}|(?:-[ \t]*){3,}|(?:_[ \t]*){3,})$"#)
    static let quote = regex(#"^ {0,3}(?:>[ \t]?)+"#)
    private static let listItem = regex(#"^[ \t]*(?:[-*+]|\d{1,9}[.)])[ \t]+(\[[ xX]\][ \t]+)?"#)
    static let tableSeparator = regex(#"^[ \t]*\|?[ \t]*:?-+:?[ \t]*(?:\|[ \t]*:?-+:?[ \t]*)+\|?[ \t]*$"#)
    private static let tableRow = regex(#"^[ \t]*\|"#)
    static let pipe = regex(#"(?<!\\)\|"#)

    // Inline.
    static let codeSpan = regex(#"(?<!`)(`+)(?!`)(.+?)(?<!`)\1(?!`)"#)
    private static let link = regex(#"(!?\[)([^\]\n]*)(\]\([^)\n]*\))"#)
    private static let autolink = regex(#"<(?:https?://|mailto:)[^>\s]+>|(?<![<(\w/])https?://[^\s<>()\[\]]+"#)
    static let boldStars = regex(#"(?<!\\)\*\*(?=\S)(.+?)(?<=\S)(?<!\\)\*\*"#)
    /// Like `_`, `__` doesn't work inside a word: `snake__double__name` stays as it is.
    static let boldUnderscores = regex(#"(?<![\w\\])__(?=\S)(.+?)(?<=\S)__(?!\w)"#)
    static let italic = regex(#"(?<![*\w\\])\*(?=[^\s*])(.+?)(?<=[^\s*\\])\*(?![*\w])|(?<![_\w\\])_(?=[^\s_])(.+?)(?<=[^\s_\\])_(?![_\w])"#)
    private static let strike = regex(#"(?<!\\)~~(?=\S)(.+?)(?<=\S)~~"#)
    private static let html = regex(#"<!--.*?-->|</?[A-Za-z][A-Za-z0-9-]*(?:\s[^<>\n]*)?/?>"#)
    static let escape = regex(#"\\(?=[\\`*_{}\[\]()#+\-.!|~<>])"#)

    static func style(_ storage: NSTextStorage, in range: NSRange, fences: [Fence]) {
        let string = storage.string as NSString
        guard string.length > 0, range.length > 0 else { return }
        let range = NSIntersectionRange(range, NSRange(location: 0, length: string.length))

        storage.beginEditing()
        defer { storage.endEditing() }
        storage.addAttributes([.font: EditorStyle.bodyFont, .foregroundColor: NSColor.textColor], range: range)
        storage.removeAttribute(.strikethroughStyle, range: range)
        storage.removeAttribute(.backgroundColor, range: range)
        storage.removeAttribute(.ferryHideableMarker, range: range)

        var protected: [NSRange] = []
        for fence in fences where NSIntersectionRange(fence.range, range).length > 0 {
            let block = NSIntersectionRange(fence.range, range)
            storage.addAttribute(.font, value: EditorStyle.codeFont, range: block)
            for line in fence.fenceLines { dim(storage, NSIntersectionRange(line, range)) }
            protected.append(fence.range)
        }

        styleBlocks(storage, string, in: range, protected: protected)
        styleInline(storage, string, in: range, protected: &protected)
    }

    private static func styleBlocks(_ storage: NSTextStorage, _ string: NSString, in range: NSRange, protected: [NSRange]) {
        var lines: [NSRange] = []
        string.enumerateSubstrings(in: range, options: [.byLines, .substringNotRequired]) { _, line, _, _ in lines.append(line) }

        for (index, line) in lines.enumerated() where !overlaps(line, protected) {
            let text = string.substring(with: line) as NSString
            let local = NSRange(location: 0, length: text.length)
            func shifted(_ r: NSRange) -> NSRange { NSRange(location: line.location + r.location, length: r.length) }

            if let match = atxHeading.firstMatch(in: text as String, range: local) {
                storage.addAttribute(.font, value: EditorStyle.headingFont(level: match.range(at: 1).length), range: line)
                let content = match.range(at: 2)
                if content.length > 0 {
                    // The #s and the space after them, so a hidden heading doesn't start with a gap.
                    hideable(storage, shifted(NSRange(location: 0, length: content.location)))
                } else {
                    dim(storage, shifted(match.range(at: 1)))
                }
                let closing = NSRange(location: NSMaxRange(content), length: NSMaxRange(local) - NSMaxRange(content))
                if closing.length > 0 { content.length > 0 ? hideable(storage, shifted(closing)) : dim(storage, shifted(closing)) }
                continue
            }
            // Setext: a text line followed by === (level 1) or --- (level 2).
            if index + 1 < lines.count, text.trimmingCharacters(in: .whitespaces).count > 0,
               quote.firstMatch(in: text as String, range: local) == nil, listItem.firstMatch(in: text as String, range: local) == nil,
               rule.firstMatch(in: text as String, range: local) == nil {
                let next = string.substring(with: lines[index + 1])
                if let underline = setextUnderline.firstMatch(in: next, range: NSRange(location: 0, length: (next as NSString).length)) {
                    let level = (next as NSString).substring(with: underline.range(at: 1)).hasPrefix("=") ? 1 : 2
                    storage.addAttribute(.font, value: EditorStyle.headingFont(level: level), range: line)
                    continue
                }
            }
            if setextUnderline.firstMatch(in: text as String, range: local) != nil, index > 0,
               string.substring(with: lines[index - 1]).trimmingCharacters(in: .whitespaces).count > 0,
               rule.firstMatch(in: string.substring(with: lines[index - 1]), range: NSRange(location: 0, length: lines[index - 1].length)) == nil {
                dim(storage, line) // the underline of a setext heading
                continue
            }
            if rule.firstMatch(in: text as String, range: local) != nil {
                dim(storage, line)
                continue
            }
            if let match = quote.firstMatch(in: text as String, range: local) {
                storage.addAttribute(.foregroundColor, value: EditorStyle.quoteColor, range: line)
                dim(storage, shifted(match.range))
            }
            if let match = listItem.firstMatch(in: text as String, range: local) {
                dim(storage, shifted(match.range))
                let task = match.range(at: 1)
                if task.location != NSNotFound, text.substring(with: task).lowercased().contains("x") {
                    let done = NSRange(location: NSMaxRange(match.range), length: local.length - NSMaxRange(match.range))
                    storage.addAttribute(.foregroundColor, value: EditorStyle.quoteColor, range: shifted(done))
                }
            }
            if tableSeparator.firstMatch(in: text as String, range: local) != nil {
                dim(storage, line)
            } else if tableRow.firstMatch(in: text as String, range: local) != nil {
                for match in pipe.matches(in: text as String, range: local) { dim(storage, shifted(match.range)) }
            }
        }
    }

    private static func styleInline(_ storage: NSTextStorage, _ string: NSString, in range: NSRange, protected: inout [NSRange]) {
        let text = string as String
        func each(_ regex: NSRegularExpression, _ body: (NSTextCheckingResult) -> Void) {
            for match in regex.matches(in: text, range: range) where !overlaps(match.range, protected) { body(match) }
        }

        // Code first: nothing inside it is styled.
        each(codeSpan) { match in
            storage.addAttribute(.font, value: EditorStyle.codeFont, range: match.range(at: 2))
            storage.addAttribute(.backgroundColor, value: EditorStyle.codeBackground, range: match.range(at: 2))
            hideable(storage, match.range(at: 1))
            hideable(storage, NSRange(location: NSMaxRange(match.range(at: 2)), length: match.range(at: 1).length))
        }
        protected += codeSpan.matches(in: text, range: range).map(\.range)

        each(html) { dim(storage, $0.range) }
        each(link) { match in
            // An image link (`![alt](url)`, not yet downloaded or missing) stays visible: hiding it would
            // leave nothing, or just the alt text, where the image should be.
            let mark: (NSTextStorage, NSRange) -> Void = match.range(at: 1).length == 1 ? hideable : dim
            mark(storage, match.range(at: 1))
            storage.addAttribute(.foregroundColor, value: EditorStyle.linkColor, range: match.range(at: 2))
            mark(storage, match.range(at: 3))
        }
        each(autolink) { storage.addAttribute(.foregroundColor, value: EditorStyle.linkColor, range: $0.range) }
        for bold in [boldStars, boldUnderscores] {
            each(bold) { match in
                addTrait(.boldFontMask, storage, match.range)
                hideable(storage, NSRange(location: match.range.location, length: 2))
                hideable(storage, NSRange(location: NSMaxRange(match.range) - 2, length: 2))
            }
        }
        each(italic) { match in
            addTrait(.italicFontMask, storage, match.range)
            hideable(storage, NSRange(location: match.range.location, length: 1))
            hideable(storage, NSRange(location: NSMaxRange(match.range) - 1, length: 1))
        }
        each(strike) { match in
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: match.range(at: 1))
            hideable(storage, NSRange(location: match.range.location, length: 2))
            hideable(storage, NSRange(location: NSMaxRange(match.range) - 2, length: 2))
        }
        each(escape) { hideable(storage, $0.range) }
    }

    // MARK: Helpers

    private static func dim(_ storage: NSTextStorage, _ range: NSRange) {
        guard range.length > 0, range.location != NSNotFound else { return }
        storage.addAttribute(.foregroundColor, value: EditorStyle.markerColor, range: range)
    }

    /// Dimmed, and hidden when "Hide Markdown Syntax" is on.
    private static func hideable(_ storage: NSTextStorage, _ range: NSRange) {
        guard range.length > 0, range.location != NSNotFound else { return }
        dim(storage, range)
        storage.addAttribute(.ferryHideableMarker, value: true, range: range)
    }

    private static func addTrait(_ trait: NSFontTraitMask, _ storage: NSTextStorage, _ range: NSRange) {
        storage.enumerateAttribute(.font, in: range) { value, sub, _ in
            let font = (value as? NSFont) ?? EditorStyle.bodyFont
            storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: trait), range: sub)
        }
    }

    private static func overlaps(_ range: NSRange, _ ranges: [NSRange]) -> Bool {
        ranges.contains { NSIntersectionRange($0, range).length > 0 }
    }
}
