import Foundation
import PRFloatCore

// Lightweight validation when XCTest / full Xcode is unavailable.
var failed = 0

func expect(_ cond: @autoclosure () -> Bool, _ message: String) {
    if !cond() {
        print("FAIL: \(message)")
        failed += 1
    } else {
        print("OK:   \(message)")
    }
}

let empty = ChecklistParser.parse(nil)
expect(empty.done == 0 && empty.total == 0, "empty body")

let mixed = ChecklistParser.parse("""
- [x] A
- [ ] B
* [X] C
""")
expect(mixed.done == 2 && mixed.total == 3, "mixed checklist 2/3")

let green = PRSummary(
    number: 1, title: "t", headRefName: "b",
    url: URL(string: "https://example.com")!,
    checklistDone: 1, checklistTotal: 1,
    checks: CheckSummary(passing: 1, failing: 0, pending: 0)
)
expect(green.health == .green, "health green")

let red = PRSummary(
    number: 2, title: "t", headRefName: "b",
    url: URL(string: "https://example.com")!,
    checklistDone: 1, checklistTotal: 1,
    checks: CheckSummary(passing: 0, failing: 1, pending: 0)
)
expect(red.health == .red, "health red")

let rollup = CheckSummary.from(rollupStates: ["SUCCESS", "FAILURE", "PENDING"])
expect(rollup.passing == 1 && rollup.failing == 1 && rollup.pending == 1, "rollup mapping")

let fixture = """
[
  {
    "number": 42,
    "title": "fix",
    "headRefName": "feat",
    "url": "https://github.com/example/repo/pull/42",
    "body": "- [x] a\\n- [ ] b\\n",
    "statusCheckRollup": [
      { "name": "build", "state": "SUCCESS" },
      { "name": "test", "conclusion": "FAILURE" }
    ]
  }
]
""".data(using: .utf8)!

do {
    let rows = try GitHubCLIService.decodePRList(fixture)
    let s = rows[0]
    expect(s.checklistDone == 1 && s.checklistTotal == 2, "fixture checklist")
    expect(s.checks.failing == 1 && s.checks.passing == 1, "fixture checks")
    expect(s.health == .red, "fixture health red")
} catch {
    expect(false, "decode fixture: \(error)")
}

// The panel's collection behavior must be assignable without AppKit raising:
// a contradictory value aborts applicationDidFinishLaunching and the app launches
// with no visible UI at all.
expect(
    PanelBehavior.invalidPairReason(PanelBehavior.collectionBehavior) == nil,
    "panel collection behavior is valid"
)
expect(
    PanelBehavior.invalidPairReason([.canJoinAllSpaces, .moveToActiveSpace])
        == "window behavior cannot be both canJoinAllSpaces and moveToActiveSpace",
    "detects canJoinAllSpaces + moveToActiveSpace"
)

if failed > 0 {
    print("\n\(failed) failure(s)")
    exit(1)
}
print("\nAll validations passed.")
