import Foundation
import Testing
@testable import PRFloatCore

@Suite("Pull request search decoding")
struct PullRequestQueryTests {
    private func fixture() throws -> Data {
        let url = Bundle.module.url(
            forResource: "pr-search-sample",
            withExtension: "json",
            subdirectory: "Fixtures"
        ) ?? Bundle.module.url(forResource: "pr-search-sample", withExtension: "json")
        let fixtureURL = try #require(url, "pr-search-sample.json missing from test bundle")
        return try Data(contentsOf: fixtureURL)
    }

    @Test("Decodes a recorded GraphQL search payload across repos")
    func decodesFixture() throws {
        let prs = try PullRequestQuery.decode(fixture())

        // Five nodes, one of which is the empty non-PR result that must be dropped.
        #expect(prs.count == 4)
        #expect(prs.map(\.repository).contains("example/other"))
    }

    @Test("StatusContext entries produce checklist and check counts")
    func statusContextPR() throws {
        let prs = try PullRequestQuery.decode(fixture())
        let pr = try #require(prs.first { $0.number == 42 })

        #expect(pr.repository == "example/repo")
        #expect(pr.title == "fix: login timeout")
        #expect(pr.headRefName == "feature/login-timeout")
        #expect(pr.checklistDone == 2)
        #expect(pr.checklistTotal == 3)
        #expect(pr.checks.passing == 2)
        #expect(pr.checks.pending == 1)
        #expect(pr.health == .yellow)
        #expect(!pr.isDraft)
    }

    @Test("A failing CheckRun makes the PR red")
    func checkRunFailure() throws {
        let prs = try PullRequestQuery.decode(fixture())
        let pr = try #require(prs.first { $0.number == 39 })

        #expect(pr.repository == "example/other")
        #expect(pr.checklistTotal == 0)
        #expect(pr.checks.failing == 1)
        #expect(pr.health == .red)
    }

    @Test("Draft state and a null body survive decoding")
    func draftWithNullBody() throws {
        let prs = try PullRequestQuery.decode(fixture())
        let pr = try #require(prs.first { $0.number == 7 })

        #expect(pr.isDraft)
        #expect(pr.checklistTotal == 0)
        #expect(pr.checks.pending == 1)
    }

    @Test("A missing rollup means no checks rather than a decode failure")
    func missingRollup() throws {
        let prs = try PullRequestQuery.decode(fixture())
        let pr = try #require(prs.first { $0.number == 3 })

        #expect(pr.checks.total == 0)
        #expect(pr.checks.label == "No checks")
        #expect(pr.checklistComplete)
        #expect(pr.health == .green)
    }

    @Test("GraphQL errors are raised rather than silently returning nothing")
    func graphQLErrors() {
        let body = Data(#"{"errors":[{"message":"Bad query"}]}"#.utf8)
        #expect(throws: GitHubAPIError.graphQL("Bad query")) {
            _ = try PullRequestQuery.decode(body)
        }
    }

    @Test("The query asks only for open PRs authored by the signed-in user")
    func searchTerms() {
        #expect(PullRequestQuery.searchQuery.contains("is:pr"))
        #expect(PullRequestQuery.searchQuery.contains("is:open"))
        #expect(PullRequestQuery.searchQuery.contains("author:@me"))
    }

    @Test("A second search targets PRs where the user is requested as a reviewer")
    func reviewRequestedSearchTerms() {
        #expect(PullRequestQuery.reviewRequestedSearchQuery.contains("is:pr"))
        #expect(PullRequestQuery.reviewRequestedSearchQuery.contains("is:open"))
        #expect(PullRequestQuery.reviewRequestedSearchQuery.contains("review-requested:@me"))
    }

    @Test("fetch sends the overridden query string as the GraphQL q variable")
    func fetchUsesOverriddenQuery() async throws {
        let http = StubHTTPClient(json: #"{"data":{"search":{"nodes":[]}}}"#)
        let client = GitHubAPIClient(http: http, token: "t")

        let prs = try await PullRequestQuery.fetch(
            using: client,
            query: PullRequestQuery.reviewRequestedSearchQuery
        )

        #expect(prs.isEmpty)
        #expect(http.bodyString(at: 0).contains("review-requested:@me"))
    }

    @Test("first is a literal in the query, not a $first variable GitHub would reject as a string")
    func firstIsNotASentVariable() async throws {
        let http = StubHTTPClient(json: #"{"data":{"search":{"nodes":[]}}}"#)
        let client = GitHubAPIClient(http: http, token: "t")

        _ = try await PullRequestQuery.fetch(using: client)

        let body = http.bodyString(at: 0)
        #expect(body.contains("first: 50"))
        #expect(!body.contains(#""first""#))
    }
}
