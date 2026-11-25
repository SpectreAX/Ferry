import Foundation

/// Apps where One ⌘V never takes over ⌘V: Ferry itself, terminals (Claude Code pastes images there with ⌃V,
/// adapted separately), password managers, Finder (⌘V copies files there) and system security prompts.
/// Every other app is eligible; `AppPasteRules` decides per app.
enum TargetProfiles {
    static let excluded: Set<String> = [
        "dev.spectreax.ferry",
        // Terminals
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "com.github.wez.wezterm", "io.alacritty", "net.kovidgoyal.kitty", "co.zeit.hyper",
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
