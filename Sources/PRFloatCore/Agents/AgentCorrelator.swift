import Foundation

/// Links agents to the pull requests they are working on.
///
/// The match is (repository, branch) → (repository, headRefName). Branch alone is not
/// enough: `main` or `develop` exists in every repo.
public enum AgentCorrelator {
    /// Agents keyed by `PRSummary.id`.
    public static func index(agents: [AgentSession], prs: [PRSummary]) -> [String: [AgentSession]] {
        guard !agents.isEmpty, !prs.isEmpty else { return [:] }

        var result: [String: [AgentSession]] = [:]
        for pr in prs {
            let matches = agents.filter { agent in
                guard let repository = agent.repository, let branch = agent.branch else { return false }
                return repository.caseInsensitiveCompare(pr.repository) == .orderedSame
                    && branch == pr.headRefName
            }
            if !matches.isEmpty {
                result[pr.id] = matches.sorted(by: AgentSession.displayOrder)
            }
        }
        return result
    }
}
