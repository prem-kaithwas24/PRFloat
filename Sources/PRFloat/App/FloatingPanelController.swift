import AppKit
import PRFloatCore
import SwiftUI

/// Always-on-top utility panel hosting SwiftUI content.
@MainActor
final class FloatingPanelController {
    private static let frameKey = "panelFrame"

    private(set) var panel: NSPanel?
    private let store: PRStatusStore

    init(store: PRStatusStore) {
        self.store = store
    }

    func show() {
        if panel == nil {
            panel = makePanel()
        }
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
        panel.level = .floating
        panel.collectionBehavior = PanelBehavior.collectionBehavior
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.minSize = NSSize(width: 280, height: 120)
        panel.maxSize = NSSize(width: 520, height: 900)
        panel.isReleasedWhenClosed = false
        panel.delegate = PanelDelegate.shared

        let root = ContentView(store: store)
            .frame(minWidth: 280, minHeight: 120)
        let hosting = NSHostingView(rootView: root)
        panel.contentView = hosting

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
        // Default: upper-right of main screen
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let size = NSSize(width: 320, height: 400)
        return NSRect(
            x: screen.maxX - size.width - 24,
            y: screen.maxY - size.height - 24,
            width: size.width,
            height: size.height
        )
    }

    static func saveFrame(_ frame: NSRect?) {
        guard let frame else { return }
        UserDefaults.standard.set(
            ["x": frame.origin.x, "y": frame.origin.y, "w": frame.size.width, "h": frame.size.height],
            forKey: frameKey
        )
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
