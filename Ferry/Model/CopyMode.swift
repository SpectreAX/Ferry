import Foundation

enum SettingsKeys {
    static let copyMode = "copyMode"
    static let hideMarkdownSyntax = "hideMarkdownSyntax"
    static let stripMarkdownOnCopy = "stripMarkdownOnCopy"
}

/// Editor and copy preferences (both off by default).
enum Preferences {
    /// Hide Markdown markers in the editor, except in the paragraph being edited. Display only.
    static var hideMarkdownSyntax: Bool { UserDefaults.standard.bool(forKey: SettingsKeys.hideMarkdownSyntax) }
    /// Copies to other apps leave out Markdown syntax. Pasting back into Ferry and ⌥⌘C keep it.
    static var stripMarkdownOnCopy: Bool { UserDefaults.standard.bool(forKey: SettingsKeys.stripMarkdownOnCopy) }
}

/// How ⌘C delivers a selection that contains images. Chromium apps (Claude, Codex desktop) can't take
/// clipboard text and files from one paste, so each mode is a different trade-off.
enum CopyMode: String, CaseIterable {
    /// First paste attaches the images, then the clipboard switches to the text for a second paste.
    case twoPastes
    /// One paste: the text as a `.md` file plus the image files, all as attachments.
    case attachments
    /// Experimental: one ⌘V in any app (learned per app, see `AppPasteRules`); Ferry drives the image and text
    /// pastes itself (needs Accessibility permission).
    case oneCommandV

    static var current: CopyMode {
        UserDefaults.standard.string(forKey: SettingsKeys.copyMode).flatMap(CopyMode.init(rawValue:)) ?? .twoPastes
    }
}
