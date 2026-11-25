import AppKit

/// A small notice near the top of the screen that never takes focus (Ferry is in the background while
/// the user pastes into another app).
enum PasteHUD {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ message: String, for seconds: TimeInterval = 3) {
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + 32, height: label.frame.height + 18)

        let panel = self.panel ?? makePanel()
        self.panel = panel
        let effect = panel.contentView as! NSVisualEffectView
        effect.subviews.forEach { $0.removeFromSuperview() }
        label.frame.origin = NSPoint(x: 16, y: 9)
        effect.addSubview(label)

        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 24,
                              width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { panel.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        panel.contentView = effect
        return panel
    }
}
