import Foundation

/// Pure helpers for ⌘B / ⌘I / ⌘K and pasting a link over selected text.
enum MarkdownFormatting {
    /// A single http(s) URL and nothing else (no spaces, one line), as typed or copied from a browser.
    static func httpURL(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              !(url.host ?? "").isEmpty else { return nil }
        return trimmed
    }

    /// How many `*` sit right before `index` (looking left) or from it (looking right), up to three.
    static func stars(in text: NSString, from index: Int, forward: Bool) -> Int {
        var count = 0
        var i = forward ? index : index - 1
        while count < 3, i >= 0, i < text.length, text.character(at: i) == 42 { // "*"
            count += 1
            i += forward ? 1 : -1
        }
        return count
    }

    /// Whether `count` stars on both sides make the emphasis `marker` stands for: `**` needs 2 or 3, `*` 1 or 3.
    static func isWrapped(stars count: Int, marker: String) -> Bool {
        marker == "**" ? count >= 2 : count == 1 || count == 3
    }
}
