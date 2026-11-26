import Foundation

/// What Return does in a Markdown list or quote: continue it on the next line, or end it on an empty item.
enum ListContinuation {
    enum Action: Equatable {
        /// Insert this text at the caret (starts with a newline).
        case insert(String)
        /// The item is empty: remove its marker (the first `length` characters of the line) instead of a newline.
        case end(markerLength: Int)
    }

    private static let item = try! NSRegularExpression(pattern: #"^([ \t]*)(?:([-*+])|(\d{1,9})([.)]))([ \t]+)(\[[ xX]\][ \t]+)?"#)
    private static let quote = try! NSRegularExpression(pattern: #"^[ \t]{0,3}(?:>[ \t]?)+"#)
    private static let rule = try! NSRegularExpression(pattern: #"^ {0,3}(?:(?:\*[ \t]*){3,}|(?:-[ \t]*){3,}|(?:_[ \t]*){3,})$"#)

    /// `line` is the text of the current line before the caret; `rest` is what follows the caret on that line.
    static func action(line: String, rest: String) -> Action? {
        let ns = line as NSString
        let all = NSRange(location: 0, length: ns.length)
        guard rule.firstMatch(in: line, range: all) == nil else { return nil }

        if let match = item.firstMatch(in: line, range: all) {
            let content = ns.substring(from: NSMaxRange(match.range))
            if content.trimmingCharacters(in: .whitespaces).isEmpty {
                return rest.trimmingCharacters(in: .whitespaces).isEmpty ? .end(markerLength: match.range.length) : nil
            }
            let indent = ns.substring(with: match.range(at: 1))
            let spacing = ns.substring(with: match.range(at: 5))
            let task = match.range(at: 6).location != NSNotFound ? "[ ] " : ""
            let marker: String
            if match.range(at: 2).location != NSNotFound {
                marker = ns.substring(with: match.range(at: 2))
            } else {
                let number = Int(ns.substring(with: match.range(at: 3))) ?? 0
                marker = "\(number + 1)" + ns.substring(with: match.range(at: 4))
            }
            return .insert("\n" + indent + marker + spacing + task)
        }

        if let match = quote.firstMatch(in: line, range: all) {
            let content = ns.substring(from: NSMaxRange(match.range))
            if content.trimmingCharacters(in: .whitespaces).isEmpty {
                return rest.trimmingCharacters(in: .whitespaces).isEmpty ? .end(markerLength: match.range.length) : nil
            }
            return .insert("\n" + ns.substring(with: match.range))
        }
        return nil
    }
}

/// Tab / ⇧Tab on lists and multi-line selections: two spaces per level.
enum ListIndentation {
    /// Per line: how many leading characters go, and how many spaces come in their place.
    struct LineChange: Equatable {
        let line: NSRange
        let removed: Int
        let added: Int
    }

    struct Edit: Equatable {
        /// The whole lines touched, and their new text (plain; the editor rebuilds it from `changes` so images stay).
        let range: NSRange
        let replacement: String
        let selection: NSRange
        let changes: [LineChange]
    }

    private static let unit = "  "
    private static let listItem = try! NSRegularExpression(pattern: #"^[ \t]*(?:[-*+]|\d{1,9}[.)])[ \t]+"#)

    /// Tab: indents a list item at the cursor, or every non-empty line of a multi-line selection. nil leaves Tab to
    /// the text view (a tab character).
    static func indent(in text: String, selection: NSRange) -> Edit? {
        let lines = lineRanges(in: text as NSString, covering: selection)
        let ns = text as NSString
        guard let first = lines.first else { return nil }
        if lines.count == 1 {
            let line = ns.substring(with: first)
            guard listItem.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil else { return nil }
        }
        let changes = lines.map { line -> LineChange in
            let isBlank = ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return LineChange(line: line, removed: 0, added: isBlank ? 0 : unit.utf16.count)
        }
        return edit(ns, changes, selection: selection)
    }

    /// ⇧Tab: removes one level (a tab, or up to two spaces) from each line the selection touches.
    static func outdent(in text: String, selection: NSRange) -> Edit? {
        let ns = text as NSString
        let changes = lineRanges(in: ns, covering: selection).map { line -> LineChange in
            let content = ns.substring(with: line)
            if content.hasPrefix("\t") { return LineChange(line: line, removed: 1, added: 0) }
            return LineChange(line: line, removed: content.prefix(2).prefix { $0 == " " }.count, added: 0)
        }
        guard changes.contains(where: { $0.removed > 0 }) else { return nil }
        return edit(ns, changes, selection: selection)
    }

    /// The lines a selection touches; a selection ending at the very start of a line leaves that line out.
    private static func lineRanges(in ns: NSString, covering selection: NSRange) -> [NSRange] {
        guard selection.location <= ns.length else { return [] }
        var end = NSMaxRange(selection)
        if selection.length > 0, end > selection.location, ns.lineRange(for: NSRange(location: end, length: 0)).location == end { end -= 1 }
        var lines: [NSRange] = []
        var location = ns.lineRange(for: NSRange(location: selection.location, length: 0)).location
        repeat {
            var contentsEnd = 0, lineEnd = 0
            ns.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            lines.append(NSRange(location: location, length: contentsEnd - location))
            location = lineEnd
        } while location <= end && location < ns.length
        return lines
    }

    private static func edit(_ ns: NSString, _ changes: [LineChange], selection: NSRange) -> Edit {
        let whole = NSRange(location: changes[0].line.location, length: NSMaxRange(changes[changes.count - 1].line) - changes[0].line.location)
        var replacement = ""
        var cursor = whole.location
        for change in changes {
            replacement += ns.substring(with: NSRange(location: cursor, length: change.line.location - cursor))
            replacement += String(repeating: " ", count: change.added)
            replacement += ns.substring(with: NSRange(location: change.line.location + change.removed, length: change.line.length - change.removed))
            cursor = NSMaxRange(change.line)
        }
        // Where an old position lands: moved by what was added or removed before it. A cursor at a line's start
        // moves with its text; a selection starting there grows to include the new indentation.
        func map(_ position: Int, includingLineStart: Bool) -> Int {
            var shift = 0
            for change in changes where change.line.location < position || includingLineStart && change.line.location == position {
                shift += change.added - min(change.removed, position - change.line.location)
            }
            return position + shift
        }
        let start = map(selection.location, includingLineStart: selection.length == 0)
        let end = selection.length == 0 ? start : map(NSMaxRange(selection), includingLineStart: true)
        return Edit(range: whole, replacement: replacement, selection: NSRange(location: start, length: max(0, end - start)), changes: changes)
    }
}
