import AppKit
import PRFloatCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var settings: AppSettings!
    private var session: GitHubSession!
    private var store: PRStatusStore!
    private var agentStore: AgentStore!
    private var panelController: FloatingPanelController!
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        settings = AppSettings()
        session = GitHubSession(
            clientID: ClientConfiguration.clientID(),
            http: URLSessionHTTPClient(),
            tokenStore: KeychainTokenStore()
        )
        store = PRStatusStore(session: session, settings: settings)
        agentStore = AgentStore()

        panelController = FloatingPanelController(
            store: store,
            agentStore: agentStore,
            settings: settings,
            onOpenSettings: { [weak self] in self?.openSettings() }
        )

        store.start()
        agentStore.start()

        setupStatusItem()
        panelController.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
        agentStore.stop()
        FloatingPanelController.saveFrame(panelController.panel?.frame)
    }

    // MARK: - Menu bar

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
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettingsMenu), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "About PR Float", action: #selector(showAbout), keyEquivalent: ""))
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
        Task {
            await store.refresh()
            agentStore.reload()
        }
    }

    @objc private func openSettingsMenu() {
        openSettings()
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [:])
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Settings window

    private func openSettings() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsView(
            session: session,
            settings: settings,
            onSignOut: { [weak self] in
                self?.session.signOut()
                Task { await self?.store.refresh() }
            }
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "PR Float Settings"
        window.contentView = NSHostingView(rootView: view)
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        settingsWindow = window
    }
}
