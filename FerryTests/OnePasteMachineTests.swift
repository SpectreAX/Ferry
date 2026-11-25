import XCTest
@testable import Ferry

final class OnePasteMachineTests: XCTestCase {
    private func armed(_ images: Int = 2) -> OnePasteMachine {
        var machine = OnePasteMachine()
        _ = machine.handle(.armed(imageCount: images))
        return machine
    }

    func testHappyPathPastesImagesOneAtATimeThenText() {
        var machine = armed(2)
        XCTAssertEqual(machine.handle(.pasteIntercepted).filter { $0 != .log("⌘V intercepted") },
                       [.takeBaseline, .writeImage(0), .postPaste, .startGuard(.imagesOffered)])
        XCTAssertTrue(machine.nothingPastedYet)
        XCTAssertEqual(machine.handle(.imageRequested(1)), [], "only the image on offer counts")
        XCTAssertTrue(machine.handle(.imageRequested(0)).contains(.evaluateTarget))
        XCTAssertEqual(machine.phase, .imagesRequested)
        XCTAssertEqual(machine.handle(.targetUpdated(imagesAdded: false, textAdded: true)), [], "text change isn't image proof")

        let second = machine.handle(.targetUpdated(imagesAdded: true, textAdded: false))
        XCTAssertTrue(second.contains(.writeImage(1)), "next image, in its own paste")
        XCTAssertEqual(machine.phase, .imagesOffered)
        XCTAssertFalse(machine.nothingPastedYet)
        XCTAssertTrue(machine.handle(.imageRequested(1)).contains(.evaluateTarget))
        XCTAssertTrue(machine.handle(.targetUpdated(imagesAdded: true, textAdded: false)).contains(.writeText))
        XCTAssertEqual(machine.phase, .textOffered)

        XCTAssertEqual(machine.handle(.targetUpdated(imagesAdded: true, textAdded: true)), [], "needs the text request first")
        XCTAssertTrue(machine.handle(.textRequested).contains(.evaluateTarget))
        let done = machine.handle(.targetUpdated(imagesAdded: false, textAdded: true))
        XCTAssertTrue(done.contains(.restoreFallback))
        XCTAssertTrue(done.contains(.report(.worked)))
        XCTAssertEqual(machine.phase, .armed, "ready for the next ⌘V")
    }

    func testFailureAfterTheFirstImageLeavesTextInsteadOfTheCopy() {
        var machine = armed(2)
        _ = machine.handle(.pasteIntercepted)
        _ = machine.handle(.imageRequested(0))
        _ = machine.handle(.targetUpdated(imagesAdded: true, textAdded: false))
        let effects = machine.handle(.timedOut(.imagesOffered))
        XCTAssertTrue(effects.contains(.leaveTextOnClipboard), "restoring the copy would paste image 1 again")
        XCTAssertFalse(effects.contains(.restoreFallback))
        XCTAssertEqual(machine.handle(.unsuitableTarget("late")), [], "no hand-back once something was pasted")
    }

    func testRequestAloneNeverConfirms() {
        var machine = armed(1)
        _ = machine.handle(.pasteIntercepted)
        _ = machine.handle(.imageRequested(0))
        XCTAssertEqual(machine.phase, .imagesRequested)
        XCTAssertFalse(machine.handle(.imageRequested(0)).contains(.writeText))
    }

    func testFailureGuardsNeverPasteMoreAndKeepContent() {
        var machine = armed(1)
        _ = machine.handle(.pasteIntercepted)
        XCTAssertTrue(machine.handle(.timedOut(.imagesOffered)).contains(.restoreFallback))
        XCTAssertEqual(machine.phase, .armed)

        _ = machine.handle(.pasteIntercepted)
        _ = machine.handle(.imageRequested(0))
        let afterImages = machine.handle(.timedOut(.imagesRequested))
        XCTAssertTrue(afterImages.contains(.leaveTextOnClipboard))
        XCTAssertFalse(afterImages.contains(.postPaste))
        XCTAssertEqual(machine.phase, .idle)
    }

    func testStaleGuardIsIgnored() {
        var machine = armed(1)
        _ = machine.handle(.pasteIntercepted)
        _ = machine.handle(.imageRequested(0))
        XCTAssertEqual(machine.handle(.timedOut(.imagesOffered)), [], "guard of a finished phase")
        XCTAssertEqual(machine.phase, .imagesRequested)
    }

    func testInterruptionsByPhase() {
        var machine = armed(1)
        _ = machine.handle(.pasteIntercepted)
        XCTAssertTrue(machine.handle(.interrupted("click")).contains(.restoreFallback))
        XCTAssertEqual(machine.phase, .armed)

        _ = machine.handle(.pasteIntercepted)
        _ = machine.handle(.imageRequested(0))
        XCTAssertTrue(machine.handle(.interrupted("click")).contains(.leaveTextOnClipboard), "an image may be in: keep the text")
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertEqual(machine.handle(.interrupted("late")), [])
    }

    func testExternalClipboardChangeStopsWithoutWriting() {
        var machine = armed(1)
        _ = machine.handle(.pasteIntercepted)
        let effects = machine.handle(.clipboardChangedExternally)
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertFalse(effects.contains { [.restoreFallback, .leaveTextOnClipboard, .writeText, .writeImage(0)].contains($0) })
    }

    func testSnapshotHelpers() {
        let base = TargetSnapshot(valueLength: 3, levels: [.init(images: 0, buttons: 1), .init(images: 1, buttons: 4)])
        let chip = TargetSnapshot(valueLength: 3, levels: [.init(images: 0, buttons: 2), .init(images: 1, buttons: 5)])
        let typed = TargetSnapshot(valueLength: 40, levels: base.levels)
        XCTAssertFalse(base.textChanged(since: base))
        XCTAssertTrue(typed.textChanged(since: base))
        XCTAssertEqual(chip.attachmentGain(since: base), 1)
        XCTAssertEqual(base.attachmentGain(since: base), 0)
    }

    /// Seen in Antigravity: the reference for the text step was caught mid-redraw (a button missing). Merging
    /// it with the snapshot that confirmed the last image keeps the returning button from looking new.
    func testMergedReferenceIgnoresARedrawDip() {
        let confirmedImage = TargetSnapshot(valueLength: 1, levels: [.init(images: 1, buttons: 4)])
        let dippedBaseline = TargetSnapshot(valueLength: 1, levels: [.init(images: 1, buttons: 3)])
        let reference = dippedBaseline.mergedMax(with: confirmedImage)
        XCTAssertEqual(reference.levels, [.init(images: 1, buttons: 4)])
        XCTAssertEqual(reference.valueLength, 1)
        let afterRedraw = TargetSnapshot(valueLength: 1, levels: [.init(images: 1, buttons: 4)])
        XCTAssertEqual(afterRedraw.attachmentGain(since: reference), 0)
        XCTAssertEqual(afterRedraw.attachmentGain(since: dippedBaseline), 1, "what fooled the per-step baseline")
    }

    func testOnlyTheFirstImageTakesABeforeSnapshot() {
        var machine = armed(3)
        XCTAssertTrue(machine.handle(.pasteIntercepted).contains(.takeBaseline))
        _ = machine.handle(.imageRequested(0))
        let second = machine.handle(.targetUpdated(imagesAdded: true, textAdded: false))
        XCTAssertFalse(second.contains(.takeBaseline))
        XCTAssertEqual(Array(second.dropFirst()), [.writeImage(1), .postPaste, .startGuard(.imagesOffered)])
        _ = machine.handle(.imageRequested(1))
        _ = machine.handle(.targetUpdated(imagesAdded: true, textAdded: false))
        _ = machine.handle(.imageRequested(2))
        XCTAssertTrue(machine.handle(.targetUpdated(imagesAdded: true, textAdded: false)).contains(.takeBaseline),
                      "the text step takes its own")
    }
}
