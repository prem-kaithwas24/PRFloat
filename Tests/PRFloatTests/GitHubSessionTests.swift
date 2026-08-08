import Foundation
import Testing
@testable import PRFloatCore

@MainActor
@Suite("GitHub session")
struct GitHubSessionTests {
    private func makeSession(
        _ steps: [StubHTTPClient.Step],
        stored: StoredToken? = nil
    ) -> (GitHubSession, InMemoryTokenStore) {
        let store = InMemoryTokenStore(stored: stored)
        let session = GitHubSession(clientID: "cid", http: StubHTTPClient(steps), tokenStore: store)
        session.sleep = { _ in }
        return (session, store)
    }

    private static let accountJSON = #"{"login":"octocat","name":"Mona","avatar_url":null}"#

    @Test("Starts signed out with no stored token")
    func startsSignedOut() async {
        let (session, _) = makeSession([])
        await session.restore()

        #expect(session.state == .signedOut)
        #expect(!session.isSignedIn)
        #expect(session.apiClient == nil)
    }

    @Test("Restores a stored token by verifying it against GitHub")
    func restoresStoredToken() async {
        let (session, _) = makeSession(
            [.respond(.json(Self.accountJSON))],
            stored: StoredToken(token: "t", login: "octocat")
        )
        await session.restore()

        #expect(session.isSignedIn)
        #expect(session.account?.login == "octocat")
        #expect(session.apiClient != nil)
    }

    @Test("A rejected stored token expires the session and is discarded")
    func restoreWithRejectedToken() async {
        let (session, store) = makeSession(
            [.respond(.json(#"{"message":"Bad credentials"}"#, status: 401))],
            stored: StoredToken(token: "stale", login: "octocat")
        )
        await session.restore()

        #expect(session.state == .expired)
        #expect(try! store.read() == nil)
    }

    @Test("Being offline at launch keeps the user signed in")
    func restoreWhileOffline() async {
        let (session, store) = makeSession(
            [.fail(.offline)],
            stored: StoredToken(token: "t", login: "octocat")
        )
        await session.restore()

        #expect(session.isSignedIn)
        #expect(session.account?.login == "octocat")
        #expect(try! store.read() != nil, "an offline launch must not discard the token")
    }

    @Test("A full device flow signs in and persists the token")
    func signInHappyPath() async throws {
        let (session, store) = makeSession([
            .respond(.json("""
            {"device_code":"dc","user_code":"WXYZ-1234",
             "verification_uri":"https://github.com/login/device",
             "expires_in":900,"interval":1}
            """)),
            .respond(.json(#"{"error":"authorization_pending"}"#)),
            .respond(.json(#"{"access_token":"gho_abc"}"#)),
            .respond(.json(Self.accountJSON))
        ])

        session.signIn()
        try await waitUntil { session.isSignedIn }

        #expect(session.account?.login == "octocat")
        #expect(try store.read()?.token == "gho_abc")
    }

    @Test("The user code is exposed while waiting for authorisation")
    func exposesUserCode() async throws {
        let (session, _) = makeSession([
            .respond(.json("""
            {"device_code":"dc","user_code":"WXYZ-1234",
             "verification_uri":"https://github.com/login/device",
             "expires_in":900,"interval":1}
            """)),
            .respond(.json(#"{"error":"authorization_pending"}"#))
        ])
        // A real pause between polls, so the signing-in state is observable rather than
        // racing straight through to the next response.
        session.sleep = { _ in try? await Task.sleep(nanoseconds: 50_000_000) }

        session.signIn()
        try await waitUntil {
            if case .signingIn = session.state { return true }
            return false
        }

        guard case .signingIn(let grant) = session.state else {
            Issue.record("expected signingIn state")
            return
        }
        #expect(grant.userCode == "WXYZ-1234")
        session.cancelSignIn()
    }

    @Test("Denying on GitHub returns to signed out with a reason")
    func signInDenied() async throws {
        let (session, _) = makeSession([
            .respond(.json("""
            {"device_code":"dc","user_code":"C","verification_uri":"https://x.test",
             "expires_in":900,"interval":1}
            """)),
            .respond(.json(#"{"error":"access_denied"}"#))
        ])

        session.signIn()
        try await waitUntil { session.lastError != nil }

        #expect(session.state == .signedOut)
        #expect(session.lastError == DeviceFlowError.accessDenied.localizedDescription)
    }

    @Test("Signing out clears both state and stored credentials")
    func signOut() async {
        let (session, store) = makeSession(
            [.respond(.json(Self.accountJSON))],
            stored: StoredToken(token: "t", login: "octocat")
        )
        await session.restore()
        #expect(session.isSignedIn)

        session.signOut()

        #expect(session.state == .signedOut)
        #expect(session.apiClient == nil)
        #expect(try! store.read() == nil)
    }

    @Test("A 401 during refresh expires the session rather than signing out silently")
    func markExpired() async {
        let (session, store) = makeSession(
            [.respond(.json(Self.accountJSON))],
            stored: StoredToken(token: "t", login: "octocat")
        )
        await session.restore()

        session.markExpired()

        #expect(session.state == .expired)
        #expect(try! store.read() == nil)
    }

    /// Polls a condition rather than sleeping a fixed time, so the test is not timing-bound.
    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        Issue.record("condition not met within \(timeout)s")
    }
}

@Suite("Token storage")
struct TokenStoreTests {
    @Test("In-memory store round-trips and deletes")
    func inMemoryRoundTrip() throws {
        let store = InMemoryTokenStore()
        #expect(try store.read() == nil)

        try store.write(StoredToken(token: "abc", login: "octocat"))
        #expect(try store.read() == StoredToken(token: "abc", login: "octocat"))

        try store.delete()
        #expect(try store.read() == nil)
    }

    @Test("Deleting an absent token is not an error")
    func deleteMissing() throws {
        try InMemoryTokenStore().delete()
    }
}

@Suite("Client configuration")
struct ClientConfigurationTests {
    private func defaults(_ name: String) throws -> UserDefaults {
        let suite = try #require(UserDefaults(suiteName: name))
        suite.removePersistentDomain(forName: name)
        return suite
    }

    @Test("An override takes precedence over the bundled ID")
    func overrideWins() throws {
        let suite = try defaults("prfloat.tests.override")
        ClientConfiguration.setOverride("Iv1.custom", defaults: suite)

        #expect(ClientConfiguration.clientID(bundle: .module, defaults: suite) == "Iv1.custom")
    }

    @Test("Blank overrides are cleared rather than stored")
    func blankOverrideClears() throws {
        let suite = try defaults("prfloat.tests.blank")
        ClientConfiguration.setOverride("Iv1.custom", defaults: suite)
        ClientConfiguration.setOverride("   ", defaults: suite)

        #expect(ClientConfiguration.clientID(bundle: .module, defaults: suite).isEmpty)
    }

    @Test("With nothing configured the ID is empty so the UI can explain setup")
    func emptyByDefault() throws {
        let suite = try defaults("prfloat.tests.empty")
        #expect(ClientConfiguration.clientID(bundle: .module, defaults: suite).isEmpty)
    }
}
