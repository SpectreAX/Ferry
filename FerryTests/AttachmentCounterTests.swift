import XCTest
@testable import Ferry

/// Replays image/button counts recorded in real sessions (~/Library/Logs/Ferry/one-paste.log).
final class AttachmentCounterTests: XCTestCase {
    /// "L1=0i/0b L2=…" as logged.
    private func snap(_ levels: [(Int, Int)]) -> TargetSnapshot {
        TargetSnapshot(valueLength: 1, levels: levels.map { .init(images: $0.0, buttons: $0.1) })
    }

    func testAntigravityRedrawDoesNotPassForImageTwo() {
        var counter = AttachmentCounter(start: snap([(0, 0), (0, 0), (0, 0), (0, 2), (0, 2), (0, 2)]))
        XCTAssertFalse(counter.confirms(1, now: snap([(0, 0), (0, 0), (0, 0), (0, 2), (0, 2), (0, 2)])))
        XCTAssertTrue(counter.confirms(1, now: snap([(0, 0), (0, 0), (1, 2), (1, 4), (1, 4), (1, 4)])), "image 1")
        // Image 1's chip redraws (a button disappears, then comes back) before image 2 shows.
        XCTAssertFalse(counter.confirms(2, now: snap([(0, 0), (0, 0), (1, 2), (1, 4), (1, 3), (1, 4)])))
        XCTAssertFalse(counter.confirms(2, now: snap([(0, 0), (0, 0), (1, 2), (1, 4), (1, 4), (1, 4)])),
                       "the button coming back is not image 2")
        XCTAssertTrue(counter.confirms(2, now: snap([(0, 0), (0, 0), (2, 4), (2, 6), (2, 6), (2, 6)])), "image 2")
    }

    func testChatGPTCountsButtonsAtTheRateImageOneSet() {
        var counter = AttachmentCounter(start: snap([(0, 3), (0, 3), (0, 3)]))
        XCTAssertTrue(counter.confirms(1, now: snap([(0, 4), (0, 4), (0, 4)])))
        XCTAssertEqual(counter.buttonsPerImage, 1)
        XCTAssertFalse(counter.confirms(2, now: snap([(0, 4), (0, 4), (0, 4)])))
        XCTAssertTrue(counter.confirms(2, now: snap([(0, 5), (0, 5), (0, 5)])))
    }

    func testTwoButtonsPerImageWithoutThumbnails() {
        var counter = AttachmentCounter(start: snap([(0, 0)]))
        XCTAssertTrue(counter.confirms(1, now: snap([(0, 2)])))
        XCTAssertFalse(counter.confirms(2, now: snap([(0, 3)])), "one extra button is not a second attachment")
        XCTAssertTrue(counter.confirms(2, now: snap([(0, 4)])))
    }

    func testClaudeThumbnails() {
        var counter = AttachmentCounter(start: snap([(0, 0), (0, 0), (0, 0), (0, 0), (0, 0), (0, 2)]))
        XCTAssertTrue(counter.confirms(1, now: snap([(0, 0), (0, 0), (0, 0), (0, 1), (1, 2), (1, 4)])))
        XCTAssertFalse(counter.confirms(2, now: snap([(0, 0), (0, 0), (0, 0), (0, 1), (1, 3), (1, 5)])))
        XCTAssertTrue(counter.confirms(2, now: snap([(0, 0), (0, 0), (0, 0), (0, 1), (2, 3), (2, 5)])))
    }

    func testNothingNewConfirmsNothing() {
        var counter = AttachmentCounter(start: snap([(1, 2)]))
        XCTAssertFalse(counter.confirms(1, now: snap([(1, 2)])))
        XCTAssertFalse(counter.confirms(2, now: snap([(1, 4)])), "image 2 can't be the first to set the button rate")
    }
}
