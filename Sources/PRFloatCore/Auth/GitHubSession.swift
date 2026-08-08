import Foundation
import Observation

/// Owns signed-in state and drives the device flow.
///
/// `expired` is deliberately distinct from `signedOut`: the UI needs to say *why* the PR
/// list went away, rather than silently showing a sign-in screen as if the user had never
/// authenticated.
@MainActor
@Observable
public final class GitHubSession {
    public enum State: Equatable, Sendable {
        case signedOut
        case signingIn(DeviceCodeGrant)
        case signedIn(GitHubAccount)
        case expired
    }

    public private(set) var state: State = .signedOut
    public private(set) var lastError: String?

    private let clientID: String
    private let http: HTTPClient
    private let tokenStore: TokenStore
    private var token: String?
    private var signInTask: Task<Void, Never>?

    /// Sleep hook so tests do not wait real seconds between polls.
    var sleep: @Sendable (TimeInterval) async -> Void = { seconds in
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    public init(clientID: String, http: HTTPClient, tokenStore: TokenStore) {
        self.clientID = clientID
        self.http = http
        self.tokenStore = tokenStore
    }

    public var isSignedIn: Bool {
        if case .signedIn = state { return true }
        return false
    }

    public var account: GitHubAccount? {
        if case .signedIn(let account) = state { return account }
        return nil
    }

    /// An authenticated client, or nil when there is no usable token.
    public var apiClient: GitHubAPIClient? {
        guard let token else { return nil }
        return GitHubAPIClient(http: http, token: token)
    }

    /// Loads any stored token at launch and verifies it still works.
    public func restore() async {
        guard let stored = try? tokenStore.read(), !stored.token.isEmpty else {
            state = .signedOut
            return
        }
        token = stored.token
        do {
            let account = try await GitHubAPIClient(http: http, token: stored.token).account()
            state = .signedIn(account)
            lastError = nil
        } catch GitHubAPIError.unauthorized {
            token = nil
            try? tokenStore.delete()
            state = .expired
        } catch {
            // Offline at launch is not a reason to sign the user out; trust the token and
            // let the first refresh surface any real problem.
            state = .signedIn(GitHubAccount(login: stored.login))
        }
    }

    public func signIn() {
        guard signInTask == nil else { return }
        lastError = nil
        signInTask = Task { [weak self] in
            await self?.runDeviceFlow()
            self?.signInTask = nil
        }
    }

    public func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        if case .signingIn = state { state = .signedOut }
    }

    public func signOut() {
        cancelSignIn()
        token = nil
        try? tokenStore.delete()
        lastError = nil
        state = .signedOut
    }

    /// Called by the data layer when a request comes back 401.
    public func markExpired() {
        token = nil
        try? tokenStore.delete()
        state = .expired
    }

    // MARK: - Device flow

    private func runDeviceFlow() async {
        let client = DeviceFlowClient(clientID: clientID, http: http)

        let grant: DeviceCodeGrant
        do {
            grant = try await client.requestDeviceCode()
        } catch {
            lastError = error.localizedDescription
            state = .signedOut
            return
        }

        state = .signingIn(grant)

        var interval = TimeInterval(grant.interval)
        let deadline = Date().addingTimeInterval(TimeInterval(grant.expiresIn))

        while !Task.isCancelled {
            if Date() >= deadline {
                lastError = DeviceFlowError.expiredCode.localizedDescription
                state = .signedOut
                return
            }

            await sleep(interval)
            if Task.isCancelled { return }

            do {
                switch try await client.poll(deviceCode: grant.deviceCode) {
                case .pending:
                    continue
                case .slowDown(let newInterval):
                    interval = TimeInterval(newInterval)
                case .token(let accessToken):
                    await completeSignIn(with: accessToken)
                    return
                }
            } catch {
                lastError = error.localizedDescription
                state = .signedOut
                return
            }
        }
    }

    private func completeSignIn(with accessToken: String) async {
        token = accessToken
        do {
            let account = try await GitHubAPIClient(http: http, token: accessToken).account()
            try? tokenStore.write(StoredToken(token: accessToken, login: account.login))
            lastError = nil
            state = .signedIn(account)
        } catch {
            lastError = error.localizedDescription
            token = nil
            state = .signedOut
        }
    }
}
