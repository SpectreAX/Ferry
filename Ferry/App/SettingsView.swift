import SwiftUI

struct SettingsView: View {
    @AppStorage(SettingsKeys.copyMode) private var copyMode = CopyMode.twoPastes
    @AppStorage(SettingsKeys.hideMarkdownSyntax) private var hideMarkdownSyntax = false
    @AppStorage(SettingsKeys.stripMarkdownOnCopy) private var stripMarkdownOnCopy = false
    @State private var isTrusted = SystemPasteEnvironment.isTrusted
    private let trustTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Markdown") {
                Toggle("Hide Markdown syntax", isOn: $hideMarkdownSyntax)
                Toggle("Ignore Markdown syntax when copying", isOn: $stripMarkdownOnCopy)
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
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(trustTimer) { _ in isTrusted = SystemPasteEnvironment.isTrusted }
    }
}
