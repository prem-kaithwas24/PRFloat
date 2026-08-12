import AppKit
import ServiceManagement
import SwiftUI
import PRFloatCore

struct SettingsView: View {
    @Bindable var session: GitHubSession
    @Bindable var settings: AppSettings
    let onSignOut: () -> Void

    var body: some View {
        TabView {
            AccountSettings(session: session, onSignOut: onSignOut)
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
            GeneralSettings(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            PanelSettings(settings: settings)
                .tabItem { Label("Panel", systemImage: "macwindow") }
        }
        .frame(width: 420, height: 300)
    }
}

private struct AccountSettings: View {
    @Bindable var session: GitHubSession
    let onSignOut: () -> Void

    @State private var clientID = ClientConfiguration.clientID()
    @State private var saved = false

    var body: some View {
        Form {
            Section {
                if let account = session.account {
                    HStack(spacing: Theme.Space.md) {
                        AsyncImage(url: account.avatarURL) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Circle().fill(Theme.rowBorder)
                        }
                        .frame(width: 40, height: 40)
                        .clipShape(Circle())

                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.displayName).font(.headline)
                            Text("@\(account.login)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Sign Out", role: .destructive, action: onSignOut)
                    }
                } else {
                    HStack {
                        Text("Not signed in").foregroundStyle(.secondary)
                        Spacer()
                        Button("Sign In") { session.signIn() }
                    }
                }
            }

            Section("OAuth App") {
                TextField("Client ID", text: $clientID, prompt: Text("Iv1.…"))
                    .font(.caption.monospaced())
                HStack {
                    Button("Save") {
                        ClientConfiguration.setOverride(clientID)
                        saved = true
                    }
                    if saved {
                        Text("Saved — sign in again to use it")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Register an app…") {
                        NSWorkspace.shared.open(URL(string: "https://github.com/settings/developers")!)
                    }
                }
                Text("Device flow must be enabled on the OAuth app.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: clientID) { saved = false }
    }
}

private struct GeneralSettings: View {
    @Bindable var settings: AppSettings
    @State private var loginError: String?

    var body: some View {
        Form {
            Picker("Check for updates", selection: $settings.pollInterval) {
                ForEach(AppSettings.PollInterval.allCases) { interval in
                    Text(interval.label).tag(interval)
                }
            }

            Section("Show") {
                Toggle("Agents", isOn: $settings.showAgents)
                Toggle("Pull requests", isOn: $settings.showPullRequests)
                Toggle("PRs to review", isOn: $settings.showReviewRequests)
            }

            Section {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                    .onChange(of: settings.launchAtLogin) { _, enabled in
                        applyLaunchAtLogin(enabled)
                    }
                if let loginError {
                    Text(loginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            // Registration only works from a real bundle, so a debug run will fail here.
            loginError = "Could not update login item: \(error.localizedDescription)"
            settings.launchAtLogin = !enabled
        }
    }
}

private struct PanelSettings: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Toggle("Keep panel above other windows", isOn: $settings.alwaysOnTop)
            Section {
                Button("Reset panel position") {
                    FloatingPanelController.resetFrame()
                }
                Text("Moves the panel back to the top-right of the main screen.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
    }
}
