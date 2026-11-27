import XCTest
@testable import Ferry

final class TabStripModelTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    private func strip(_ ids: [UUID], active: UUID? = nil) -> TabStripModel {
        var strip = TabStripModel()
        for id in ids { strip.add(id, afterActive: false) }
        if let active { strip.select(active) }
        return strip
    }

    func testOneDocumentHasNoTabBar() {
        var model = strip([a])
        XCTAssertFalse(model.showsTabBar)
        model.add(b)
        XCTAssertTrue(model.showsTabBar)
        model.close(b)
        XCTAssertFalse(model.showsTabBar)
        XCTAssertEqual(model.activeID, a)
    }

    func testNewTabsGoRightAfterTheActiveOne() {
        var model = strip([a, b, c], active: a)
        model.add(d)
        XCTAssertEqual(model.tabs, [a, d, b, c])
        XCTAssertEqual(model.activeID, d)
        model.add(b) // already open: just shown
        XCTAssertEqual(model.tabs.count, 4)
        XCTAssertEqual(model.activeID, b)
    }

    func testClosingTheActiveTabShowsItsNeighbour() {
        var model = strip([a, b, c], active: b)
        model.close(b)
        XCTAssertEqual(model.activeID, c, "the tab to the right takes its place")
        model.close(c)
        XCTAssertEqual(model.activeID, a, "the last one: the new last tab")
        model = strip([a, b, c], active: a)
        model.close(a)
        XCTAssertEqual(model.activeID, b)
        model = strip([a, b, c], active: c)
        model.close(a)
        XCTAssertEqual(model.activeID, c, "closing another tab keeps the shown one")
        model.close(c)
        model.close(b)
        XCTAssertNil(model.activeID)
        XCTAssertTrue(model.tabs.isEmpty)
    }

    func testNextPreviousAndNumberShortcuts() {
        var model = strip([a, b, c], active: c)
        model.selectNext()
        XCTAssertEqual(model.activeID, a, "wraps around")
        model.selectPrevious()
        XCTAssertEqual(model.activeID, c)
        model.selectShortcutIndex(2)
        XCTAssertEqual(model.activeID, b)
        model.selectShortcutIndex(9)
        XCTAssertEqual(model.activeID, c, "⌘9: the last tab")
        model.selectShortcutIndex(5)
        XCTAssertEqual(model.activeID, c, "no fifth tab: nothing happens")
        model.selectShortcutIndex(0)
        XCTAssertEqual(model.activeID, c)
        XCTAssertEqual(model.otherIDs(keeping: b), [a, c])
    }

    func testDragReorderKeepsTheActiveTab() {
        var model = strip([a, b, c, d], active: b)
        model.move(b, to: 3)
        XCTAssertEqual(model.tabs, [a, c, d, b])
        XCTAssertEqual(model.activeID, b)
        model.move(d, to: -5)
        XCTAssertEqual(model.tabs, [d, a, c, b])
        model.move(a, to: 99)
        XCTAssertEqual(model.tabs, [d, c, b, a])
    }

    func testDividersHideNextToTheActiveAndHoveredTabs() {
        let model = strip([a, b, c, d], active: b)
        XCTAssertFalse(model.showsTrailingDivider(at: 0, hoveredID: nil), "left of the active tab")
        XCTAssertFalse(model.showsTrailingDivider(at: 1, hoveredID: nil), "right of the active tab")
        XCTAssertTrue(model.showsTrailingDivider(at: 2, hoveredID: nil), "between two plain tabs")
        XCTAssertFalse(model.showsTrailingDivider(at: 2, hoveredID: d), "next to the hovered tab")
        XCTAssertFalse(model.showsTrailingDivider(at: 3, hoveredID: nil), "never after the last tab")
    }
}
