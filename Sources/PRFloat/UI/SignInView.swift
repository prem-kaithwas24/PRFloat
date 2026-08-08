import AppKit
import SwiftUI
import PRFloatCore

/// Signed-out and signing-in states: the only thing the panel shows before auth.
struct SignInView: View {
    @Bindable var session: GitHubSession
    let clientID: String
    let onSaveClientID: (String) -> Void

    @State private var clientIDField = ""
    @State private var showingSetup = false
    @State private var copied = false

    var body: some View {
        VStack(spacing: Theme.Space.lg) {
            switch session.state {
            case .signingIn(let grant):
                deviceCode(grant)
            default:
                signedOut
            }
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Space.lg)
    }

    // MARK: - Signed out

    private var signedOut: some View {
        VStack(spacing: Theme.Space.md) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)

            Text(session.state == .expired ? "Session expired" : "Connect to GitHub")
                .font(.headline)

            Text(session.state == .expired
                 ? "Your GitHub session is no longer valid. Sign in again to keep watching your PRs."
                 : "Sign in to see every open pull request you have, across all your repositories.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let error = session.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Ask the session, not a captured copy: the ID can be pasted while running.
            if !session.hasClientID || showingSetup {
                setupForm
            } else {
                Button("Sign in with GitHub") { session.signIn() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)

                Button("Use a different OAuth app") { showingSetup = true }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var setupForm: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(ClientConfiguration.setupInstructions)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Theme.Space.sm) {
                TextField("Client ID", text: $clientIDField)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                Button("Save & Sign In") {
                    onSaveClientID(clientIDField)
                    showingSetup = false
                    // The provider now resolves the new ID, so this can succeed.
                    session.signIn()
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.small)
                .disabled(clientIDField.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Button("Open GitHub developer settings") {
                NSWorkspace.shared.open(URL(string: "https://github.com/settings/developers")!)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.tint)
        }
        .onAppear { clientIDField = clientID }
    }

    // MARK: - Signing in

    private func deviceCode(_ grant: DeviceCodeGrant) -> some View {
        VStack(spacing: Theme.Space.md) {
            Text("Enter this code on GitHub")
                .font(.headline)

            Text(grant.userCode)
                .font(.system(.title2, design: .monospaced).weight(.semibold))
                .tracking(2)
                .padding(.vertical, Theme.Space.sm)
                .padding(.horizontal, Theme.Space.lg)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.row)
                        .fill(Theme.rowBackground)
                )
                .textSelection(.enabled)

            Button(copied ? "Copied — waiting for you…" : "Copy & Open GitHub") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(grant.userCode, forType: .string)
                NSWorkspace.shared.open(grant.verificationURI)
                copied = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)

            HStack(spacing: Theme.Space.sm) {
                ProgressView().controlSize(.small)
                Text("Waiting for authorisation…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Cancel") { session.cancelSignIn() }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}
