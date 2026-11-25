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
