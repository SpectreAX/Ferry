import AppKit
import SwiftUI

/// What the tab bar shows, and what its clicks do. Owned by a `TabWindowController`.
final class TabBarStore: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id: UUID
        var title: String
        var edited: Bool
        var fileURL: URL?
    }

    struct Actions {
        weak var controller: TabWindowController?
        func select(_ id: UUID) { controller?.select(id) }
        func close(_ id: UUID) { controller?.closeTab(id) }
        func closeOthers(_ id: UUID) { controller?.closeOtherTabs(keeping: id) }
        func moveToNewWindow(_ id: UUID) { controller?.moveTabToNewWindow(id) }
        func move(_ id: UUID, to index: Int) { controller?.move(id, to: index) }
        func newTab() { FerryDocument.newTab() }
    }

    @Published private(set) var strip = TabStripModel()
    @Published private(set) var items: [Item] = []
    @Published var leadingInset: CGFloat = 78
    @Published var isKeyWindow = true
    var actions = Actions()

    func update(strip: TabStripModel, items: [Item]) {
        if self.strip != strip { self.strip = strip }
        if self.items != items { self.items = items }
    }
}

/// The 38 pt bar at the top of a document window, in the style of Safari's compact tabs.
/// One document: just its name, centered (no tabs, no +). Two or more: equal-width tabs and a + button.
struct SafariTabBar: View {
    @ObservedObject var store: TabBarStore
    @State private var hoveredID: UUID?
    private struct Drag: Equatable {
        let id: UUID
        var offset: CGFloat
    }

    /// Resets by itself when the drag ends or is cancelled (focus lost), so a tab never stays shifted.
    @GestureState private var dragging: Drag?
    @Environment(\.colorScheme) private var colorScheme

    private let tabHeight: CGFloat = 26
    private let spacing: CGFloat = 3
    private let minTabWidth: CGFloat = 100

    var body: some View {
        ZStack(alignment: .bottom) {
            WindowDragArea(menu: titleMenu)
            if store.strip.showsTabBar { tabRow } else { title }
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 0.5)
        }
        .frame(height: TabWindowController.barHeight)
    }

    // MARK: One document

    private var title: some View {
        HStack(spacing: 5) {
            Image(systemName: "doc.text").font(.system(size: 13)).foregroundStyle(.tertiary)
            Text(store.items.first?.title ?? "").font(.system(size: 12.5, weight: .medium))
            if store.items.first?.edited == true {
                Text("— Edited").font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .foregroundStyle(store.isKeyWindow ? .primary : .secondary)
        .padding(.horizontal, store.leadingInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false) // clicks fall through to the drag area: move, double-click to zoom, right-click
    }

    private func titleMenu() -> NSMenu? {
        guard let url = store.items.first?.fileURL, !store.strip.showsTabBar else { return nil }
        let menu = NSMenu()
        let item = NSMenuItem(title: "Reveal in Finder", action: #selector(RevealTarget.reveal(_:)), keyEquivalent: "")
        item.target = RevealTarget.shared
        item.representedObject = url
        menu.addItem(item)
        return menu
    }

    // MARK: Tabs

    private var tabRow: some View {
        GeometryReader { geometry in
            // Leading space (inset), spacing before + (6), + (26), trailing margin (8), tab row padding (2 + 2).
            let available = geometry.size.width - store.leadingInset - 6 - 26 - 8 - 4
            let count = CGFloat(store.items.count)
            let width = max(minTabWidth, floor((available - spacing * (count - 1)) / count))
            HStack(spacing: 6) {
                Color.clear.frame(width: store.leadingInset - 6)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: spacing) {
                            ForEach(Array(store.items.enumerated()), id: \.element.id) { index, item in
                                tab(item, index: index, width: width).id(item.id)
                            }
                        }
                        .padding(.horizontal, 2) // room for the shown tab's shadow at either end
                        .frame(height: TabWindowController.barHeight)
                    }
                    .onChange(of: store.strip.activeID) { _, id in
                        if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
                    }
                }
                PlusButton { store.actions.newTab() }
                    .padding(.trailing, 8)
            }
        }
    }

    private func tab(_ item: TabBarStore.Item, index: Int, width: CGFloat) -> some View {
        let active = item.id == store.strip.activeID
        let hovered = item.id == hoveredID
        let offset = dragging?.id == item.id ? dragging?.offset ?? 0 : 0
        return ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(background(active: active, hovered: hovered))
                .shadow(color: .black.opacity(active && colorScheme == .light ? 0.12 : 0), radius: 2, y: 0.5)
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(active ? Color.primary.opacity(colorScheme == .light ? 0.08 : 0.1) : .clear, lineWidth: 0.5))
            HStack(spacing: 4) {
                statusSlot(item, hovered: hovered)
                Text(item.title)
                    .font(.system(size: 12, weight: active ? .medium : .regular))
                    .foregroundStyle(active ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity)
                Color.clear.frame(width: 16, height: 16) // balances the left slot so the title stays centered
            }
            .padding(.horizontal, 5)
        }
        .frame(width: width, height: tabHeight)
        .opacity(store.isKeyWindow || active ? 1 : 0.85)
        .overlay(alignment: .trailing) {
            if store.strip.showsTrailingDivider(at: index, hoveredID: hoveredID) {
                Rectangle().fill(Color.primary.opacity(0.14)).frame(width: 1, height: 14).offset(x: spacing / 2 + 0.5)
            }
        }
        .contentShape(Rectangle())
        .offset(x: offset)
        .zIndex(dragging?.id == item.id ? 1 : 0)
        .onHover { inside in hoveredID = inside ? item.id : (hoveredID == item.id ? nil : hoveredID) }
        .onTapGesture { store.actions.select(item.id) }
        .gesture(DragGesture(minimumDistance: 5)
            .updating($dragging) { value, state, _ in state = Drag(id: item.id, offset: value.translation.width) }
            .onChanged { _ in
                // As in Safari, dragging a tab also shows it (a click that moved a little still selects).
                if store.strip.activeID != item.id { store.actions.select(item.id) }
            }
            .onEnded { value in
                let steps = Int((value.translation.width / (width + spacing)).rounded())
                if steps != 0 { store.actions.move(item.id, to: index + steps) }
            })
        .contextMenu {
            Button("Close Tab") { store.actions.close(item.id) }
            Button("Close Other Tabs") { store.actions.closeOthers(item.id) }
            Button("Move Tab to New Window") { store.actions.moveToNewWindow(item.id) }
            if let url = item.fileURL {
                Divider()
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
        .help(item.fileURL?.path ?? item.title)
    }

    private func background(active: Bool, hovered: Bool) -> Color {
        if active {
            return colorScheme == .light ? Color.white.opacity(store.isKeyWindow ? 1 : 0.7) : Color.white.opacity(store.isKeyWindow ? 0.14 : 0.09)
        }
        return hovered ? Color.primary.opacity(0.055) : .clear
    }

    /// Unsaved: a blue dot. Pointer over the tab: × to close.
    @ViewBuilder private func statusSlot(_ item: TabBarStore.Item, hovered: Bool) -> some View {
        ZStack {
            if hovered {
                CloseButton { store.actions.close(item.id) }
            } else if item.edited {
                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
            }
        }
        .frame(width: 16, height: 16)
    }
}

private struct CloseButton: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(hovered ? 0.1 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Close Tab")
    }
}

private struct PlusButton: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovered ? 0.07 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("New Tab (⌘T)")
    }
}

/// Empty title bar space: drag to move the window, double-click to zoom or minimize (as set in System Settings).
struct WindowDragArea: NSViewRepresentable {
    var menu: () -> NSMenu? = { nil }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) { view.menuProvider = menu }

    final class DragView: NSView {
        var menuProvider: () -> NSMenu? = { nil }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
                if action == "Minimize" { window.performMiniaturize(nil) } else if action != "None" { window.performZoom(nil) }
                return
            }
            window.performDrag(with: event)
        }

        override func menu(for event: NSEvent) -> NSMenu? { menuProvider() }
        override var mouseDownCanMoveWindow: Bool { true }
    }
}

final class RevealTarget: NSObject {
    static let shared = RevealTarget()
    @objc func reveal(_ sender: NSMenuItem) {
        (sender.representedObject as? URL).map { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    }
}
