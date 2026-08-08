import Foundation

/// One entry from a commit's `statusCheckRollup.contexts`.
///
/// The connection mixes two types: `CheckRun` carries `status` + `conclusion`, while
/// `StatusContext` carries `state`. Every field is optional so one decoder handles both.
struct GHCheck: Decodable, Equatable {
    let state: String?
    let status: String?
    let conclusion: String?
    let name: String?
    let context: String?

    init(state: String? = nil, status: String? = nil, conclusion: String? = nil, name: String? = nil, context: String? = nil) {
        self.state = state
        self.status = status
        self.conclusion = conclusion
        self.name = name
        self.context = context
    }

    /// A completed `CheckRun` reports its outcome in `conclusion`; an in-flight one only
    /// has `status`, so conclusion must win when both are present.
    var normalized: String {
        (conclusion ?? state ?? status ?? "").lowercased()
    }
}

extension CheckSummary {
    private static let passingStates: Set<String> = [
        "success", "pass", "passed", "neutral", "skipped"
    ]
    private static let failingStates: Set<String> = [
        "failure", "failed", "error", "timed_out", "cancelled", "action_required", "startup_failure"
    ]
    public static func from(rollupStates: [String]) -> CheckSummary {
        from(rollup: rollupStates.map { GHCheck(state: $0) })
    }

    static func from(rollup: [GHCheck]) -> CheckSummary {
        var passing = 0
        var failing = 0
        var pending = 0

        for check in rollup {
            let state = check.normalized
            if passingStates.contains(state) {
                passing += 1
            } else if failingStates.contains(state) {
                failing += 1
            } else {
                // Unknown or absent states count as pending so the user notices rather
                // than seeing a PR reported green on incomplete information.
                pending += 1
            }
        }

        return CheckSummary(passing: passing, failing: failing, pending: pending)
    }
}
