import Foundation
import Testing
@testable import PRFloatCore

@Suite("GitHub API client")
struct GitHubAPIClientTests {
    @Test("Decodes the authenticated account")
    func account() async throws {
        let http = StubHTTPClient(json: """
        {"login":"octocat","name":"Mona","avatar_url":"https://example.com/a.png"}
        """)
        let account = try await GitHubAPIClient(http: http, token: "t").account()

        #expect(account.login == "octocat")
        #expect(account.displayName == "Mona")
        #expect(account.avatarURL?.absoluteString == "https://example.com/a.png")
    }

    @Test("Falls back to the handle when GitHub has no display name")
    func accountWithoutName() async throws {
        let http = StubHTTPClient(json: #"{"login":"octocat","name":null,"avatar_url":null}"#)
        let account = try await GitHubAPIClient(http: http, token: "t").account()
        #expect(account.displayName == "octocat")
    }

    @Test("Sends a bearer token")
    func sendsBearer() async throws {
        let http = StubHTTPClient(json: #"{"login":"octocat"}"#)
        _ = try await GitHubAPIClient(http: http, token: "secret").account()

        let header = http.requests.first?.value(forHTTPHeaderField: "Authorization")
        #expect(header == "Bearer secret")
    }

    @Test("401 becomes an explicit expiry, not an empty list")
    func unauthorized() async {
        let http = StubHTTPClient([.respond(.json(#"{"message":"Bad credentials"}"#, status: 401))])
        await #expect(throws: GitHubAPIError.unauthorized) {
            _ = try await GitHubAPIClient(http: http, token: "t").account()
        }
    }

    @Test("403 with an exhausted quota is rate limiting")
    func rateLimited() throws {
        let reset = Date().addingTimeInterval(600)
        let response = HTTPResponse.json(
            #"{"message":"API rate limit exceeded"}"#,
            status: 403,
            headers: [
                "x-ratelimit-remaining": "0",
                "x-ratelimit-reset": String(Int(reset.timeIntervalSince1970))
            ]
        )

        #expect(throws: GitHubAPIError.self) {
            try GitHubAPIClient.validate(response)
        }
        let resetAt = try #require(GitHubAPIClient.resetDate(from: response))
        #expect(abs(resetAt.timeIntervalSince(reset)) < 1)
    }

    @Test("403 with quota remaining is a permission error, not a rate limit")
    func forbiddenNotRateLimited() {
        let response = HTTPResponse.json(
            #"{"message":"Resource not accessible"}"#,
            status: 403,
            headers: ["x-ratelimit-remaining": "4999"]
        )
        #expect(throws: GitHubAPIError.http(status: 403, message: "Resource not accessible")) {
            try GitHubAPIClient.validate(response)
        }
    }

    @Test("Offline transport failures map to an offline error")
    func offline() async {
        let http = StubHTTPClient([.fail(.offline)])
        await #expect(throws: GitHubAPIError.offline) {
            _ = try await GitHubAPIClient(http: http, token: "t").account()
        }
    }

    @Test("GraphQL errors surface their message")
    func graphQLError() async {
        let http = StubHTTPClient(json: #"{"errors":[{"message":"Field 'nope' doesn't exist"}]}"#)
        await #expect(throws: GitHubAPIError.graphQL("Field 'nope' doesn't exist")) {
            _ = try await GitHubAPIClient(http: http, token: "t")
                .graphQL(query: "{}", as: SearchPayload.self)
        }
    }

    @Test("Header lookup ignores case, as HTTP requires")
    func headerCaseInsensitive() {
        let response = HTTPResponse(status: 200, headers: ["X-RateLimit-Remaining": "0"])
        #expect(response.header("x-ratelimit-remaining") == "0")
    }

    @Test("Only transient failures are worth retrying")
    func transience() {
        #expect(GitHubAPIError.offline.isTransient)
        #expect(GitHubAPIError.rateLimited(resetAt: nil).isTransient)
        #expect(GitHubAPIError.http(status: 502, message: "").isTransient)
        #expect(!GitHubAPIError.unauthorized.isTransient)
        #expect(!GitHubAPIError.http(status: 404, message: "").isTransient)
    }

    @Test("Backoff grows exponentially and stops at the cap")
    func backoff() {
        #expect(Backoff.delay(attempt: 0) == 0)
        #expect(Backoff.delay(attempt: 1) == 2)
        #expect(Backoff.delay(attempt: 2) == 4)
        #expect(Backoff.delay(attempt: 3) == 8)
        #expect(Backoff.delay(attempt: 30) == 900)
    }
}
