import Foundation

/// Which paste each app gets in One ⌘V mode. Unknown apps get One ⌘V; results teach Ferry what works.
/// A rule the user sets is never changed by learning. Thread-safe: the keyboard tap reads it from its own thread.
final class AppPasteRules {
    enum Mode: String, Codable, CaseIterable {
        case oneCommandV
        case normalPaste
    }

    /// The result of one session, as far as it says something about the app.
    enum Outcome: Equatable {
        case worked
        case failed
    }

    struct Rule: Codable, Equatable {
        var name: String
        var mode: Mode
        var setByUser: Bool
        var failures: Int
    }

    static let shared = AppPasteRules(defaults: .standard)
    static let defaultsKey = "onePasteAppRules"
    static let didChange = Notification.Name("dev.spectreax.ferry.appPasteRulesChanged")
    /// Consecutive failures before an app is switched to a normal paste.
    static let failuresBeforeNormalPaste = 2
    /// Each tab is a different site, so one site's failures say nothing about the others: in browsers Ferry
    /// learns from successes only (unsuitable fields still get a normal paste, and you can set the mode).
    static let browsers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome", "com.google.Chrome.canary",
        "org.chromium.Chromium", "company.thebrowser.Browser", "com.microsoft.edgemac", "org.mozilla.firefox",
        "com.brave.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "app.zen-browser.zen",
    ]

    /// Verified apps, known to work before any learning.
    static let presets: [String: String] = [
        "com.anthropic.claudefordesktop": "Claude",
        "com.openai.codex": "ChatGPT",
        "com.openai.chat": "ChatGPT",
    ]

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var rules: [String: Rule]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        rules = (defaults.data(forKey: Self.defaultsKey)).flatMap { try? JSONDecoder().decode([String: Rule].self, from: $0) } ?? [:]
    }

    /// What ⌘V does in this app. Excluded apps always get a normal paste; unknown apps get One ⌘V.
    func mode(for bundleID: String?) -> Mode {
        guard let bundleID, !TargetProfiles.isExcluded(bundleID) else { return .normalPaste }
        lock.lock(); defer { lock.unlock() }
        return rules[bundleID]?.mode ?? .oneCommandV
    }

    /// Learns from a finished session. A success re-enables One ⌘V; repeated failures switch to a normal paste.
    func record(_ outcome: Outcome, for bundleID: String, name: String) {
        // Tabs in browsers and terminals each hold something different (a site; a shell or an AI CLI), so one
        // tab's failure says nothing about the others: there Ferry learns from successes only.
        let learnsOnlySuccess = Self.browsers.contains(bundleID) || TargetProfiles.isTerminal(bundleID)
        guard !TargetProfiles.isExcluded(bundleID), !(outcome == .failed && learnsOnlySuccess) else { return }
        update { rules in
            var rule = rules[bundleID] ?? Rule(name: Self.presets[bundleID] ?? name, mode: .oneCommandV, setByUser: false, failures: 0)
            guard !rule.setByUser else { return }
            switch outcome {
            case .worked:
                rule.failures = 0
                rule.mode = .oneCommandV
            case .failed:
                rule.failures += 1
                if rule.failures >= Self.failuresBeforeNormalPaste { rule.mode = .normalPaste }
            }
            rules[bundleID] = rule
        }
        PasteLog.write("learned \(bundleID): \(mode(for: bundleID).rawValue) after \(outcome)")
    }

    /// The user's choice for an app; nil returns it to automatic learning.
    func setMode(_ mode: Mode?, for bundleID: String, name: String) {
        update { rules in
            if let mode {
                rules[bundleID] = Rule(name: rules[bundleID]?.name ?? name, mode: mode, setByUser: true, failures: 0)
            } else {
                rules[bundleID] = nil
            }
        }
    }

    /// Known apps, for Settings, sorted by name.
    var all: [(bundleID: String, rule: Rule)] {
        lock.lock(); defer { lock.unlock() }
        return rules.map { ($0.key, $0.value) }.sorted { $0.rule.name.localizedCaseInsensitiveCompare($1.rule.name) == .orderedAscending }
    }

    private func update(_ change: (inout [String: Rule]) -> Void) {
        lock.lock()
        change(&rules)
        let data = try? JSONEncoder().encode(rules)
        lock.unlock()
        defaults.set(data, forKey: Self.defaultsKey)
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: self) }
    }
}
