import XCTest
@testable import PRFloatCore

final class CheckSummaryTests: XCTestCase {
    func testHealthGreen() {
        let pr = PRSummary(
            number: 1,
            title: "ok",
            headRefName: "main",
            url: URL(string: "https://example.com")!,
            checklistDone: 2,
            checklistTotal: 2,
            checks: CheckSummary(passing: 3, failing: 0, pending: 0)
        )
        XCTAssertEqual(pr.health, .green)
        XCTAssertFalse(pr.needsAttention)
    }

    func testHealthYellowIncompleteChecklist() {
        let pr = PRSummary(
            number: 1,
            title: "wip",
            headRefName: "feat",
            url: URL(string: "https://example.com")!,
            checklistDone: 1,
            checklistTotal: 3,
            checks: CheckSummary(passing: 2, failing: 0, pending: 0)
        )
        XCTAssertEqual(pr.health, .yellow)
    }

    func testHealthYellowPending() {
        let pr = PRSummary(
            number: 1,
            title: "pending",
            headRefName: "feat",
            url: URL(string: "https://example.com")!,
            checklistDone: 0,
            checklistTotal: 0,
            checks: CheckSummary(passing: 1, failing: 0, pending: 2)
        )
        XCTAssertEqual(pr.health, .yellow)
    }

    func testHealthRed() {
        let pr = PRSummary(
            number: 1,
            title: "fail",
            headRefName: "feat",
            url: URL(string: "https://example.com")!,
            checklistDone: 3,
            checklistTotal: 3,
            checks: CheckSummary(passing: 1, failing: 1, pending: 0)
        )
        XCTAssertEqual(pr.health, .red)
        XCTAssertTrue(pr.needsAttention)
    }

    func testRollupMapping() {
        let summary = CheckSummary.from(rollupStates: ["SUCCESS", "FAILURE", "PENDING"])
        XCTAssertEqual(summary.passing, 1)
        XCTAssertEqual(summary.failing, 1)
        XCTAssertEqual(summary.pending, 1)
        XCTAssertEqual(summary.label, "1 failing")
    }

    func testDecodeFixture() throws {
        let url = Bundle.module.url(forResource: "pr-list-sample", withExtension: "json", subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: "pr-list-sample", withExtension: "json")
        let fixtureURL = try XCTUnwrap(url)
        let data = try Data(contentsOf: fixtureURL)
        let rows = try GitHubCLIService.decodePRList(data)
        XCTAssertEqual(rows.count, 2)

        let first = rows[0]
        XCTAssertEqual(first.number, 42)
        XCTAssertEqual(first.checklistDone, 2)
        XCTAssertEqual(first.checklistTotal, 3)
        XCTAssertEqual(first.checks.passing, 2)
        XCTAssertEqual(first.checks.failing, 0)
        XCTAssertEqual(first.checks.pending, 1)
        XCTAssertEqual(first.health, .yellow)

        let second = rows[1]
        XCTAssertEqual(second.number, 39)
        XCTAssertEqual(second.checklistTotal, 0)
        XCTAssertEqual(second.checks.failing, 1)
        XCTAssertEqual(second.health, .red)
    }
}
