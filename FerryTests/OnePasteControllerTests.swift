import XCTest
@testable import Ferry

/// A simulated Claude: on each ⌘V it reads the clipboard the way Chromium does (files win over text)
/// and updates what its "UI" shows. Flags simulate the failure cases.
private final class FakeTarget {
    var readsPastes = true
    var showsImages = true
    var showsText = true
    var longTextBecomesAttachment = false
    /// Like Antigravity: of a multi-file paste, only the first file is kept.
    var keepsOnlyFirstFile = false
    /// Like Claude: image chips re-render right away, the text shows up a moment later.
    var textArrivesAfterChipReRender = false
    private(set) var images = 0
    private(set) var buttons = 0
    private(set) var chars = 0
    private(set) var receivedFiles: [[URL]] = []
    private(set) var receivedTexts: [String] = []

    func paste(from pasteboard: NSPasteboard) {
        guard readsPastes else { return }
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty {
            let kept = keepsOnlyFirstFile ? Array(urls.prefix(1)) : urls
            receivedFiles.append(kept)
            if showsImages { images += kept.count; buttons += kept.count * 2 }
            return
        }
        guard let text = pasteboard.string(forType: .string) else { return }
        receivedTexts.append(text)
        guard showsText else { return }
        if longTextBecomesAttachment, text.count >= 500 {
            images += 1; buttons += 1
        } else if textArrivesAfterChipReRender {
            images = 0; buttons += 2
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.chars += text.utf16.count }
        } else {
            chars += text.utf16.count
        }
    }

    /// The focused field's kind, as Accessibility reports it.
    var role = "AXTextArea"
    var subrole: String?
    var snapshot: TargetSnapshot {
        TargetSnapshot(valueLength: chars, levels: [.init(images: images, buttons: buttons)], focusedRole: role, focusedSubrole: subrole)
    }
}

private final class FakeEnvironment: OnePasteEnvironment {
    let pasteboard = NSPasteboard(name: .init("ferry.test.onepaste"))
    let target = FakeTarget()
    var trusted = true
    var pastes = 0
    var notices: [String] = []
    var isObserving = false
    private(set) var interceptionInstalled = false
    var interrupt: ((String) -> Void)?

    func installInterception(_ decide: @escaping (PasteEventTap.Key) -> PasteEventTap.Decision) -> Bool {
        interceptionInstalled = trusted
        return trusted
    }
    func removeInterception() { interceptionInstalled = false }
    private(set) var interceptionActive = true
    func setInterceptionActive(_ active: Bool) { interceptionActive = active }
    func watchFrontmost(_ handler: @escaping (String?, pid_t) -> Void) { handler("com.anthropic.claudefordesktop", 4242) }
    func postPaste() -> Bool {
        pastes += 1
        DispatchQueue.main.async { self.target.paste(from: self.pasteboard) } // the app handles ⌘V a moment later
        return true
    }
    func beginObserving(pid: pid_t, onChange: @escaping (String) -> Void, onInterrupt: @escaping (String) -> Void) {
        isObserving = true
        interrupt = onInterrupt
    }
    func endObserving() { isObserving = false }
    /// Like the real one: answers asynchronously, optionally slowly (a busy target app).
    var snapshotDelay: TimeInterval = 0
    /// The app exposes nothing to Accessibility.
    var unreadable = false
    private(set) var snapshotRequests = 0
    /// Makes a read hang (an unresponsive app) while this returns true.
    var hangsWhen: () -> Bool = { false }
    /// Keeps answers until the test releases them, to order them exactly.
    var holdsSnapshots = false
    var heldSnapshots: [() -> Void] = []
    func snapshot(pid: pid_t, completion: @escaping (TargetSnapshot?) -> Void) {
        snapshotRequests += 1
        if hangsWhen() { return } // never answers
        if holdsSnapshots { return heldSnapshots.append { completion(self.target.snapshot) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + snapshotDelay) { completion(self.unreadable ? nil : self.target.snapshot) }
    }
    func notify(_ message: String) { notices.append(message) }
}

final class OnePasteControllerTests: XCTestCase {
    private var env: FakeEnvironment!
    private var controller: OnePasteController!
    private var rules: AppPasteRules!
    private var images: [URL] = []
    private let commandV = PasteEventTap.Key(isCommandV: true, isAutorepeat: false)

    override func setUpWithError() throws {
        PasteLog.writesFile = false
        let dir = try makeTempDirectory(self, name: "doc")
        images = try ["a.png", "b.png"].map { try writePNG(at: dir.appendingPathComponent("assets/\($0)")) }
        env = FakeEnvironment()
        env.pasteboard.clearContents()
        let suite = "ferry.test.rules.\(UUID().uuidString)"
        rules = AppPasteRules(defaults: UserDefaults(suiteName: suite)!)
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        controller = OnePasteController(environment: env, rules: rules)
        controller.guardTimeouts = [.imagesOffered: 0.4, .imagesRequested: 0.6, .textOffered: 0.4, .textRequested: 0.6]
    }

    private func payload(images count: Int = 2, text: String = "Look at these") -> OnePastePayload {
        var segments: [Fragment.Segment] = [.init(text: text + "\n")]
        for url in images.prefix(count) { segments.append(.init(image: .init(path: url.path, alt: ""))) }
        return OnePastePayload(fragment: Fragment(segments: segments))!
    }

    private func arm(_ payload: OnePastePayload) {
        XCTAssertTrue(controller.arm(payload) { $0.clearContents(); $0.setString("FALLBACK", forType: .string) })
    }

    @discardableResult
    private func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return condition()
    }

    // MARK: Happy paths

    func testOneCommandVPastesImagesThenTextAndRearms() {
        let payload = payload()
        arm(payload)
        XCTAssertEqual(env.pasteboard.string(forType: .string), "FALLBACK")
        XCTAssertEqual(controller.decide(commandV), .swallow)

        XCTAssertTrue(waitUntil { env.pastes == 3 && controller.phase == .armed })
        XCTAssertEqual(env.target.receivedFiles, images.map { [$0] }, "one image per paste")
        XCTAssertEqual(env.target.receivedTexts, [payload.text])
        XCTAssertEqual(payload.text, "Look at these\n[Image 1][Image 2]")
        XCTAssertEqual(env.pasteboard.string(forType: .string), "FALLBACK", "original copy restored")
        XCTAssertTrue(env.notices.isEmpty)
        XCTAssertFalse(env.isObserving)
    }

    func testRepeatedPasteWorksAgain() {
        arm(payload())
        controller.decide(commandV)
        XCTAssertTrue(waitUntil { env.pastes == 3 && controller.phase == .armed })
        XCTAssertEqual(controller.decide(commandV), .swallow)
        XCTAssertTrue(waitUntil { env.pastes == 6 && controller.phase == .armed })
        XCTAssertEqual(env.target.receivedTexts.count, 2)
    }

    func testSingleImage() {
        arm(payload(images: 1))
        controller.decide(commandV)
        XCTAssertTrue(waitUntil { env.pastes == 2 && controller.phase == .armed })
        XCTAssertEqual(env.target.receivedFiles, [[images[0]]])
    }

    func testLongTextTurnedIntoAttachmentStillCompletes() {
        env.target.longTextBecomesAttachment = true
        let payload = payload(text: String(repeating: "long text ", count: 60))
        arm(payload)
        controller.decide(commandV)
        XCTAssertTrue(waitUntil { env.pastes == 3 && controller.phase == .armed })
        XCTAssertEqual(env.target.receivedTexts, [payload.text], "complete text delivered")
    }

    func testWaitsForTheRealTextNotAChipReRender() {
        env.target.textArrivesAfterChipReRender = true
        arm(payload())
        controller.decide(commandV)
        XCTAssertTrue(waitUntil { controller.phase == .armed && env.pastes == 3 })
        XCTAssertGreaterThan(env.target.chars, 0, "confirmed only once the text was really there")
    }

    /// Regression (first paste stuck for 6 s): reading the target must never block the main thread, which has
    /// to stay free to hand the target its clipboard data. A slow target only delays the paste.
    func testSlowTargetReadsDelayButDoNotBlockThePaste() {
        env.snapshotDelay = 0.3
        arm(payload())
        controller.decide(commandV)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(env.pastes, 0, "⌘V waits for the before-snapshot")
        XCTAssertTrue(waitUntil(5) { env.pastes == 3 && controller.phase == .armed })
        XCTAssertEqual(env.target.receivedFiles, images.map { [$0] }, "one image per paste")
        XCTAssertEqual(env.target.receivedTexts.count, 1)
    }

    func testInterruptionWhileReadingTheTargetPastesNothing() {
        env.snapshotDelay = 0.3
        arm(payload())
        controller.decide(commandV)
        XCTAssertTrue(waitUntil { controller.phase == .imagesOffered })
        env.interrupt?("mouse click")
        controller.send(.interrupted("mouse click"))
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertEqual(env.pastes, 0, "the pending steps were dropped")
        XCTAssertEqual(controller.phase, .armed)
        XCTAssertEqual(env.pasteboard.string(forType: .string), "FALLBACK")
    }

    /// Regression (Antigravity kept 1 of 2 images): one image per paste works even where an app keeps only
    /// the first file of a paste.
    func testAppThatKeepsOnlyTheFirstFileStillGetsEveryImage() {
        env.target.keepsOnlyFirstFile = true
        arm(payload())
        controller.decide(commandV)
        XCTAssertTrue(waitUntil { env.pastes == 3 && controller.phase == .armed })
        XCTAssertEqual(env.target.images, 2)
        XCTAssertEqual(env.target.receivedTexts.count, 1)
    }

    // MARK: Robustness

    func testUnresponsiveAppBeforeTheFirstImageGetsANormalPaste() {
        controller.baselineTimeout = 0.3
        env.hangsWhen = { true }
        arm(payload())
        XCTAssertEqual(controller.decide(commandV), .swallow)
        XCTAssertTrue(waitUntil { env.pastes == 1 && controller.phase == .armed && env.target.receivedTexts == ["FALLBACK"] })
        XCTAssertTrue(env.target.receivedFiles.isEmpty)
        XCTAssertTrue(rules.all.isEmpty, "not the app's fault as far as learning goes")
    }

    func testUnresponsiveAppAtTheTextStepStopsAndKeepsTheText() {
        controller.baselineTimeout = 0.3
        env.hangsWhen = { [unowned self] in self.controller.phase == .textOffered }
        let payload = payload()
        arm(payload)
        controller.decide(commandV)
        XCTAssertTrue(waitUntil { controller.phase == .idle })
        XCTAssertEqual(env.target.images, 2, "both images went in")
        XCTAssertEqual(env.pastes, 2, "no text paste without a reference")
        XCTAssertEqual(env.pasteboard.string(forType: .string), payload.text)
    }

    func testEscCancelsWithoutReachingTheApp() {
        env.target.showsImages = false
        arm(payload())
        controller.decide(commandV)
        XCTAssertTrue(waitUntil { controller.phase == .imagesRequested })
        XCTAssertEqual(controller.decide(.init(isCommandV: false, isAutorepeat: false, isEscape: true)), .swallow)
        XCTAssertTrue(waitUntil { controller.phase == .idle })
    }

    func testLateBeforeSnapshotFromAnInterruptedSessionIsIgnored() {
        env.holdsSnapshots = true
        arm(payload())
        controller.decide(commandV)
        XCTAssertTrue(waitUntil { env.heldSnapshots.count == 1 })
        controller.send(.interrupted("Esc")) // before image 1: back to armed
        XCTAssertEqual(controller.phase, .armed)
        controller.decide(commandV) // a new session, same phase, while the first answer is still on its way
        XCTAssertTrue(waitUntil { env.heldSnapshots.count == 2 })
        env.holdsSnapshots = false
        let answers = env.heldSnapshots
        answers.forEach { $0() } // the stale answer lands first, right before the current one
        XCTAssertTrue(waitUntil { env.pastes == 3 && controller.phase == .armed })
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(env.target.receivedFiles, images.map { [$0] }, "each image pasted once")
        XCTAssertEqual(env.pastes, 3)
    }

    func testCopyThatDoesNotArmStandsDown() {
        arm(payload())
        XCTAssertTrue(env.interceptionActive)
        controller.standDown()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(env.interceptionActive, "the tap pauses right away")
        XCTAssertEqual(env.pasteboard.string(forType: .string), "FALLBACK", "the clipboard is left alone")
        XCTAssertEqual(controller.decide(commandV), .pass)
        arm(payload())
        XCTAssertTrue(env.interceptionActive)
    }

    func testOnlyBareEscapeCancels() {
        func escape(_ flags: CGEventFlags) -> CGEvent {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)!
            event.flags = flags
            return event
        }
        XCTAssertTrue(PasteEventTap.isBareEscape(escape([])))
        XCTAssertFalse(PasteEventTap.isBareEscape(escape([.maskCommand, .maskAlternate])), "⌥⌘Esc is Force Quit")
        XCTAssertFalse(PasteEventTap.isBareEscape(escape(.maskShift)))
        XCTAssertFalse(PasteEventTap.isBareEscape(CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true)!))
    }

    func testInterceptionPausesWhileNotArmed() {
        arm(payload())
        XCTAssertTrue(env.interceptionActive)
        env.pasteboard.clearContents()
        env.pasteboard.setString("copied elsewhere", forType: .string)
        controller.decide(commandV)
        XCTAssertTrue(waitUntil { controller.phase == .idle })
        XCTAssertFalse(env.interceptionActive, "idle: keystrokes no longer pass through Ferry")
        arm(payload())
        XCTAssertTrue(env.interceptionActive)
    }

    // MARK: Terminals

    private func inTerminal() {
        controller.terminalSettleDelay = 0.05
        controller.frontmostChanged(bundleID: "com.mitchellh.ghostty", pid: 4242)
    }

    func testTerminalGetsEachImageAsItsPathThenTheText() {
        env.unreadable = true // GPU terminals expose nothing to Accessibility
        let payload = payload()
        arm(payload)
        inTerminal()
        XCTAssertEqual(controller.decide(commandV), .swallow)
        XCTAssertTrue(waitUntil { env.pastes == 3 && controller.phase == .armed })
        XCTAssertTrue(env.target.receivedFiles.isEmpty, "never files: a CLI reads text")
        XCTAssertEqual(env.target.receivedTexts, images.map { TerminalPath.escaped($0.path) } + [payload.text])
        XCTAssertEqual(env.pasteboard.string(forType: .string), "FALLBACK", "the copy is back for the next ⌘V")
        XCTAssertEqual(rules.all.first?.rule.mode, .oneCommandV)
    }

    func testTerminalSearchFieldGetsANormalPaste() {
        env.target.role = "AXTextField"
        env.target.subrole = "AXSearchField"
        arm(payload())
        inTerminal()
        controller.decide(commandV)
        XCTAssertTrue(waitUntil { env.pastes == 1 && controller.phase == .armed && env.target.receivedTexts == ["FALLBACK"] })
    }

    func testInterruptingATerminalSessionSendsNothingMore() {
        env.unreadable = true
        arm(payload())
        inTerminal()
        controller.terminalSettleDelay = 0.4
        controller.decide(commandV)
        XCTAssertTrue(waitUntil { controller.phase == .imagesRequested })
        XCTAssertEqual(controller.decide(.init(isCommandV: false, isAutorepeat: false, isEscape: true)), .swallow)
        XCTAssertTrue(waitUntil { controller.phase == .idle })
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertEqual(env.pastes, 1, "the pending step was dropped")
        XCTAssertTrue(rules.all.isEmpty)
    }

    // MARK: Where ⌘V is left alone

    func testOtherAppsAndKeysPassThrough() {
        arm(payload())
        controller.frontmostChanged(bundleID: "com.apple.finder", pid: 777)
        XCTAssertEqual(controller.decide(commandV), .pass)
        controller.frontmostChanged(bundleID: "dev.spectreax.ferry", pid: ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(controller.decide(commandV), .pass)
        controller.frontmostChanged(bundleID: "com.anthropic.claudefordesktop", pid: 4242)
        XCTAssertEqual(controller.decide(.init(isCommandV: false, isAutorepeat: false)), .pass)
        XCTAssertEqual(controller.decide(.init(isCommandV: true, isAutorepeat: true)), .pass)
        XCTAssertEqual(controller.phase, .armed)
        XCTAssertEqual(env.pastes, 0)
    }

    func testExternalClipboardChangeDisarmsWithoutTouchingIt() {
        arm(payload())
        env.pasteboard.clearContents()
        env.pasteboard.setString("copied elsewhere", forType: .string)
        // The tap can't read the clipboard on its thread, so it takes the ⌘V; the main thread sees the change
        // and hands the paste back, which delivers the new content.
        XCTAssertEqual(controller.decide(commandV), .swallow)
        XCTAssertTrue(waitUntil { controller.phase == .idle && env.target.receivedTexts == ["copied elsewhere"] })
        XCTAssertEqual(env.pasteboard.string(forType: .string), "copied elsewhere")
        XCTAssertEqual(env.pastes, 1)
        XCTAssertTrue(env.target.receivedFiles.isEmpty)
    }

    func testExternalChangeMidSessionStopsWithoutTouchingIt() {
        env.target.showsImages = false // stays waiting for confirmation
        arm(payload())
        controller.decide(commandV)
        XCTAssertTrue(waitUntil { controller.phase == .imagesRequested })
        env.pasteboard.clearContents()
        env.pasteboard.setString("copied elsewhere", forType: .string)
        controller.send(.targetUpdated(imagesAdded: false, textAdded: false))
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(env.pasteboard.string(forType: .string), "copied elsewhere")
    }

    // MARK: Failures keep content and never send more

    func testAppIgnoresThePaste() {
        env.target.readsPastes = false
        arm(payload())
        controller.decide(commandV)
        XCTAssertTrue(waitUntil { !env.notices.isEmpty })
        XCTAssertEqual(controller.phase, .armed, "nothing was pasted, so ⌘V can be tried again")
        XCTAssertEqual(env.pastes, 1)
        XCTAssertEqual(env.pasteboard.string(forType: .string), "FALLBACK")
    }

    func testImagesReadButNeverShownLeavesTextForManualPaste() {
        env.target.showsImages = false
        let payload = payload()
        arm(payload)
        controller.decide(commandV)
        XCTAssertTrue(waitUntil { controller.phase == .idle })
        XCTAssertEqual(env.pastes, 1, "text is not pasted without proof the images landed")
        XCTAssertEqual(env.pasteboard.string(forType: .string), payload.text)
        XCTAssertNil(env.pasteboard.availableType(from: TwoStepClipboard.skipMarkers), "a normal, manual paste")
        XCTAssertFalse(env.notices.isEmpty)
    }

    func testTextReadButNeverShownIsNotPastedAgain() {
        env.target.showsText = false
        let payload = payload()
        arm(payload)
        controller.decide(commandV)
        XCTAssertTrue(waitUntil { controller.phase == .idle })
        XCTAssertEqual(env.pastes, 3, "two images + the text")
        XCTAssertEqual(env.target.receivedTexts.count, 1, "never pasted twice")
        XCTAssertEqual(env.pasteboard.string(forType: .string), payload.text)
    }

    // MARK: Interruptions

    func testClickMidSessionStopsAndLeavesText() {
        env.target.showsImages = false
        let payload = payload()
        arm(payload)
        controller.decide(commandV)
        XCTAssertTrue(waitUntil { controller.phase == .imagesRequested })
        env.interrupt?("mouse click")
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(env.pasteboard.string(forType: .string), payload.text)
        XCTAssertEqual(env.notices.count, 1)
        XCTAssertTrue(env.notices[0].hasPrefix("Check the images (stopped at 1 of 2)"), env.notices[0])
    }

    func testKeysDuringSession() {
        env.target.showsImages = false
        arm(payload())
        controller.decide(commandV)
        XCTAssertTrue(waitUntil { controller.phase == .imagesRequested })
        XCTAssertEqual(controller.decide(commandV), .swallow, "an extra ⌘V must not paste a second time")
        XCTAssertEqual(controller.phase, .imagesRequested)
        XCTAssertEqual(controller.decide(.init(isCommandV: false, isAutorepeat: false)), .pass)
        XCTAssertTrue(waitUntil { controller.phase == .idle }, "typing interrupts")
    }

    func testSwitchingAppsInterrupts() {
        env.target.showsImages = false
        arm(payload())
        controller.decide(commandV)
        XCTAssertTrue(waitUntil { controller.phase == .imagesRequested })
        controller.frontmostChanged(bundleID: "com.apple.Safari", pid: 999)
        XCTAssertEqual(controller.phase, .idle)
    }

    // MARK: Setup

    func testWithoutAccessibilityNothingIsArmed() {
        env.trusted = false
        XCTAssertFalse(controller.arm(payload()) { _ in XCTFail("fallback must not be written by the controller") })
        XCTAssertEqual(controller.phase, .idle)
    }

    func testDisarmRemovesInterception() {
        arm(payload())
        XCTAssertTrue(env.interceptionInstalled)
        controller.disarm()
        XCTAssertFalse(env.interceptionInstalled)
        XCTAssertEqual(controller.decide(commandV), .pass)
    }

    // MARK: Any app, learned per app

    func testAnyUnknownAppGetsOneCommandVAndIsLearned() {
        arm(payload())
        controller.frontmostChanged(bundleID: "com.google.antigravity", pid: 5150)
        XCTAssertEqual(controller.decide(commandV), .swallow)
        XCTAssertTrue(waitUntil { env.pastes == 3 && controller.phase == .armed })
        XCTAssertEqual(env.target.receivedTexts.count, 1)
        XCTAssertEqual(rules.all.first?.bundleID, "com.google.antigravity")
        XCTAssertEqual(rules.all.first?.rule.mode, .oneCommandV)
    }

    func testExcludedAppsAlwaysGetANormalPaste() {
        arm(payload())
        for bundleID in ["com.apple.finder", "com.1password.1password", "com.apple.SecurityAgent", "dev.spectreax.ferry"] {
            controller.frontmostChanged(bundleID: bundleID, pid: 6000)
            XCTAssertEqual(controller.decide(commandV), .pass, bundleID)
        }
        XCTAssertEqual(env.pastes, 0)
    }

    func testAppThatFailsTwiceGetsANormalPasteFromThenOn() {
        env.target.readsPastes = false // the app ignores pasted files
        for attempt in 1...2 {
            arm(payload())
            controller.frontmostChanged(bundleID: "com.example.notes", pid: 7000)
            XCTAssertEqual(controller.decide(commandV), .swallow, "attempt \(attempt)")
            XCTAssertTrue(waitUntil { controller.phase == .armed && env.notices.count == attempt })
        }
        XCTAssertEqual(rules.mode(for: "com.example.notes"), .normalPaste)
        XCTAssertEqual(controller.decide(commandV), .pass, "third ⌘V is a normal paste")
    }

    func testUserChoiceWins() {
        rules.setMode(.normalPaste, for: "com.anthropic.claudefordesktop", name: "Claude")
        arm(payload())
        XCTAssertEqual(controller.decide(commandV), .pass)
        rules.setMode(.oneCommandV, for: "com.anthropic.claudefordesktop", name: "Claude")
        XCTAssertEqual(controller.decide(commandV), .swallow)
        XCTAssertTrue(waitUntil { env.pastes == 3 && controller.phase == .armed })
    }

    // MARK: Fields that can't take images get a normal paste

    private func assertHandedBack(file: StaticString = #filePath, line: UInt = #line) {
        arm(payload())
        XCTAssertEqual(controller.decide(commandV), .swallow, file: file, line: line)
        XCTAssertTrue(waitUntil { env.pastes == 1 && controller.phase == .armed && env.target.receivedTexts == ["FALLBACK"] },
                      "the user's ⌘V comes back as a normal paste of the copy", file: file, line: line)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(env.pastes, 1, "nothing more is pasted", file: file, line: line)
        XCTAssertTrue(env.target.receivedFiles.isEmpty, file: file, line: line)
        XCTAssertTrue(rules.all.isEmpty, "a field choice says nothing about the app", file: file, line: line)
    }

    func testPasswordFieldGetsANormalPaste() {
        env.target.role = "AXTextField"
        env.target.subrole = "AXSecureTextField"
        assertHandedBack()
    }

    func testSingleLineAndSearchFieldsGetANormalPaste() {
        env.target.role = "AXTextField"
        assertHandedBack()
    }

    func testUnreadableAppGetsANormalPaste() {
        env.unreadable = true
        assertHandedBack()
    }

    func testOnlyMixedSelectionsUseOneCommandV() {
        XCTAssertNil(OnePastePayload(fragment: Fragment(segments: [.init(text: "only text")])))
        XCTAssertNil(OnePastePayload(fragment: Fragment(segments: [.init(image: .init(path: images[0].path, alt: ""))])))
        XCTAssertNil(OnePastePayload(fragment: Fragment(segments: [.init(text: "x"), .init(image: .init(path: "/missing.png", alt: ""))])))
    }
}
