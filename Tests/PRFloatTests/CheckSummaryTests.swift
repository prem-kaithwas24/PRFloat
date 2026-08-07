import Foundation
import Testing
@testable import PRFloatCore

private func makePR(
    checklistDone: Int,
    checklistTotal: Int,
    checks: CheckSummary
) -> PRSummary {
    PRSummary(
        number: 1,
        title: "t",
        headRefName: "feat",
        url: URL(string: "https://example.com")!,
        checklistDone: checklistDone,
        checklistTotal: checklistTotal,
        checks: checks
    )
}

@Suite("PR health")
struct PRHealthTests {
    @Test("Complete checklist with all checks passing is green")
    func healthGreen() {
        let pr = makePR(
            checklistDone: 2,
            checklistTotal: 2,
            checks: CheckSummary(passing: 3, failing: 0, pending: 0)
        )
        #expect(pr.health == .green)
        #expect(!pr.needsAttention)
    }

    @Test("Incomplete checklist is yellow")
    func healthYellowIncompleteChecklist() {
        let pr = makePR(
            checklistDone: 1,
            checklistTotal: 3,
            checks: CheckSummary(passing: 2, failing: 0, pending: 0)
        )
        #expect(pr.health == .yellow)
    }

    @Test("Pending checks are yellow even with no checklist")
    func healthYellowPending() {
        let pr = makePR(
            checklistDone: 0,
            checklistTotal: 0,
            checks: CheckSummary(passing: 1, failing: 0, pending: 2)
        )
        #expect(pr.health == .yellow)
    }

    @Test("Any failing check is red and needs attention")
    func healthRed() {
        let pr = makePR(
            checklistDone: 3,
            checklistTotal: 3,
            checks: CheckSummary(passing: 1, failing: 1, pending: 0)
        )
        #expect(pr.health == .red)
        #expect(pr.needsAttention)
    }
}

@Suite("gh output decoding")
struct GitHubDecodingTests {
    @Test("Maps rollup states to passing/failing/pending")
    func rollupMapping() {
        let summary = CheckSummary.from(rollupStates: ["SUCCESS", "FAILURE", "PENDING"])
        #expect(summary.passing == 1)
        #expect(summary.failing == 1)
        #expect(summary.pending == 1)
        #expect(summary.label == "1 failing")
    }

    @Test("Decodes a real `gh pr list --json` payload")
    func decodeFixture() throws {
        let url = Bundle.module.url(
            forResource: "pr-list-sample",
            withExtension: "json",
            subdirectory: "Fixtures"
        ) ?? Bundle.module.url(forResource: "pr-list-sample", withExtension: "json")
        let fixtureURL = try #require(url, "pr-list-sample.json missing from test bundle")

        let rows = try GitHubCLIService.decodePRList(Data(contentsOf: fixtureURL))
        #expect(rows.count == 2)

        let first = try #require(rows.first)
        #expect(first.number == 42)
        #expect(first.checklistDone == 2)
        #expect(first.checklistTotal == 3)
        #expect(first.checks.passing == 2)
        #expect(first.checks.failing == 0)
        #expect(first.checks.pending == 1)
        #expect(first.health == .yellow)

        let second = rows[1]
        #expect(second.number == 39)
        #expect(second.checklistTotal == 0)
        #expect(second.checks.failing == 1)
        #expect(second.health == .red)
    }
}
