import AppKit
import ApplicationServices

/// Watches the target app through Accessibility: change notifications trigger a check, and `snapshot`
/// reads the focused input and its surroundings. Read-only: it never changes the target's content.
///
/// Every Accessibility call runs off the main thread. An AX call blocks until the target app answers, and
/// while it handles Ferry's ⌘V the target is itself waiting for Ferry's main thread to hand over the
/// clipboard data: calling AX from the main thread there deadlocks both apps until AX times out (6 s).
final class TargetObserver {
    private static let notifications = [
        kAXValueChangedNotification, kAXCreatedNotification, kAXUIElementDestroyedNotification,
        kAXFocusedUIElementChangedNotification, kAXLayoutChangedNotification, kAXSelectedTextChangedNotification,
        kAXSelectedChildrenChangedNotification, kAXRowCountChangedNotification,
        "AXLiveRegionChanged", "AXLoadComplete", "AXChildrenChanged",
    ]
    private static let ancestorLevels = 6
    private static let nodeBudget = 6000 // shared by all levels

    // Owned by the observer thread only.
    private var observer: AXObserver?
    private var appElement: AXUIElement?
    private var registered: [String] = []
    private var onChange: ((String) -> Void)?

    /// Notifications are delivered on this thread's run loop; snapshots run on `snapshotQueue`.
    private var runLoop: CFRunLoop?
    private let snapshotQueue = DispatchQueue(label: "dev.spectreax.ferry.ax-snapshot", qos: .userInitiated)

    init() {
        // Process-wide cap for every AX call (set on the system-wide element). A per-app timeout would not
        // cover the elements read from it, which otherwise wait up to 6 s on a busy app.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            self?.runLoop = CFRunLoopGetCurrent()
            RunLoop.current.add(NSMachPort(), forMode: .default) // keeps the run loop alive
            ready.signal()
            RunLoop.current.run()
        }
        thread.name = "Ferry accessibility"
        thread.qualityOfService = .userInitiated
        thread.start()
        ready.wait()
    }

    /// Starts watching `pid`; `onChange` is called on the main thread. Returns immediately.
    func begin(pid: pid_t, onChange: @escaping (String) -> Void) {
        perform { [weak self] in
            guard let self else { return }
            self.teardown()
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.5)
            // Electron/Chromium apps only expose their web content to Accessibility clients that ask for it.
            let manual = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            var created: AXObserver?
            guard AXObserverCreate(pid, targetObserverCallback, &created) == .success, let created else {
                PasteLog.write("could not observe pid \(pid)")
                return
            }
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            self.registered = Self.notifications.filter { AXObserverAddNotification(created, app, $0 as CFString, refcon) == .success }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(created), .defaultMode)
            self.observer = created
            self.appElement = app
            self.onChange = { name in DispatchQueue.main.async { onChange(name) } }
            PasteLog.write("observing pid \(pid) (manualAX=\(manual.rawValue)): \(self.registered.joined(separator: ","))")
        }
    }

    /// Stops watching. Returns immediately.
    func end() {
        perform { [weak self] in self?.teardown() }
    }

    /// Reads the target off the main thread; `completion` runs on the main thread.
    func snapshot(pid: pid_t, completion: @escaping (TargetSnapshot?) -> Void) {
        snapshotQueue.async {
            let snapshot = Self.snapshot(pid: pid)
            DispatchQueue.main.async { completion(snapshot) }
        }
    }

    private func teardown() {
        onChange = nil
        guard let observer, let appElement else { return }
        for name in registered { AXObserverRemoveNotification(observer, appElement, name as CFString) }
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        self.observer = nil
        self.appElement = nil
        registered = []
    }

    private func perform(_ block: @escaping () -> Void) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    fileprivate func notified(_ name: String) { onChange?(name) }

    /// The focused input's character count and the images/buttons around it.
    /// Runs on `snapshotQueue` (may wait briefly; never on the main thread).
    static func snapshot(pid: pid_t) -> TargetSnapshot? {
        let app = AXUIElementCreateApplication(pid)
        // Electron/Chromium build their web tree only once asked, and need a moment for it: ask here too (the
        // observer may not have started yet on a first paste) and retry briefly before giving up.
        _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var focused = element(app, kAXFocusedUIElementAttribute)
        for _ in 0..<3 where focused.flatMap({ value($0, kAXRoleAttribute) }) == nil {
            Thread.sleep(forTimeInterval: 0.1)
            focused = element(app, kAXFocusedUIElementAttribute)
        }
        guard let focused else { return nil }

        return TargetSnapshot(valueLength: textLength(of: focused), levels: surroundings(of: focused),
                              focusedRole: value(focused, kAXRoleAttribute) as? String,
                              focusedSubrole: value(focused, kAXSubroleAttribute) as? String)
    }

    /// Images and buttons inside ancestors 1…6 of `start`. Each element is read once: a level's totals are the
    /// previous level's plus the ancestor itself and its other children.
    static func surroundings(of start: AXUIElement) -> [TargetSnapshot.Level] {
        var budget = nodeBudget
        var totals = TargetSnapshot.Level(images: 0, buttons: 0)
        count(start, into: &totals, budget: &budget)
        var levels: [TargetSnapshot.Level] = []
        var counted = start
        for _ in 0..<ancestorLevels {
            guard let parent = element(counted, kAXParentAttribute) else { break }
            add(role: value(parent, kAXRoleAttribute) as? String, to: &totals)
            for child in children(parent) where !CFEqual(child, counted) {
                count(child, into: &totals, budget: &budget)
            }
            levels.append(totals)
            counted = parent
        }
        return levels
    }

    /// The input's character count; for rich editors whose element reports none, the text of its children.
    private static func textLength(of input: AXUIElement) -> Int {
        let direct = (value(input, kAXNumberOfCharactersAttribute) as? Int)
            ?? (value(input, kAXValueAttribute) as? String)?.utf16.count ?? 0
        guard direct == 0 else { return direct }
        var budget = 300
        var total = 0
        func walk(_ node: AXUIElement) {
            guard budget > 0 else { return }
            budget -= 1
            if (value(node, kAXRoleAttribute) as? String) == kAXStaticTextRole {
                total += (value(node, kAXValueAttribute) as? String)?.utf16.count ?? 0
            }
            children(node).forEach(walk)
        }
        children(input).forEach(walk)
        return total
    }

    private static func count(_ node: AXUIElement, into counts: inout TargetSnapshot.Level, budget: inout Int) {
        guard budget > 0 else { return }
        budget -= 1
        add(role: value(node, kAXRoleAttribute) as? String, to: &counts)
        for child in children(node) {
            count(child, into: &counts, budget: &budget)
        }
    }

    private static func add(role: String?, to counts: inout TargetSnapshot.Level) {
        switch role {
        case kAXImageRole: counts.images += 1
        case kAXButtonRole: counts.buttons += 1
        default: break
        }
    }

    private static func children(_ node: AXUIElement) -> [AXUIElement] {
        (value(node, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var result: AnyObject?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let result = value(element, attribute), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }
}

private func targetObserverCallback(observer: AXObserver, element: AXUIElement, notification: CFString,
                                    refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    Unmanaged<TargetObserver>.fromOpaque(refcon).takeUnretainedValue().notified(notification as String)
}
