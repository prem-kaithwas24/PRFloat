import Foundation
import Testing
@testable import PRFloatCore

private func date(_ iso: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: iso)!
}

@Suite("Model pricing")
struct ModelPricingTests {
    @Test("Model ids normalise across date suffixes and context markers", arguments: [
        ("claude-opus-5", "claude-opus-5"),
        ("claude-opus-5[1m]", "claude-opus-5"),
        ("claude-haiku-4-5-20251001", "claude-haiku-4-5"),
        ("CLAUDE-SONNET-5", "claude-sonnet-5")
    ])
    func normalisation(raw: String, expected: String) {
        #expect(ModelPricing.normalize(raw) == expected)
    }

    @Test("Opus 5 bills at $5 in / $25 out per million")
    func opusRate() throws {
        let rate = try #require(ModelPricing.rate(for: "claude-opus-5"))
        #expect(rate.input == 5)
        #expect(rate.output == 25)
    }

    @Test("Sonnet 5 uses introductory pricing until it lapses")
    func sonnetIntroPricing() throws {
        let during = try #require(ModelPricing.rate(for: "claude-sonnet-5", on: date("2026-08-08T00:00:00Z")))
        #expect(during.input == 2)
        #expect(during.output == 10)

        let after = try #require(ModelPricing.rate(for: "claude-sonnet-5", on: date("2026-09-01T00:00:00Z")))
        #expect(after.input == 3)
        #expect(after.output == 15)
    }

    @Test("Cost applies the cache multipliers, not the flat input rate")
    func cacheMultipliers() throws {
        // 1M of each class on Opus 5: $5 in, $25 out, $0.50 cache read,
        // $6.25 5-minute write, $10 1-hour write.
        let usage = TokenUsage(
            input: 1_000_000,
            output: 1_000_000,
            cacheRead: 1_000_000,
            cacheWrite5m: 1_000_000,
            cacheWrite1h: 1_000_000
        )
        let cost = try #require(ModelPricing.cost(of: usage, model: "claude-opus-5"))
        #expect(abs(cost - 46.75) < 0.001)
    }

    @Test("Cache reads cost a tenth of full input")
    func cacheReadIsCheap() throws {
        let cached = TokenUsage(cacheRead: 1_000_000)
        let fresh = TokenUsage(input: 1_000_000)
        let cachedCost = try #require(ModelPricing.cost(of: cached, model: "claude-opus-5"))
        let freshCost = try #require(ModelPricing.cost(of: fresh, model: "claude-opus-5"))
        #expect(abs(cachedCost * 10 - freshCost) < 0.001)
    }

    @Test("An unknown model yields no cost rather than a wrong one")
    func unknownModel() {
        #expect(ModelPricing.cost(of: TokenUsage(input: 1000), model: "some-future-model") == nil)
        #expect(!ModelPricing.isPriced("some-future-model"))
    }

    @Test("Token usage sums and reports cache hit rate")
    func usageArithmetic() {
        var total = TokenUsage(input: 10, output: 5)
        total += TokenUsage(input: 90, cacheRead: 900)

        #expect(total.input == 100)
        #expect(total.output == 5)
        #expect(total.totalInput == 1000)
        #expect(abs(total.cacheHitRate - 0.9) < 0.0001)
    }
}

@Suite("Usage parsing")
struct UsageAnalyzerTests {
    @Test("Reads the split cache-creation breakdown")
    func cacheCreationBreakdown() {
        let usage = UsageAnalyzer.tokenUsage(from: [
            "input_tokens": 2,
            "output_tokens": 401,
            "cache_read_input_tokens": 509_971,
            "cache_creation_input_tokens": 264,
            "cache_creation": [
                "ephemeral_5m_input_tokens": 64,
                "ephemeral_1h_input_tokens": 200
            ]
        ])

        #expect(usage.input == 2)
        #expect(usage.output == 401)
        #expect(usage.cacheRead == 509_971)
        #expect(usage.cacheWrite5m == 64)
        #expect(usage.cacheWrite1h == 200)
    }

    /// The flat total and the breakdown describe the same tokens — counting both would
    /// inflate spend on every cached request.
    @Test("Does not double-count the flat cache_creation total alongside the breakdown")
    func noDoubleCounting() {
        let usage = UsageAnalyzer.tokenUsage(from: [
            "cache_creation_input_tokens": 1000,
            "cache_creation": ["ephemeral_5m_input_tokens": 1000, "ephemeral_1h_input_tokens": 0]
        ])
        #expect(usage.cacheWrite5m + usage.cacheWrite1h == 1000)
    }

    @Test("Falls back to the flat total when no breakdown is present")
    func flatFallback() {
        let usage = UsageAnalyzer.tokenUsage(from: ["cache_creation_input_tokens": 512])
        #expect(usage.cacheWrite5m == 512)
    }

    @Test("Parses a transcript into per-day, per-model usage")
    func parsesTranscript() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prfloat-usage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("sess.jsonl")
        let lines = [
            #"{"type":"assistant","cwd":"/Users/test/proj","timestamp":"2026-08-08T10:00:00.000Z","message":{"model":"claude-opus-5","usage":{"input_tokens":100,"output_tokens":50},"content":[{"type":"tool_use","name":"Bash"}]}}"#,
            #"{"type":"assistant","cwd":"/Users/test/proj","timestamp":"2026-08-08T11:00:00.000Z","message":{"model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":5},"content":[{"type":"tool_use","name":"Read"}]}}"#,
            #"{"type":"assistant","timestamp":"2026-08-08T12:00:00.000Z","message":{"model":"<synthetic>","usage":{"input_tokens":999,"output_tokens":999}}}"#,
            #"{"type":"user","message":{"content":"hello"}}"#,
            "{ not json"
        ]
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)

        let summary = UsageAnalyzer.parse(file: file)

        #expect(summary.cwd == "/Users/test/proj")
        let day = try #require(summary.byDayModel.keys.first)
        let usage = try #require(summary.byDayModel[day]?["claude-opus-5"])
        #expect(usage.input == 110, "synthetic messages must not be billed")
        #expect(usage.output == 55)
        #expect(summary.messagesByDay[day] == 3)
        #expect(summary.toolCountsByDay[day]?["Bash"] == 1)
        #expect(summary.toolCountsByDay[day]?["Read"] == 1)
    }
}

@Suite("Org metrics aggregation")
struct OrgMetricsBuilderTests {
    private func transcript(
        cwd: String,
        day: String,
        model: String = "claude-opus-5",
        usage: TokenUsage = TokenUsage(input: 1_000_000)
    ) -> TranscriptUsage {
        TranscriptUsage(
            sessionID: UUID().uuidString,
            cwd: cwd,
            byDayModel: [day: [model: usage]],
            messagesByDay: [day: 1],
            toolCountsByDay: [day: ["Bash": 3]],
            activeDays: [day]
        )
    }

    private func mergedPR(
        repository: String,
        number: Int = 1,
        created: String,
        merged: String
    ) -> MergedPullRequest {
        MergedPullRequest(
            repository: repository, number: number, title: "t",
            url: URL(string: "https://example.com")!, headRefName: "feature/x",
            createdAt: date(created), mergedAt: date(merged),
            additions: 100, deletions: 20, changedFiles: 3
        )
    }

    @Test("Only repositories inside the organization are counted")
    func filtersByOrganization() {
        let today = UsageAnalyzer.dayKey(for: Date())
        let metrics = OrgMetricsBuilder.build(
            organization: "acme",
            period: .today,
            contribution: ContributionReport(),
            transcripts: [
                transcript(cwd: "/work/inside", day: today),
                transcript(cwd: "/work/outside", day: today)
            ],
            repositoryForDirectory: { cwd in
                cwd.hasSuffix("inside") ? "acme/widgets" : "other/thing"
            }
        )

        #expect(metrics.ai.sessions == 1)
        #expect(metrics.ai.usage.input == 1_000_000)
    }

    @Test("Usage outside the period window is excluded")
    func filtersByPeriod() {
        let metrics = OrgMetricsBuilder.build(
            organization: "acme",
            period: .today,
            contribution: ContributionReport(),
            transcripts: [transcript(cwd: "/work", day: "2020-01-01")],
            repositoryForDirectory: { _ in "acme/widgets" }
        )

        #expect(metrics.ai.sessions == 0)
        #expect(metrics.ai.usage.total == 0)
        #expect(metrics.ai.estimatedCost == 0)
    }

    @Test("Spend is priced per model and summed")
    func spend() {
        let today = UsageAnalyzer.dayKey(for: Date())
        let metrics = OrgMetricsBuilder.build(
            organization: "acme",
            period: .today,
            contribution: ContributionReport(),
            transcripts: [transcript(cwd: "/work", day: today, usage: TokenUsage(input: 1_000_000))],
            repositoryForDirectory: { _ in "acme/widgets" }
        )
        #expect(abs(metrics.ai.estimatedCost - 5.0) < 0.001)
    }

    @Test("An unpriced model is reported so the total reads as a floor")
    func unpricedModelSurfaces() {
        let today = UsageAnalyzer.dayKey(for: Date())
        let metrics = OrgMetricsBuilder.build(
            organization: "acme",
            period: .today,
            contribution: ContributionReport(),
            transcripts: [transcript(cwd: "/work", day: today, model: "claude-future-9")],
            repositoryForDirectory: { _ in "acme/widgets" }
        )
        #expect(metrics.ai.unpricedModels == ["claude-future-9"])
        #expect(metrics.ai.estimatedCost == 0)
    }

    @Test("A PR with agent activity in its repo while open counts as AI-active")
    func aiAttribution() {
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: Date())!
        let activity: Set<String> = ["acme/widgets|\(UsageAnalyzer.dayKey(for: yesterday))"]

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let pr = MergedPullRequest(
            repository: "acme/widgets", number: 1, title: "t",
            url: URL(string: "https://example.com")!, headRefName: "x",
            createdAt: calendar.date(byAdding: .day, value: -2, to: Date())!,
            mergedAt: Date(),
            additions: 1, deletions: 1, changedFiles: 1
        )

        #expect(OrgMetricsBuilder.countAIAssisted([pr], activity: activity) == 1)
    }

    @Test("A PR in a different repo is not attributed to the agent")
    func aiAttributionRespectsRepository() {
        let activity: Set<String> = ["acme/other|\(UsageAnalyzer.dayKey(for: Date()))"]
        let pr = mergedPR(repository: "acme/widgets", created: "2026-08-08T09:00:00Z", merged: "2026-08-08T17:00:00Z")
        #expect(OrgMetricsBuilder.countAIAssisted([pr], activity: activity) == 0)
    }

    @Test("Median cycle time ignores the mean-skewing outlier")
    func medianCycleTime() throws {
        let report = ContributionReport(mergedPullRequests: [
            mergedPR(repository: "acme/w", number: 1, created: "2026-08-01T00:00:00Z", merged: "2026-08-01T01:00:00Z"),
            mergedPR(repository: "acme/w", number: 2, created: "2026-08-02T00:00:00Z", merged: "2026-08-02T03:00:00Z"),
            mergedPR(repository: "acme/w", number: 3, created: "2026-08-03T00:00:00Z", merged: "2026-08-13T00:00:00Z")
        ])
        let median = try #require(report.medianCycleTimeHours)
        #expect(abs(median - 3) < 0.001)
    }

    @Test("No merged PRs means no median rather than zero")
    func medianWithoutData() {
        #expect(ContributionReport().medianCycleTimeHours == nil)
    }

    @Test("Cost per merged PR divides spend by delivery")
    func costPerMergedPR() throws {
        var metrics = OrgMetrics(organization: "acme", period: .week)
        metrics.contribution = ContributionReport(mergedPullRequests: [
            mergedPR(repository: "acme/w", number: 1, created: "2026-08-01T00:00:00Z", merged: "2026-08-01T01:00:00Z"),
            mergedPR(repository: "acme/w", number: 2, created: "2026-08-02T00:00:00Z", merged: "2026-08-02T01:00:00Z")
        ])
        metrics.ai = AIActivityReport(estimatedCost: 10)

        let perPR = try #require(metrics.costPerMergedPR)
        #expect(abs(perPR - 5) < 0.001)
    }

    @Test("The daily series covers every day in the window, oldest first")
    func dailySeries() {
        let metrics = OrgMetricsBuilder.build(
            organization: "acme",
            period: .week,
            contribution: ContributionReport(),
            transcripts: [],
            repositoryForDirectory: { _ in "acme/widgets" }
        )
        #expect(metrics.ai.costByDay.count == 7)
        #expect(metrics.ai.costByDay.first!.day < metrics.ai.costByDay.last!.day)
        #expect(metrics.ai.costByDay.last!.day == UsageAnalyzer.dayKey(for: Date()))
    }

    @Test("An empty organization means every repository counts")
    func noOrganizationFilter() {
        let today = UsageAnalyzer.dayKey(for: Date())
        let metrics = OrgMetricsBuilder.build(
            organization: "",
            period: .today,
            contribution: ContributionReport(),
            transcripts: [
                transcript(cwd: "/a", day: today),
                transcript(cwd: "/b", day: today)
            ],
            repositoryForDirectory: { cwd in cwd == "/a" ? "acme/one" : "other/two" }
        )
        #expect(metrics.ai.sessions == 2)
    }
}
