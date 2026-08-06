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

    public var label: String {
        if total == 0 { return "No checks" }
        if failing > 0 { return "\(failing) failing" }
        if pending > 0 { return "\(pending) pending" }
        return "CI passing"
    }
}

public struct PRSummary: Identifiable, Equatable, Sendable {
    public var id: Int { number }
    public let number: Int
    public let title: String
    public let headRefName: String
    public let url: URL
    public let checklistDone: Int
    public let checklistTotal: Int
    public let checks: CheckSummary

    public init(
        number: Int,
        title: String,
        headRefName: String,
        url: URL,
        checklistDone: Int,
        checklistTotal: Int,
        checks: CheckSummary
    ) {
        self.number = number
        self.title = title
        self.headRefName = headRefName
        self.url = url
        self.checklistDone = checklistDone
        self.checklistTotal = checklistTotal
        self.checks = checks
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
