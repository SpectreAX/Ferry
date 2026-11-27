import Foundation

/// The tabs of one window, in order, and which one is shown. No UI: the tab bar draws it, the window acts on it.
struct TabStripModel: Equatable {
    private(set) var tabs: [UUID] = []
    private(set) var activeID: UUID?

    /// One document never gets a tab bar.
    var showsTabBar: Bool { tabs.count > 1 }

    var activeIndex: Int? { activeID.flatMap { tabs.firstIndex(of: $0) } }

    /// Adds a tab right after the active one (or at the end) and shows it.
    mutating func add(_ id: UUID, afterActive: Bool = true) {
        guard !tabs.contains(id) else { return select(id) }
        let index = afterActive ? (activeIndex.map { $0 + 1 } ?? tabs.count) : tabs.count
        tabs.insert(id, at: index)
        activeID = id
    }

    mutating func select(_ id: UUID) {
        if tabs.contains(id) { activeID = id }
    }

    mutating func selectNext() { step(1) }
    mutating func selectPrevious() { step(-1) }

    private mutating func step(_ delta: Int) {
        guard let index = activeIndex, !tabs.isEmpty else { return }
        activeID = tabs[(index + delta + tabs.count) % tabs.count]
    }

    /// ⌘1…⌘8 pick that tab, ⌘9 the last one (as in Safari); a number past the end does nothing.
    mutating func selectShortcutIndex(_ number: Int) {
        guard (1...9).contains(number), !tabs.isEmpty else { return }
        if number == 9 { activeID = tabs.last } else if number <= tabs.count { activeID = tabs[number - 1] }
    }

    /// Removes a tab. Closing the shown one shows the tab that takes its place (the one to its right), or the
    /// new last one.
    mutating func close(_ id: UUID) {
        guard let index = tabs.firstIndex(of: id) else { return }
        tabs.remove(at: index)
        guard activeID == id else { return }
        activeID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)]
    }

    func otherIDs(keeping id: UUID) -> [UUID] { tabs.filter { $0 != id } }

    /// Drag to reorder: the tab lands at `index` (clamped); the shown tab stays shown.
    mutating func move(_ id: UUID, to index: Int) {
        guard let from = tabs.firstIndex(of: id) else { return }
        tabs.remove(at: from)
        tabs.insert(id, at: max(0, min(index, tabs.count)))
    }

    /// Safari's thin line between tabs: only between two tabs that are neither shown nor under the pointer.
    func showsTrailingDivider(at index: Int, hoveredID: UUID?) -> Bool {
        guard index >= 0, index < tabs.count - 1 else { return false }
        let pair = [tabs[index], tabs[index + 1]]
        return !pair.contains { $0 == activeID || $0 == hoveredID }
    }
}
