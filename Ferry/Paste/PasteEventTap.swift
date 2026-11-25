import AppKit

/// A system-wide keyboard tap on its own thread, so work on Ferry's main thread can never delay keystrokes.
/// The decision closure runs on that thread and must only read lock-protected state and return.
final class PasteEventTap {
    enum Decision { case pass, swallow }

    struct Key {
        let isCommandV: Bool
        let isAutorepeat: Bool
        var isEscape = false
    }

    /// Stamped on Ferry's own synthetic keystrokes so the tap lets them through ("FERR").
    static let syntheticMarker: Int64 = 0x4645_5252

    private let decide: (Key) -> Decision
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    /// Paused while Ferry isn't armed, so idle keystrokes don't pass through Ferry at all.
    private var wantsEnabled = true
    private let lock = NSLock()

    init(decide: @escaping (Key) -> Decision) {
        self.decide = decide
    }

    var isInstalled: Bool {
        lock.lock(); defer { lock.unlock() }
        return tap != nil
    }

    /// Installs the tap. Fails without Accessibility permission.
    func install() -> Bool {
        if isInstalled { return true }
        let ready = DispatchSemaphore(value: 0)
        var installed = false
        let thread = Thread { [weak self] in
            guard let self else { ready.signal(); return }
            let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                               eventsOfInterest: mask, callback: pasteTapCallback,
                                               userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
                ready.signal()
                return
            }
            let source = CFMachPortCreateRunLoopSource(nil, port, 0)
            let loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            self.lock.lock(); self.tap = port; self.runLoop = loop; self.lock.unlock()
            installed = true
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "Ferry paste tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        PasteLog.write(installed ? "event tap installed" : "event tap NOT installed (no Accessibility permission?)")
        return installed
    }

    /// Pauses or resumes the tap without removing it.
    func setEnabled(_ enabled: Bool) {
        lock.lock()
        wantsEnabled = enabled
        let port = tap
        lock.unlock()
        if let port { CGEvent.tapEnable(tap: port, enable: enabled) }
    }

    func uninstall() {
        lock.lock()
        let port = tap, loop = runLoop
        tap = nil; runLoop = nil
        lock.unlock()
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        if let loop { CFRunLoopStop(loop) }
        PasteLog.write("event tap removed")
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock(); let port = tap, wanted = wantsEnabled; lock.unlock()
            if wanted, let port { CGEvent.tapEnable(tap: port, enable: true) }
            PasteLog.write("event tap was disabled by the system (type \(type.rawValue))\(wanted ? "; re-enabled" : "")")
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown, event.getIntegerValueField(.eventSourceUserData) != Self.syntheticMarker else {
            return Unmanaged.passUnretained(event)
        }
        let key = Key(isCommandV: Self.isCommandV(event),
                      isAutorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                      isEscape: Self.isBareEscape(event))
        if event.flags.contains(.maskCommand), event.getIntegerValueField(.keyboardEventKeycode) == 9, !key.isCommandV {
            PasteLog.write("⌘+V key not recognized as paste (flags \(event.flags.rawValue))")
        }
        return decide(key) == .swallow ? nil : Unmanaged.passUnretained(event)
    }

    /// Esc with no modifier: ⌥⌘Esc (Force Quit) and friends are other keys and reach the system.
    static func isBareEscape(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.keyboardEventKeycode) == 53
            && event.flags.isDisjoint(with: [.maskCommand, .maskControl, .maskAlternate, .maskShift])
    }

    /// ⌘V with no other modifier (⌘⇧V and ⌥⌘V stay untouched).
    /// Uses only CGEvent data: AppKit/input-method lookups (e.g. `NSEvent(cgEvent:)`) must not run on this thread.
    static func isCommandV(_ event: CGEvent) -> Bool {
        let flags = event.flags
        guard flags.contains(.maskCommand), flags.isDisjoint(with: [.maskShift, .maskAlternate, .maskControl]) else {
            return false
        }
        var buffer = [UniChar](repeating: 0, count: 4)
        var length = 0
        event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
        if length > 0 { return String(utf16CodeUnits: buffer, count: length).lowercased() == "v" }
        return event.getIntegerValueField(.keyboardEventKeycode) == 9
    }
}

private func pasteTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                              refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<PasteEventTap>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
}
