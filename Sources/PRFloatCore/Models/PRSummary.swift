import Foundation

public enum HealthColor: String, Sendable, Equatable {
    case green
    case yellow
    case red
}

public struct CheckSummary: Equatable, Sendable {
    public let passing: Int
    public let failing: Int
    public let pending: Int

    public init(passing: Int, failing: Int, pending: Int) {
        self.passing = passing
        self.failing = failing
        self.pending = pending
    }

    public static let empty = CheckSummary(passing: 0, failing: 0, pending: 0)

    public var total: Int { passing + failing + pending }

    /// True once every check has reported and none are failing or still running.
    public var allPassing: Bool { total > 0 && failing == 0 && pending == 0 }

    public var label: String {
        if total == 0 { return "No checks" }
        if failing > 0 { return "\(failing) failing" }
        if pending > 0 { return "\(pending) pending" }
        return "CI passing"
    }
}

public struct PRSummary: Identifiable, Equatable, Sendable {
    /// PR numbers repeat across repositories, so identity must include the repo.
    public var id: String { "\(repository)#\(number)" }

    /// `owner/repo`, as GitHub's `nameWithOwner`.
    public let repository: String
    public let number: Int
    public let title: String
    public let headRefName: String
    public let url: URL
    public let isDraft: Bool
    public let checklistDone: Int
    public let checklistTotal: Int
    public let checks: CheckSummary

    public init(
        repository: String,
        number: Int,
        title: String,
        headRefName: String,
        url: URL,
        isDraft: Bool = false,
        checklistDone: Int,
        checklistTotal: Int,
        checks: CheckSummary
    ) {
        self.repository = repository
        self.number = number
        self.title = title
        self.headRefName = headRefName
        self.url = url
        self.isDraft = isDraft
        self.checklistDone = checklistDone
        self.checklistTotal = checklistTotal
        self.checks = checks
    }

    /// Just the repo name, for grouping headers where the owner is redundant.
    public var repositoryShortName: String {
        repository.split(separator: "/").last.map(String.init) ?? repository
    }

    public var checklistLabel: String {
        if checklistTotal == 0 { return "No checklist" }
        return "\(checklistDone)/\(checklistTotal) checklist"
    }

    public var checklistFraction: Double {
        guard checklistTotal > 0 else { return 1 }
        return Double(checklistDone) / Double(checklistTotal)
    }

    public var checklistComplete: Bool {
        checklistTotal == 0 || checklistDone >= checklistTotal
    }

    public var health: HealthColor {
        if checks.failing > 0 { return .red }
        if !checklistComplete || checks.pending > 0 { return .yellow }
        return .green
    }

    public var needsAttention: Bool {
        health != .green
    }
}
