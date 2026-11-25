import AppKit

/// Everything One ⌘V needs from the system, behind a protocol so tests can drive the controller with fakes.
protocol OnePasteEnvironment: AnyObject {
    var pasteboard: NSPasteboard { get }
    /// Installs the ⌘V interception (requires Accessibility permission).
    func installInterception(_ decide: @escaping (PasteEventTap.Key) -> PasteEventTap.Decision) -> Bool
    func removeInterception()
    /// Pauses the interception while Ferry isn't armed, resumes it when armed.
    func setInterceptionActive(_ active: Bool)
    /// Reports the frontmost app now and whenever it changes (on the main thread).
    func watchFrontmost(_ handler: @escaping (_ bundleID: String?, _ pid: pid_t) -> Void)
    func postPaste() -> Bool
    func beginObserving(pid: pid_t, onChange: @escaping (String) -> Void, onInterrupt: @escaping (String) -> Void)
    func endObserving()
    /// Reads the target asynchronously (never block the main thread on the target); completion on main.
    func snapshot(pid: pid_t, completion: @escaping (TargetSnapshot?) -> Void)
    func notify(_ message: String)
}

final class SystemPasteEnvironment: OnePasteEnvironment {
    let pasteboard = NSPasteboard.general
    private var tap: PasteEventTap?
    private let observer = TargetObserver()
    private var mouseMonitor: Any?
    private var frontmostToken: NSObjectProtocol?

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Registers Ferry in Privacy & Security › Accessibility (the system prompt appears at most once per app)
    /// and opens that list so the user can turn it on.
    static func openAccessibilitySettings() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: false] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func installInterception(_ decide: @escaping (PasteEventTap.Key) -> PasteEventTap.Decision) -> Bool {
        guard Self.isTrusted else { return false }
        if tap == nil { tap = PasteEventTap(decide: decide) }
        return tap!.install()
    }

    func removeInterception() {
        tap?.uninstall()
        tap = nil
    }

    func setInterceptionActive(_ active: Bool) { tap?.setEnabled(active) }

    func watchFrontmost(_ handler: @escaping (String?, pid_t) -> Void) {
        if let app = NSWorkspace.shared.frontmostApplication { handler(app.bundleIdentifier, app.processIdentifier) }
        guard frontmostToken == nil else { return }
        frontmostToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            handler(app.bundleIdentifier, app.processIdentifier)
        }
    }

    func postPaste() -> Bool { KeystrokePoster.postPaste() }

    func beginObserving(pid: pid_t, onChange: @escaping (String) -> Void, onInterrupt: @escaping (String) -> Void) {
        observer.begin(pid: pid, onChange: onChange)
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { _ in
            onInterrupt("mouse click")
        }
    }

    func endObserving() {
        observer.end()
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
    }

    func snapshot(pid: pid_t, completion: @escaping (TargetSnapshot?) -> Void) { observer.snapshot(pid: pid, completion: completion) }

    func notify(_ message: String) { PasteHUD.show(message) }
}
