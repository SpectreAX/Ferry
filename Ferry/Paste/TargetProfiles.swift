import Foundation

/// Apps where One ⌘V never takes over ⌘V: Ferry itself, password managers, Finder (⌘V copies files there) and
/// system security prompts. Every other app is eligible; `AppPasteRules` decides per app.
enum TargetProfiles {
    /// Terminals get One ⌘V in its terminal form: each image goes in as its file path (Claude Code and Codex
    /// turn a pasted image path into an attachment), then the text. Only ⌘V, never ⌃V: in a shell ⌃V is
    /// quoted-insert, which would swallow the start of the next paste and let its lines run as commands.
    static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "dev.warp.Warp-Preview", "com.github.wez.wezterm", "io.alacritty", "org.alacritty", "net.kovidgoyal.kitty",
        "co.zeit.hyper", "com.raphaelamorim.rio",
    ]

    static func isTerminal(_ bundleID: String?) -> Bool { bundleID.map(terminals.contains) ?? false }

    static let excluded: Set<String> = [
        "dev.spectreax.ferry",
        // Passwords and security prompts
        "com.apple.Passwords", "com.apple.keychainaccess", "com.1password.1password", "com.agilebits.onepassword7",
        "com.bitwarden.desktop", "com.apple.SecurityAgent", "com.apple.loginwindow", "com.apple.SecurityAgentHelper.arm64",
        "com.apple.SecurityAgentHelper.x86_64",
        // Files and system UI
        "com.apple.finder", "com.apple.Spotlight", "com.apple.systempreferences", "com.apple.dock",
    ]

    static func isExcluded(_ bundleID: String?) -> Bool {
        guard let bundleID else { return true }
        return excluded.contains(bundleID)
    }
}
