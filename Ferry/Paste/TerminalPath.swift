import Foundation

/// File paths as a terminal's drag and drop types them, so AI CLIs (Claude Code, Codex) read a pasted path as one
/// file: shell-special characters are backslash-escaped (`ferry\ icon.png`).
enum TerminalPath {
    private static let special = Set(" \t\\'\"()[]{}<>&;|$`!*?#~")

    static func escaped(_ path: String) -> String {
        var result = ""
        for character in path {
            if special.contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }
}
