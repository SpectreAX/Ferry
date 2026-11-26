import AppKit
import SwiftUI

/// Native shortcut recorder pill for Settings. Clicking begins listening for a keyDown event;
/// bare Esc cancels, bare Delete clears, and invalid/reserved combinations beep and report an error.
struct ShortcutRecorderButton: View {
    @Binding var shortcut: AppShortcut?
    let otherShortcut: AppShortcut?
    let onError: (String?) -> Void

    @StateObject private var monitor = ShortcutMonitor()

    var body: some View {
        Button {
            if monitor.isRecording {
                monitor.stop()
                onError(nil)
            } else {
                onError(nil)
                monitor.start { event in
                    handleKeyDown(event)
                }
            }
        } label: {
            Text(monitor.isRecording ? "Type shortcut…" : (shortcut?.displayString ?? "None"))
                .font(.system(.caption, design: .rounded).weight(.medium))
                .foregroundStyle(monitor.isRecording ? Color.accentColor : (shortcut == nil ? .secondary : .primary))
                .monospacedDigit()
                .frame(minWidth: 74)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(monitor.isRecording ? Color.accentColor : Color(nsColor: .separatorColor),
                                      lineWidth: monitor.isRecording ? 1.5 : 0.75)
                )
        }
        .buttonStyle(.plain)
        .help("Click to change shortcut. Press Esc to cancel, Delete to clear.")
        .onDisappear {
            monitor.stop()
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        let userModifiers = event.modifierFlags.intersection([.control, .option, .shift, .command])
        // Bare Esc cancels recording.
        if event.keyCode == 53, userModifiers.isEmpty {
            monitor.stop()
            onError(nil)
            return nil
        }
        // Bare Delete / Forward Delete clears the shortcut.
        if (event.keyCode == 51 || event.keyCode == 117), userModifiers.isEmpty {
            shortcut = nil
            monitor.stop()
            onError(nil)
            return nil
        }

        guard let candidate = AppShortcut.from(event: event) else {
            NSSound.beep()
            return nil
        }

        switch AppShortcut.validate(candidate, conflictingWith: otherShortcut) {
        case .valid(let valid):
            shortcut = valid
            onError(nil)
            monitor.stop()
        case .missingModifier:
            NSSound.beep()
            onError("Include ⌘ or ⌃ in the shortcut.")
        case .reserved:
            NSSound.beep()
            onError("That shortcut is reserved by Ferry or macOS.")
        case .duplicate:
            NSSound.beep()
            onError("Already used by the other Markdown option.")
        }
        return nil
    }
}

private final class ShortcutMonitor: ObservableObject {
    @Published private(set) var isRecording = false
    private var eventMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    deinit {
        stop()
    }

    func start(handler: @escaping (NSEvent) -> NSEvent?) {
        stop()
        isRecording = true
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handler(event)
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: NSApp.keyWindow,
            queue: .main
        ) { [weak self] _ in
            self?.stop()
        }
    }

    func stop() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        if isRecording {
            isRecording = false
        }
    }
}
