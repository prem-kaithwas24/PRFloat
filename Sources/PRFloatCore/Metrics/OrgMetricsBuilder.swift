import Foundation

/// Combines GitHub contribution data with local AI activity into the Org metric view model.
///
/// Pure by design — the store supplies the two inputs and a `cwd → owner/repo` resolver, so
/// every aggregation rule here is testable without touching the network or the filesystem.
public enum OrgMetricsBuilder {
    public static func build(
        organization: String,
        period: MetricsPeriod,
        contribution: ContributionReport,
        transcripts: [TranscriptUsage],
        repositoryForDirectory: (String) -> String?,
        now: Date = Date()
    ) -> OrgMetrics {
        let days = dayKeys(for: period, now: now)
        let daySet = Set(days)

        var usage = TokenUsage.zero
        var usageByModel: [String: TokenUsage] = [:]
        var tools: [String: Int] = [:]
        var sessions = 0
        var costByDay: [String: Double] = [:]
        /// (repo, day) pairs with local agent activity — the AI-attribution index.
        var activity: Set<String> = []

        for transcript in transcripts {
            guard let repository = repositoryForDirectory(transcript.cwd) else { continue }
            guard belongs(repository, to: organization) else { continue }

            var contributedInWindow = false

            for (day, models) in transcript.byDayModel where daySet.contains(day) {
                contributedInWindow = true
                activity.insert("\(repository.lowercased())|\(day)")

                for (model, modelUsage) in models {
                    usage += modelUsage
                    usageByModel[model, default: .zero] += modelUsage
                    if let cost = ModelPricing.cost(of: modelUsage, model: model, on: now) {
                        costByDay[day, default: 0] += cost
                    }
                }
            }

            for (day, counts) in transcript.toolCountsByDay where daySet.contains(day) {
                contributedInWindow = true
                activity.insert("\(repository.lowercased())|\(day)")
                for (name, count) in counts {
                    tools[name, default: 0] += count
                }
            }

            if contributedInWindow { sessions += 1 }
        }

        let costByModel = usageByModel
            .map { ModelSpend(model: $0.key, usage: $0.value, cost: ModelPricing.cost(of: $0.value, model: $0.key, on: now)) }
            .sorted { ($0.cost ?? 0) > ($1.cost ?? 0) }

        let unpriced = usageByModel.keys.filter { !ModelPricing.isPriced($0) }.sorted()
        let totalCost = costByModel.reduce(0) { $0 + ($1.cost ?? 0) }

        let mergedByDay = Dictionary(grouping: contribution.mergedPullRequests) {
            UsageAnalyzer.dayKey(for: $0.mergedAt)
        }

        let ai = AIActivityReport(
            sessions: sessions,
            usage: usage,
            estimatedCost: totalCost,
            unpricedModels: unpriced,
            costByModel: costByModel,
            topTools: tools
                .map { ToolCount(name: $0.key, count: $0.value) }
                .sorted { $0.count > $1.count },
            costByDay: days.map { day in
                DaySpend(day: day, cost: costByDay[day] ?? 0, merged: mergedByDay[day]?.count ?? 0)
            }
        )

        return OrgMetrics(
            organization: organization,
            period: period,
            contribution: contribution,
            ai: ai,
            aiAssistedMergedPRs: countAIAssisted(contribution.mergedPullRequests, activity: activity)
        )
    }

    /// A PR counts as AI-assisted when an agent session ran in that repository on any day the
    /// PR was open.
    ///
    /// This is repo-and-date overlap, not trace-level attribution: it cannot prove the agent
    /// wrote the code, only that it was working in the same repo while the PR was open. The UI
    /// labels the figure accordingly rather than presenting it as provenance.
    static func countAIAssisted(_ prs: [MergedPullRequest], activity: Set<String>) -> Int {
        guard !activity.isEmpty else { return 0 }
        let calendar = Calendar.current

        return prs.filter { pr in
            var day = calendar.startOfDay(for: pr.createdAt)
            let last = calendar.startOfDay(for: pr.mergedAt)
            while day <= last {
                if activity.contains("\(pr.repository.lowercased())|\(UsageAnalyzer.dayKey(for: day))") {
                    return true
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
            return false
        }.count
    }

    static func belongs(_ repository: String, to organization: String) -> Bool {
        guard !organization.isEmpty else { return true }
        let owner = repository.split(separator: "/").first.map(String.init) ?? ""
        return owner.caseInsensitiveCompare(organization) == .orderedSame
    }

    /// Oldest-first day keys covering the period, so charts read left to right.
    public static func dayKeys(for period: MetricsPeriod, now: Date = Date()) -> [String] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        return (0..<period.days).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today).map(UsageAnalyzer.dayKey(for:))
        }
    }
}
