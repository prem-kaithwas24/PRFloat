import Foundation
import Testing
@testable import PRFloatCore

private func makePR(
    repository: String = "example/repo",
    number: Int = 1,
    checklistDone: Int,
    checklistTotal: Int,
    checks: CheckSummary
) -> PRSummary {
    PRSummary(
        repository: repository,
        number: number,
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

    @Test("Identity includes the repository, since PR numbers repeat across repos")
    func identityIsRepoScoped() {
        let a = makePR(repository: "example/one", number: 5, checklistDone: 0, checklistTotal: 0, checks: .empty)
        let b = makePR(repository: "example/two", number: 5, checklistDone: 0, checklistTotal: 0, checks: .empty)

        #expect(a.id != b.id)
        #expect(a.id == "example/one#5")
    }

    @Test("Grouping headers drop the owner")
    func shortName() {
        let pr = makePR(repository: "moxiworks/some-service", checklistDone: 0, checklistTotal: 0, checks: .empty)
        #expect(pr.repositoryShortName == "some-service")
    }
}

@Suite("Check rollup mapping")
struct CheckRollupTests {
    @Test("Maps rollup states to passing/failing/pending")
    func rollupMapping() {
        let summary = CheckSummary.from(rollupStates: ["SUCCESS", "FAILURE", "PENDING"])
        #expect(summary.passing == 1)
        #expect(summary.failing == 1)
        #expect(summary.pending == 1)
        #expect(summary.label == "1 failing")
    }

    @Test("Neutral and skipped runs count as passing")
    func neutralPasses() {
        let summary = CheckSummary.from(rollupStates: ["NEUTRAL", "SKIPPED"])
        #expect(summary.passing == 2)
        #expect(summary.label == "CI passing")
    }

    @Test("A completed CheckRun is judged on conclusion, not status")
    func conclusionWinsOverStatus() {
        let summary = CheckSummary.from(rollup: [
            GHCheck(status: "COMPLETED", conclusion: "FAILURE", name: "lint")
        ])
        #expect(summary.failing == 1)
    }

    @Test("An in-flight CheckRun with no conclusion is pending")
    func inProgressIsPending() {
        let summary = CheckSummary.from(rollup: [
            GHCheck(status: "IN_PROGRESS", conclusion: nil, name: "build")
        ])
        #expect(summary.pending == 1)
    }

    @Test("Unrecognised states count as pending so nothing looks falsely green")
    func unknownIsPending() {
        let summary = CheckSummary.from(rollupStates: ["SOMETHING_NEW", ""])
        #expect(summary.pending == 2)
        #expect(summary.passing == 0)
    }

    @Test("No checks at all is reported as such")
    func noChecks() {
        #expect(CheckSummary.from(rollupStates: []).label == "No checks")
    }
}
