import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var store: PRStatusStore!
    private var panelController: FloatingPanelController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        store = PRStatusStore()
        panelController = FloatingPanelController(store: store)
        store.start()

        setupStatusItem()
        panelController.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
        FloatingPanelController.saveFrame(panelController.panel?.frame)
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "checklist",
                accessibilityDescription: "PR Float"
            )
            button.image?.isTemplate = true
            button.toolTip = "PR Float"
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show / Hide Panel", action: #selector(togglePanel), keyEquivalent: "p"))
        menu.addItem(NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Choose Repo…", action: #selector(chooseRepo), keyEquivalent: "o"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit PR Float", action: #selector(quit), keyEquivalent: "q"))
        for entry in menu.items {
            entry.target = self
        }
        item.menu = menu
        statusItem = item
    }

    @objc private func togglePanel() {
        panelController.toggle()
    }

    @objc private func refresh() {
        Task { await store.refresh() }
    }

    @objc private func chooseRepo() {
        panelController.show()
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Watch"
        panel.message = "Select a local git repository"
        if panel.runModal() == .OK, let url = panel.url {
            store.setRepoPath(url.path)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
