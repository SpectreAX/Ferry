import Foundation

/// What Ferry sees of the target's message box through Accessibility: the focused input's text length
/// and, for each of its nearest ancestors, how many images and buttons it contains.
/// Comparing two snapshots is how a paste is confirmed; a data request alone proves nothing.
struct TargetSnapshot: Equatable {
    struct Level: Equatable {
        var images: Int
        var buttons: Int
    }

    var valueLength: Int
    /// Ancestors of the focused input, nearest first.
    var levels: [Level]
    var focusedRole: String? = "AXTextArea"
    var focusedSubrole: String? = nil

    /// Why the focused field can't take a One ⌘V paste (images + text), if it can't. Message boxes are
    /// multi-line (`AXTextArea`, or a group in some web editors); these get a normal paste instead.
    var unsuitableReason: String? {
        if focusedSubrole == "AXSecureTextField" { return "password field" }
        if focusedSubrole == "AXSearchField" { return "search field" }
        if ["AXTextField", "AXComboBox"].contains(focusedRole ?? "") { return "single-line field" }
        return nil
    }

    /// The input's text length changed.
    func textChanged(since base: TargetSnapshot) -> Bool { valueLength != base.valueLength }

    /// The largest number of new images or buttons at any nearby level: a new attachment of some kind.
    func attachmentGain(since base: TargetSnapshot) -> Int {
        zip(levels, base.levels).map { max($0.images - $1.images, $0.buttons - $1.buttons) }.max() ?? 0
    }

    /// Per level, the higher count of the two snapshots (text and roles from `self`): a reference that a
    /// momentary redraw in either one can't lower.
    func mergedMax(with other: TargetSnapshot) -> TargetSnapshot {
        var merged = self
        merged.levels = zip(levels, other.levels).map { Level(images: max($0.images, $1.images), buttons: max($0.buttons, $1.buttons)) }
        return merged
    }

    var summary: String {
        "chars=\(valueLength) " + levels.enumerated().map { "L\($0.offset + 1)=\($0.element.images)i/\($0.element.buttons)b" }
            .joined(separator: " ")
    }
}
