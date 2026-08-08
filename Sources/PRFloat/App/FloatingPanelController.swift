import AppKit
import PRFloatCore
import SwiftUI

/// Always-on-top utility panel hosting the SwiftUI content.
@MainActor
final class FloatingPanelController {
    private static let frameKey = "panelFrame"
    private static let defaultSize = NSSize(width: 360, height: 480)

    private(set) var panel: NSPanel?

    private let store: PRStatusStore
    private let agentStore: AgentStore
    private let settings: AppSettings
    private let onOpenSettings: () -> Void

    init(
        store: PRStatusStore,
        agentStore: AgentStore,
        settings: AppSettings,
        onOpenSettings: @escaping () -> Void
    ) {
        self.store = store
        self.agentStore = agentStore
        self.settings = settings
        self.onOpenSettings = onOpenSettings
    }

    func show() {
        if panel == nil {
            panel = makePanel()
        }
        applyLevel()
        panel?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func toggle() {
        guard let panel else {
            show()
            return
        }
        if panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    /// Reflects the always-on-top preference without rebuilding the panel.
    func applyLevel() {
        panel?.level = settings.alwaysOnTop ? .floating : .normal
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: restoredFrame(),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "PR Float"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = settings.alwaysOnTop ? .floating : .normal
        panel.collectionBehavior = PanelBehavior.collectionBehavior
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.minSize = NSSize(width: 320, height: 160)
        panel.maxSize = NSSize(width: 560, height: 1000)
        panel.isReleasedWhenClosed = false
        panel.delegate = PanelDelegate.shared

        let root = ContentView(
            store: store,
            agentStore: agentStore,
            settings: settings,
            onOpenSettings: onOpenSettings
        )
        .frame(minWidth: 320, minHeight: 160)

        panel.contentView = NSHostingView(rootView: root)

        PanelDelegate.shared.onClose = { [weak panel] in
            Self.saveFrame(panel?.frame)
        }

        return panel
    }

    private func restoredFrame() -> NSRect {
        if let dict = UserDefaults.standard.dictionary(forKey: Self.frameKey),
           let x = dict["x"] as? CGFloat,
           let y = dict["y"] as? CGFloat,
           let w = dict["w"] as? CGFloat,
           let h = dict["h"] as? CGFloat
        {
            let frame = NSRect(x: x, y: y, width: w, height: h)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
                return frame
            }
        }
        return Self.defaultFrame()
    }

    static func defaultFrame() -> NSRect {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        return NSRect(
            x: screen.maxX - defaultSize.width - 24,
            y: screen.maxY - defaultSize.height - 24,
            width: defaultSize.width,
            height: defaultSize.height
        )
    }

    static func saveFrame(_ frame: NSRect?) {
        guard let frame else { return }
        UserDefaults.standard.set(
            ["x": frame.origin.x, "y": frame.origin.y, "w": frame.size.width, "h": frame.size.height],
            forKey: frameKey
        )
    }

    /// Used by Settings → Panel → Reset panel position.
    static func resetFrame() {
        UserDefaults.standard.removeObject(forKey: frameKey)
        let frame = defaultFrame()
        for window in NSApp.windows where window is NSPanel {
            window.setFrame(frame, display: true, animate: true)
        }
    }
}

@MainActor
private final class PanelDelegate: NSObject, NSWindowDelegate {
    static let shared = PanelDelegate()
    var onClose: (() -> Void)?

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            FloatingPanelController.saveFrame(window.frame)
        }
        onClose?()
    }

    func windowDidMove(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            FloatingPanelController.saveFrame(window.frame)
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            FloatingPanelController.saveFrame(window.frame)
        }
    }
}
