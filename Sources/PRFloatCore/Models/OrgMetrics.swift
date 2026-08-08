import Foundation

public enum MetricsPeriod: String, CaseIterable, Sendable, Identifiable {
    case today
    case week
    case month

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .today: return "Today"
        case .week: return "7 days"
        case .month: return "30 days"
        }
    }

    public var days: Int {
        switch self {
        case .today: return 1
        case .week: return 7
        case .month: return 30
        }
    }

    /// Start of the window, aligned to local midnight so "today" means the user's today.
    public func start(from now: Date = Date(), calendar: Calendar = .current) -> Date {
        let midnight = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -(days - 1), to: midnight) ?? midnight
    }
}

public struct GitHubOrganization: Sendable, Equatable, Identifiable {
    public let login: String
    public let name: String?

    public var id: String { login }
    public var displayName: String { name?.isEmpty == false ? name! : login }

    public init(login: String, name: String? = nil) {
        self.login = login
        self.name = name
    }
}

public struct MergedPullRequest: Sendable, Equatable, Identifiable {
    public let repository: String
    public let number: Int
    public let title: String
    public let url: URL
    public let headRefName: String
    public let createdAt: Date
    public let mergedAt: Date
    public let additions: Int
    public let deletions: Int
    public let changedFiles: Int

    public var id: String { "\(repository)#\(number)" }

    /// Hours from opening the PR to merge — the flow metric Span reports as cycle time.
    public var cycleTimeHours: Double {
        max(0, mergedAt.timeIntervalSince(createdAt)) / 3600
    }

    public init(
        repository: String, number: Int, title: String, url: URL, headRefName: String,
        createdAt: Date, mergedAt: Date, additions: Int, deletions: Int, changedFiles: Int
    ) {
        self.repository = repository
        self.number = number
        self.title = title
        self.url = url
        self.headRefName = headRefName
        self.createdAt = createdAt
        self.mergedAt = mergedAt
        self.additions = additions
        self.deletions = deletions
        self.changedFiles = changedFiles
    }
}

/// Per-repository contribution counts inside the selected organization.
public struct RepoContribution: Sendable, Equatable, Identifiable {
    public let repository: String
    public var commits: Int
    public var pullRequests: Int
    public var reviews: Int

    public var id: String { repository }
    public var total: Int { commits + pullRequests + reviews }

    public var shortName: String {
        repository.split(separator: "/").last.map(String.init) ?? repository
    }

    public init(repository: String, commits: Int = 0, pullRequests: Int = 0, reviews: Int = 0) {
        self.repository = repository
        self.commits = commits
        self.pullRequests = pullRequests
        self.reviews = reviews
    }
}

/// What GitHub contributed to the picture, scoped to one organization and period.
public struct ContributionReport: Sendable, Equatable {
    public var commits: Int
    public var pullRequestsOpened: Int
    public var reviews: Int
    public var byRepository: [RepoContribution]
    public var mergedPullRequests: [MergedPullRequest]

    public init(
        commits: Int = 0,
        pullRequestsOpened: Int = 0,
        reviews: Int = 0,
        byRepository: [RepoContribution] = [],
        mergedPullRequests: [MergedPullRequest] = []
    ) {
        self.commits = commits
        self.pullRequestsOpened = pullRequestsOpened
        self.reviews = reviews
        self.byRepository = byRepository
        self.mergedPullRequests = mergedPullRequests
    }

    public var totalContributions: Int { commits + pullRequestsOpened + reviews }
    public var merged: Int { mergedPullRequests.count }
    public var linesChanged: Int {
        mergedPullRequests.reduce(0) { $0 + $1.additions + $1.deletions }
    }

    /// Median rather than mean: a single long-lived PR shouldn't define the number.
    public var medianCycleTimeHours: Double? {
        let values = mergedPullRequests.map(\.cycleTimeHours).sorted()
        guard !values.isEmpty else { return nil }
        let middle = values.count / 2
        if values.count.isMultiple(of: 2) {
            return (values[middle - 1] + values[middle]) / 2
        }
        return values[middle]
    }
}

/// Local AI activity for the same organization and period.
public struct AIActivityReport: Sendable, Equatable {
    public var sessions: Int
    public var usage: TokenUsage
    public var estimatedCost: Double
    /// Models seen with no price in the table — cost is a floor when this is non-empty.
    public var unpricedModels: [String]
    public var costByModel: [ModelSpend]
    public var topTools: [ToolCount]
    public var costByDay: [DaySpend]

    public init(
        sessions: Int = 0,
        usage: TokenUsage = .zero,
        estimatedCost: Double = 0,
        unpricedModels: [String] = [],
        costByModel: [ModelSpend] = [],
        topTools: [ToolCount] = [],
        costByDay: [DaySpend] = []
    ) {
        self.sessions = sessions
        self.usage = usage
        self.estimatedCost = estimatedCost
        self.unpricedModels = unpricedModels
        self.costByModel = costByModel
        self.topTools = topTools
        self.costByDay = costByDay
    }
}

public struct ModelSpend: Sendable, Equatable, Identifiable {
    public let model: String
    public let usage: TokenUsage
    public let cost: Double?

    public var id: String { model }

    public init(model: String, usage: TokenUsage, cost: Double?) {
        self.model = model
        self.usage = usage
        self.cost = cost
    }
}

public struct ToolCount: Sendable, Equatable, Identifiable {
    public let name: String
    public let count: Int
    public var id: String { name }

    public init(name: String, count: Int) {
        self.name = name
        self.count = count
    }
}

public struct DaySpend: Sendable, Equatable, Identifiable {
    public let day: String
    public let cost: Double
    public let merged: Int
    public var id: String { day }

    public init(day: String, cost: Double, merged: Int) {
        self.day = day
        self.cost = cost
        self.merged = merged
    }
}

/// The complete Org metric view model.
public struct OrgMetrics: Sendable, Equatable {
    public var organization: String
    public var period: MetricsPeriod
    public var contribution: ContributionReport
    public var ai: AIActivityReport
    /// Merged PRs whose branch matched a local agent session — AI-attributed delivery.
    public var aiAssistedMergedPRs: Int

    public init(
        organization: String,
        period: MetricsPeriod,
        contribution: ContributionReport = ContributionReport(),
        ai: AIActivityReport = AIActivityReport(),
        aiAssistedMergedPRs: Int = 0
    ) {
        self.organization = organization
        self.period = period
        self.contribution = contribution
        self.ai = ai
        self.aiAssistedMergedPRs = aiAssistedMergedPRs
    }

    /// Estimated AI spend per merged PR — the closest honest analogue to Span's ROI framing.
    public var costPerMergedPR: Double? {
        guard contribution.merged > 0, ai.estimatedCost > 0 else { return nil }
        return ai.estimatedCost / Double(contribution.merged)
    }

    public var aiAssistedShare: Double {
        guard contribution.merged > 0 else { return 0 }
        return Double(aiAssistedMergedPRs) / Double(contribution.merged)
    }
}
