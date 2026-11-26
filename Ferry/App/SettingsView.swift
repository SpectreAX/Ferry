import SwiftUI

struct SettingsView: View {
    @AppStorage(SettingsKeys.copyMode) private var copyMode = CopyMode.twoPastes
    @AppStorage(SettingsKeys.hideMarkdownSyntax) private var hideMarkdownSyntax = false
    @AppStorage(SettingsKeys.stripMarkdownOnCopy) private var stripMarkdownOnCopy = false
    @AppStorage(SettingsKeys.hideMarkdownSyntaxShortcut) private var hideShortcutRaw = AppShortcut.defaultHideMarkdown.storageString
    @AppStorage(SettingsKeys.stripMarkdownOnCopyShortcut) private var stripShortcutRaw = AppShortcut.defaultStripMarkdownOnCopy.storageString
    @State private var isTrusted = SystemPasteEnvironment.isTrusted
    @State private var shortcutError: String?
    private let trustTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var hideShortcut: AppShortcut? {
        AppShortcut.decode(hideShortcutRaw, default: .defaultHideMarkdown)
    }

    private var stripShortcut: AppShortcut? {
        AppShortcut.decode(stripShortcutRaw, default: .defaultStripMarkdownOnCopy)
    }

    var body: some View {
        Form {
            Section("Markdown") {
                shortcutRow(
                    title: "Hide Markdown syntax",
                    isOn: $hideMarkdownSyntax,
                    shortcut: Binding(
                        get: { hideShortcut },
                        set: { hideShortcutRaw = AppShortcut.encode($0) }
                    ),
                    otherShortcut: stripShortcut,
                    defaultShortcut: .defaultHideMarkdown
                )
                shortcutRow(
                    title: "Ignore Markdown syntax when copying",
                    isOn: $stripMarkdownOnCopy,
                    shortcut: Binding(
                        get: { stripShortcut },
                        set: { stripShortcutRaw = AppShortcut.encode($0) }
                    ),
                    otherShortcut: hideShortcut,
                    defaultShortcut: .defaultStripMarkdownOnCopy
                )
                if let shortcutError {
                    Text(shortcutError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                Picker("When a copy includes images", selection: $copyMode) {
                    Text("Paste twice: images, then text").tag(CopyMode.twoPastes)
                    Text("Paste once: text as a .md attachment").tag(CopyMode.attachments)
                    Text("One ⌘V: images and text together").tag(CopyMode.oneCommandV)
                }
                .pickerStyle(.radioGroup)

                if copyMode == .oneCommandV {
                    LabeledContent("Accessibility access") {
                        if isTrusted {
                            Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button("Open Settings…") { SystemPasteEnvironment.openAccessibilitySettings() }
                        }
                    }
                    if !isTrusted {
                        LabeledContent {
                            Button("Show Ferry.app") {
                                NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                            }
                        } label: {
                            Text("Turn on Ferry in the Accessibility list, or drag Ferry.app into it.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(trustTimer) { _ in isTrusted = SystemPasteEnvironment.isTrusted }
    }

    private func shortcutRow(
        title: String,
        isOn: Binding<Bool>,
        shortcut: Binding<AppShortcut?>,
        otherShortcut: AppShortcut?,
        defaultShortcut: AppShortcut
    ) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                ShortcutRecorderButton(
                    shortcut: shortcut,
                    otherShortcut: otherShortcut,
                    onError: { shortcutError = $0 }
                )
                if shortcut.wrappedValue != defaultShortcut {
                    Button {
                        shortcut.wrappedValue = defaultShortcut
                        shortcutError = nil
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Reset to default (\(defaultShortcut.displayString))")
                }
                Toggle("", isOn: isOn)
                    .labelsHidden()
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(shortcutDescription(for: shortcut.wrappedValue, default: defaultShortcut))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func shortcutDescription(for shortcut: AppShortcut?, default fallback: AppShortcut) -> String {
        guard let shortcut else { return "No shortcut (default: \(fallback.displayString))" }
        if shortcut == fallback { return "Shortcut: \(shortcut.displayString)" }
        return "Shortcut: \(shortcut.displayString) (default: \(fallback.displayString))"
    }
}
