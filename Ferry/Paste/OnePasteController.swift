import AppKit

/// Runs One ⌘V: armed by a copy in Ferry, it takes over the next ⌘V in any app that `AppPasteRules` allows
/// and drives two pastes (images, then text), confirming each one in the target's UI before moving on.
/// Results teach `AppPasteRules` which apps it works in.
/// Main-thread object; the keyboard tap only reads `gate` (lock-protected) and hands work to the main thread.
final class OnePasteController {
    typealias Phase = OnePasteMachine.Phase

    static let shared = OnePasteController(environment: SystemPasteEnvironment(), followsSettings: true)

    /// Failure guards per waiting phase. They only decide failure; success always needs evidence.
    var guardTimeouts: [Phase: TimeInterval] = [.imagesOffered: 2, .imagesRequested: 5, .textOffered: 2, .textRequested: 4]
    /// How long the target may take to answer a before-snapshot. Past it: hand ⌘V back (before image 1) or stop.
    var baselineTimeout: TimeInterval = 1.5
    /// Terminals: how long after the terminal read a value Ferry moves on. Keystrokes reach the CLI in order
    /// through the terminal, so this only lets the terminal finish its paste before the clipboard changes.
    var terminalSettleDelay: TimeInterval = 0.15
    /// Backstop checks while waiting for confirmation, in case the app sends no change notification.
    var recheckDelays: [TimeInterval] = [0.05, 0.1, 0.2, 0.3, 0.5, 0.8, 1.2, 1.6]

    private(set) var machine = OnePasteMachine()
    var phase: Phase { machine.phase }

    private let env: OnePasteEnvironment
    private var payload: OnePastePayload?
    private var fallback: ((NSPasteboard) -> Void)?
    private var ownChangeCount: Int?
    private var target: (pid: pid_t, name: String, bundleID: String)?
    private let rules: AppPasteRules
    private var baseline: TargetSnapshot?
    /// Counts images against the snapshot taken before the first one (see `AttachmentCounter`).
    private var attachments: AttachmentCounter?
    /// The snapshot that confirmed the last image; merged into the text baseline (see `takeBaseline`).
    private var lastImageSnapshot: TargetSnapshot?
    /// Consecutive checks that saw a new attachment during the text step (long text turned into one).
    private var textAttachmentStreak = 0
    private var baselineWatchdog: DispatchWorkItem?
    /// Bumped by every before-snapshot request and whenever a session ends, so a late answer (or watchdog)
    /// from an earlier request can never run its follow-up in a newer session that happens to be in the same phase.
    private var baselineGeneration = 0
    private var interceptionActive = true
    private var lastSummary = ""
    private var providers: [LazyPasteboardValue] = []
    private var guardWork: DispatchWorkItem?
    private var recheckWork: DispatchWorkItem?
    private var evaluating = false
    private var evaluateAgain = false
    private var observing = false
    private var sessionStart = Date()
    private var settingsToken: NSObjectProtocol?
    /// The session's target is a terminal (see `TargetProfiles.terminals`).
    private var inTerminal = false
    private var settleWork: DispatchWorkItem?

    /// What the keyboard tap may read, from its own thread.
    private struct Gate {
        var armed = false
        var active = false
        var changeCount: Int?
        var frontmostBundleID: String?
        var frontmostName: String?
        var frontmostPID: pid_t = 0
    }
    private var gate = Gate()
    private let gateLock = NSLock()
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    init(environment: OnePasteEnvironment, rules: AppPasteRules = .shared, followsSettings: Bool = false) {
        env = environment
        self.rules = rules
        guard followsSettings else { return }
        settingsToken = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                                               queue: .main) { [weak self] _ in
            guard let self, CopyMode.current != .oneCommandV, self.phase != .idle || self.ownChangeCount != nil else { return }
            self.disarm()
        }
    }

    // MARK: Public

    /// Puts the fallback copy on the clipboard and waits for ⌘V. Returns false without Accessibility permission.
    @discardableResult
    func arm(_ payload: OnePastePayload, fallback: @escaping (NSPasteboard) -> Void) -> Bool {
        guard env.installInterception({ [weak self] key in self?.decide(key) ?? .pass }) else {
            PasteLog.write("not armed: Accessibility access is not granted to this Ferry")
            return false
        }
        env.watchFrontmost { [weak self] bundleID, pid in self?.frontmostChanged(bundleID: bundleID, pid: pid) }
        if phase.isActive { send(.disarm) }
        self.payload = payload
        self.fallback = fallback
        writeFallback()
        apply(machine.handle(.armed(imageCount: payload.images.count)))
        return true
    }

    /// Leaves One ⌘V entirely (mode switched off): stops intercepting and leaves the clipboard as it is.
    func disarm() {
        apply(machine.handle(.disarm))
        payload = nil
        fallback = nil
        ownChangeCount = nil
        syncGate()
        env.removeInterception()
    }

    /// A copy in Ferry that doesn't arm One ⌘V replaces the armed copy: stop listening for ⌘V (the tap pauses,
    /// stays installed) and leave the clipboard to the new copy. A running session is left to notice the change itself.
    func standDown() {
        guard phase == .armed else { return }
        apply(machine.handle(.disarm))
        payload = nil
        fallback = nil
        ownChangeCount = nil
        syncGate()
    }

    /// Called by the keyboard tap on its own thread. Only reads the gate; never blocks.
    func decide(_ key: PasteEventTap.Key) -> PasteEventTap.Decision {
        gateLock.lock()
        defer { gateLock.unlock() }
        if gate.active {
            if key.isCommandV { return .swallow } // a second ⌘V mid-session would paste twice
            DispatchQueue.main.async { self.send(.interrupted(key.isEscape ? "Esc" : "key pressed")) }
            return key.isEscape ? .swallow : .pass // Esc cancels Ferry, not the app's popover
        }
        guard key.isCommandV else { return .pass }
        let front = gate.frontmostBundleID ?? "unknown"
        guard gate.armed, !key.isAutorepeat else {
            PasteLog.write("⌘V in \(front): passed (armed=\(gate.armed), autorepeat=\(key.isAutorepeat))")
            return .pass
        }
        guard gate.frontmostPID != ownPID, let bundleID = gate.frontmostBundleID, rules.mode(for: bundleID) == .oneCommandV else {
            PasteLog.write("⌘V in \(front): passed (normal paste for this app)")
            return .pass
        }
        // The clipboard check needs NSPasteboard, which belongs on the main thread: `begin` does it there.
        gate.armed = false
        gate.active = true
        let pid = gate.frontmostPID
        let name = gate.frontmostName ?? bundleID
        PasteLog.write("⌘V in \(front): taken over")
        DispatchQueue.main.async { self.begin(pid: pid, name: name, bundleID: bundleID) }
        return .swallow
    }

    /// Frontmost-app changes (main thread). Leaving the target app mid-session is an interruption.
    func frontmostChanged(bundleID: String?, pid: pid_t) {
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName
        gateLock.lock()
        gate.frontmostBundleID = bundleID
        gate.frontmostName = name
        gate.frontmostPID = pid
        let armed = gate.armed
        gateLock.unlock()
        if armed { PasteLog.write("front app: \(bundleID ?? "unknown") (pid \(pid))") }
        if phase.isActive, let target, target.pid != pid { send(.interrupted("switched to \(bundleID ?? "another app")")) }
    }

    // MARK: Events

    private func begin(pid: pid_t, name: String, bundleID: String) {
        guard phase == .armed else { return syncGate() }
        guard env.pasteboard.changeCount == ownChangeCount else {
            // Copied elsewhere since Ferry's copy: hand the user's ⌘V back so it pastes the new content.
            log("clipboard changed since the copy; passing ⌘V through")
            send(.clipboardChangedExternally)
            _ = env.postPaste()
            return
        }
        target = (pid, name, bundleID)
        inTerminal = TargetProfiles.isTerminal(bundleID)
        sessionStart = Date()
        lastSummary = ""
        log("session in \(name) (pid \(pid))\(inTerminal ? ", terminal: images as file paths" : "")")
        apply(machine.handle(.pasteIntercepted))
    }

    func send(_ event: OnePasteMachine.Event) {
        var event = event
        if phase.isActive, event != .disarm, let own = ownChangeCount, env.pasteboard.changeCount != own {
            event = .clipboardChangedExternally
        }
        apply(machine.handle(event))
    }

    private func apply(_ effects: [OnePasteMachine.Effect]) {
        syncObservation() // start watching before the first read of the target
        var remaining = effects[...]
        while let effect = remaining.popFirst() {
            if effect == .takeBaseline {
                // Asynchronous: the rest (writing the clipboard, sending ⌘V) waits for the "before" snapshot.
                takeBaseline(then: Array(remaining))
                break
            }
            perform(effect)
        }
        syncObservation()
        syncGate()
    }

    private func syncObservation() {
        if !phase.isActive {
            baselineWatchdog?.cancel()
            baselineGeneration += 1
            settleWork?.cancel()
            guardWork?.cancel()
            recheckWork?.cancel()
            if observing { env.endObserving(); observing = false }
        } else if !observing, let target {
            env.beginObserving(pid: target.pid,
                               onChange: { [weak self] name in self?.targetChanged(name) },
                               onInterrupt: { [weak self] reason in self?.send(.interrupted(reason)) })
            observing = true
        }
    }

    private func perform(_ effect: OnePasteMachine.Effect) {
        switch effect {
        case .log(let message): log(message)
        case .takeBaseline: break // handled in apply
        case .writeImage(let index): writeImage(index)
        case .writeText: writeText()
        case .postPaste: postPaste()
        case .startGuard(let phase): startGuard(phase)
        case .evaluateTarget:
            if inTerminal { settle() } else { evaluate(); scheduleRecheck(0) }
        case .restoreFallback: writeFallback()
        case .leaveTextOnClipboard: writeManualText()
        case .notify(let message): env.notify(message)
        case .report(let outcome):
            if let target { rules.record(outcome, for: target.bundleID, name: target.name) }
        }
    }

    // MARK: Clipboard

    /// One image per paste (see `OnePasteMachine`).
    /// In a terminal the image goes as its escaped file path (plain text), which the AI CLI attaches.
    private func writeImage(_ index: Int) {
        guard let payload, payload.images.indices.contains(index) else { return }
        let url = payload.images[index]
        let value = inTerminal ? TerminalPath.escaped(url.path) : url.absoluteString
        let provider = LazyPasteboardValue(value) { [weak self] in self?.send(.imageRequested(index)) }
        providers = [provider]
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [inTerminal ? .string : .fileURL])
        markSkippable(item)
        if let fragment = payload.fragment { item.setData(fragment, forType: FerryPasteboard.fragmentType) }
        write([item], hostOnly: true)
    }

    private func writeText() {
        guard let payload else { return }
        let provider = LazyPasteboardValue(payload.text) { [weak self] in self?.send(.textRequested) }
        providers = [provider]
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.string])
        markSkippable(item)
        if let fragment = payload.fragment { item.setData(fragment, forType: FerryPasteboard.fragmentType) }
        write([item], hostOnly: true)
    }

    /// Plain text for a manual ⌘V after a failure or interruption. Ferry stops intercepting it.
    private func writeManualText() {
        guard let payload else { return }
        let item = NSPasteboardItem()
        item.setString(payload.text, forType: .string)
        if let fragment = payload.fragment { item.setData(fragment, forType: FerryPasteboard.fragmentType) }
        write([item], hostOnly: false)
    }

    private func writeFallback() {
        guard let fallback else { return }
        providers = []
        fallback(env.pasteboard)
        ownChangeCount = env.pasteboard.changeCount
    }

    private func write(_ items: [NSPasteboardItem], hostOnly: Bool) {
        let pasteboard = env.pasteboard
        if hostOnly {
            pasteboard.prepareForNewContents(with: .currentHostOnly) // no Universal Clipboard fetches
        } else {
            pasteboard.clearContents()
        }
        pasteboard.writeObjects(items)
        ownChangeCount = pasteboard.changeCount
    }

    /// Clipboard watchers (Raycast, QQ…) skip content with these markers instead of reading it.
    private func markSkippable(_ item: NSPasteboardItem) {
        for marker in TwoStepClipboard.skipMarkers { item.setData(Data(), forType: marker) }
    }

    // MARK: Target

    private func postPaste() {
        guard env.postPaste() else {
            DispatchQueue.main.async { self.send(.interrupted("could not send ⌘V")) }
            return
        }
        log("⌘V sent")
    }

    /// Reads the "before" state, then runs `rest`. If the session moved on meanwhile (interrupted, timed out),
    /// `rest` is dropped, so nothing is written or pasted.
    private func takeBaseline(then rest: [OnePasteMachine.Effect]) {
        guard let target else {
            baseline = nil
            return apply(rest)
        }
        let waiting = phase
        baselineGeneration += 1
        let generation = baselineGeneration
        baselineWatchdog?.cancel()
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, self.baselineGeneration == generation, self.phase == waiting else { return }
            self.log("the app didn't answer within \(self.baselineTimeout)s")
            self.send(self.machine.nothingPastedYet ? .unsuitableTarget("the app didn't respond") : .timedOut(waiting))
        }
        baselineWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + baselineTimeout, execute: watchdog)
        env.snapshot(pid: target.pid) { [weak self] snapshot in
            guard let self else { return }
            watchdog.cancel()
            // A fired watchdog has already moved the session on, so this also drops late answers.
            guard self.baselineGeneration == generation, self.phase == waiting else { return self.log("baseline arrived after the session moved on; skipped") }
            // Text step: merge with the snapshot that confirmed the last image, so a chip caught mid-redraw
            // here can't make a returning button look like a new attachment.
            self.baseline = waiting == .textOffered ? snapshot.map { $0.mergedMax(with: self.lastImageSnapshot ?? $0) } : snapshot
            self.textAttachmentStreak = 0
            if self.machine.nothingPastedYet { self.attachments = snapshot.map { AttachmentCounter(start: $0) } }
            self.log("baseline \(snapshot?.summary ?? "unavailable") focus=\(snapshot?.focusedRole ?? "?")/\(snapshot?.focusedSubrole ?? "-")")
            // Only multi-line message boxes get One ⌘V; anything else (or a field Ferry can't read) gets the
            // normal paste, before anything has been written to the clipboard. Many terminals expose nothing
            // to Accessibility; there an unreadable target is expected, while a search or password field still
            // gets the normal paste.
            let unreadable: String? = self.inTerminal ? nil : "can't read the focused field"
            if self.machine.nothingPastedYet, let reason = snapshot.map({ $0.unsuitableReason }) ?? unreadable {
                return self.send(.unsuitableTarget(reason))
            }
            self.apply(rest)
        }
    }

    private func targetChanged(_ name: String) { evaluate(trigger: name) }

    /// Checks the target asynchronously; overlapping requests collapse into one follow-up check.
    private func evaluate(trigger: String = "check") {
        guard phase == .imagesRequested || phase == .textRequested, let target else { return }
        guard !evaluating else {
            evaluateAgain = true
            return
        }
        evaluating = true
        let waiting = phase
        env.snapshot(pid: target.pid) { [weak self] now in
            guard let self else { return }
            self.evaluating = false
            if self.phase == waiting { self.judge(now, trigger: trigger) }
            if self.evaluateAgain {
                self.evaluateAgain = false
                self.evaluate(trigger: "follow-up")
            }
        }
    }

    private func judge(_ now: TargetSnapshot?, trigger: String) {
        guard let payload else { return }
        guard let baseline, let now else {
            log("\(trigger): target not readable")
            return
        }
        // Images: k pasted so far must all be visible, counted from the session start.
        let imagesAdded = phase == .imagesRequested && attachments?.confirms(machine.currentImage + 1, now: now) == true
        if imagesAdded { lastImageSnapshot = now }
        var textAdded = false
        if phase == .textRequested {
            // Long text may become an attachment instead; accept that only when it holds for two checks in a row.
            let attachmentSeen = payload.textMayBecomeAttachment && now.attachmentGain(since: baseline) >= 1
            textAttachmentStreak = attachmentSeen ? textAttachmentStreak + 1 : 0
            textAdded = now.textChanged(since: baseline) || textAttachmentStreak >= 2
        }
        if now.summary != lastSummary {
            lastSummary = now.summary
            log("\(trigger): \(now.summary) images=\(imagesAdded) text=\(textAdded)")
        }
        send(.targetUpdated(imagesAdded: imagesAdded, textAdded: textAdded))
    }

    /// Terminals show attachments as text in a character grid, often invisible to Accessibility. The value having
    /// been read is the evidence: once the terminal has read it, it is in the CLI's input, in order.
    private func settle() {
        settleWork?.cancel()
        let waiting = phase
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.phase == waiting else { return }
            self.log("terminal read it; moving on")
            self.send(.targetUpdated(imagesAdded: waiting == .imagesRequested, textAdded: waiting == .textRequested))
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + terminalSettleDelay, execute: work)
    }

    private func scheduleRecheck(_ step: Int) {
        recheckWork?.cancel()
        guard step < recheckDelays.count else { return }
        let waiting = phase
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.phase == waiting else { return }
            self.evaluate()
            if self.phase == waiting { self.scheduleRecheck(step + 1) }
        }
        recheckWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + recheckDelays[step], execute: work)
    }

    private func startGuard(_ phase: Phase) {
        guardWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.send(.timedOut(phase)) }
        guardWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (guardTimeouts[phase] ?? 3), execute: work)
    }

    // MARK: Bookkeeping

    private func syncGate() {
        gateLock.lock()
        gate.armed = phase == .armed
        gate.active = phase.isActive
        gate.changeCount = ownChangeCount
        let listening = gate.armed || gate.active
        gateLock.unlock()
        if listening != interceptionActive {
            interceptionActive = listening
            env.setInterceptionActive(listening) // idle: keystrokes don't pass through Ferry at all
        }
    }

    private func log(_ message: String) {
        let elapsed = Int(Date().timeIntervalSince(sessionStart) * 1000)
        PasteLog.write("[+\(elapsed)ms] [\(phase.rawValue)] \(message)")
    }
}

/// Supplies one value only when an app asks for it, and reports the request on the main thread.
/// A request proves the data was read, not that the app used it.
final class LazyPasteboardValue: NSObject, NSPasteboardItemDataProvider {
    private let value: String
    private let onRequest: () -> Void

    init(_ value: String, onRequest: @escaping () -> Void) {
        self.value = value
        self.onRequest = onRequest
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        item.setString(value, forType: type)
        DispatchQueue.main.async(execute: onRequest)
    }
}
