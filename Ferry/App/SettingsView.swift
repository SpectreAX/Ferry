import SwiftUI

struct SettingsView: View {
    @AppStorage(SettingsKeys.copyMode) private var copyMode = CopyMode.twoPastes
    @State private var isTrusted = SystemPasteEnvironment.isTrusted
    @State private var apps = SettingsView.appRows()
    private let trustTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Picker("When a copy includes images", selection: $copyMode) {
                Text("Paste twice: images, then text").tag(CopyMode.twoPastes)
                Text("Paste once: text as a .md attachment").tag(CopyMode.attachments)
                Text("One ⌘V (experimental, any app)").tag(CopyMode.oneCommandV)
            }
            .pickerStyle(.radioGroup)

            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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
                        Text("Turn on Ferry in the Accessibility list. If Ferry isn't listed, drag Ferry.app into the list.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                appList
                LabeledContent("Test log") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([PasteLog.fileURL])
                    }
                    .disabled(!FileManager.default.fileExists(atPath: PasteLog.fileURL.path))
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(trustTimer) { _ in isTrusted = SystemPasteEnvironment.isTrusted }
        .onReceive(NotificationCenter.default.publisher(for: AppPasteRules.didChange)) { _ in apps = Self.appRows() }
    }

    private struct AppRow: Identifiable {
        let id: String
        let rule: AppPasteRules.Rule
    }

    private static func appRows() -> [AppRow] {
        AppPasteRules.shared.all.map { AppRow(id: $0.bundleID, rule: $0.rule) }
    }

    /// Apps Ferry has learned or you have set. Apps not listed get One ⌘V and are learned on first use.
    @ViewBuilder private var appList: some View {
        if apps.isEmpty {
            LabeledContent("Apps", value: "Learned on first paste")
        } else {
            ForEach(apps) { app in
                LabeledContent {
                    HStack(spacing: 8) {
                        Picker(app.rule.name, selection: Binding(
                            get: { app.rule.mode },
                            set: { AppPasteRules.shared.setMode($0, for: app.id, name: app.rule.name) }
                        )) {
                            Text("One ⌘V").tag(AppPasteRules.Mode.oneCommandV)
                            Text("Normal paste").tag(AppPasteRules.Mode.normalPaste)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        Button("Reset") { AppPasteRules.shared.setMode(nil, for: app.id, name: app.rule.name) }
                            .help("Forget this app; Ferry learns it again on the next paste")
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.rule.name)
                        Text(app.rule.setByUser ? "Set by you" : "Learned")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var explanation: String {
        switch copyMode {
        case .twoPastes:
            return "The first paste attaches the images. Ferry then switches the clipboard to the text, so your second paste puts it in the message box, with images shown as [Image 1], [Image 2]. Clipboard managers that read the clipboard right away can trigger the switch early."
        case .attachments:
            return "One paste attaches everything: the text as a .md file plus each image. Desktop apps like Claude and Codex can't take clipboard text and image files from the same paste."
        case .oneCommandV:
            return "Press ⌘V once in any app's message box: Ferry pastes the images, waits until the app shows them, then pastes the text. It never presses Return; if a step can't be confirmed it stops and leaves the text on the clipboard. Ferry learns which apps this works in and gives the others a normal paste (text as a .md attachment). Terminals, Finder, password and single-line fields always get a normal paste."
        }
    }
}
