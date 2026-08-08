import SwiftUI
import PRFloatCore

/// The "Org metric" tab: your contribution to the selected organization, alongside what the
/// AI work cost to produce it.
struct OrgMetricView: View {
    @Bindable var store: OrgMetricsStore

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()

            if let error = store.errorMessage, store.metrics == nil {
                EmptyStateView(title: "Couldn't load metrics", systemImage: "chart.bar.xaxis", message: error)
            } else if store.isIndexing {
                indexing
            } else if store.needsOrganizationChoice {
                EmptyStateView(
                    title: "Choose an organization",
                    systemImage: "building.2",
                    message: "Pick one above to see your contribution to its repositories."
                )
            } else if let metrics = store.metrics {
                report(metrics)
            } else if store.isLoading {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Space.xl)
            } else {
                EmptyStateView(
                    title: "No data yet",
                    systemImage: "chart.bar.xaxis",
                    message: "Refresh to load your contribution metrics."
                )
            }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: Theme.Space.sm) {
            Picker("", selection: $store.organization) {
                if store.organization.isEmpty {
                    Text("Select org…").tag("")
                }
                ForEach(store.organizations) { org in
                    Text(org.displayName).tag(org.login)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: 160)

            Spacer(minLength: 0)

            Picker("", selection: $store.period) {
                ForEach(MetricsPeriod.allCases) { period in
                    Text(period.label).tag(period)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(maxWidth: 190)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
    }

    private var indexing: some View {
        VStack(spacing: Theme.Space.sm) {
            ProgressView().controlSize(.small)
            Text("Indexing session history…")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("First run only — results are cached after this.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.xl)
    }

    // MARK: - Report

    private func report(_ metrics: OrgMetrics) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                delivery(metrics)
                aiEffectiveness(metrics)
                if !metrics.ai.costByDay.isEmpty, metrics.period != .today {
                    dailyTrend(metrics)
                }
                if !metrics.contribution.byRepository.isEmpty {
                    repositories(metrics)
                }
                if !metrics.ai.topTools.isEmpty {
                    tools(metrics)
                }
                footnote(metrics)
            }
            .padding(Theme.Space.md)
        }
    }

    private func delivery(_ metrics: OrgMetrics) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            MetricSectionHeader(title: "Delivery", subtitle: metrics.organization)
            MetricGrid {
                MetricTile(value: "\(metrics.contribution.pullRequestsOpened)", label: "PRs opened")
                MetricTile(value: "\(metrics.contribution.merged)", label: "Merged")
                MetricTile(value: "\(metrics.contribution.commits)", label: "Commits")
                MetricTile(value: "\(metrics.contribution.reviews)", label: "Reviews")
                MetricTile(
                    value: metrics.contribution.medianCycleTimeHours.map(Self.duration) ?? "—",
                    label: "Median cycle time",
                    help: "Median time from opening a PR to merging it."
                )
                MetricTile(
                    value: Self.compact(metrics.contribution.linesChanged),
                    label: "Lines changed",
                    help: "Additions plus deletions across merged PRs."
                )
            }
        }
    }

    private func aiEffectiveness(_ metrics: OrgMetrics) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            MetricSectionHeader(title: "AI effectiveness", subtitle: "Claude Code, this machine")
            MetricGrid {
                MetricTile(value: "\(metrics.ai.sessions)", label: "Sessions")
                MetricTile(
                    value: Self.money(metrics.ai.estimatedCost),
                    label: "Est. spend",
                    accent: true,
                    help: "List-price estimate from local token usage. Excludes any negotiated discount."
                )
                MetricTile(
                    value: metrics.costPerMergedPR.map(Self.money) ?? "—",
                    label: "Per merged PR",
                    help: "Estimated AI spend divided by PRs merged in this window."
                )
                MetricTile(
                    value: Self.compact(metrics.ai.usage.total),
                    label: "Tokens",
                    help: "Input, output and cache tokens combined."
                )
                MetricTile(
                    value: Self.percent(metrics.ai.usage.cacheHitRate),
                    label: "Cache hit rate",
                    help: "Share of input tokens served from cache, at a tenth of the input rate."
                )
                MetricTile(
                    value: metrics.contribution.merged > 0
                        ? "\(metrics.aiAssistedMergedPRs)/\(metrics.contribution.merged)"
                        : "—",
                    label: "AI-active PRs",
                    help: """
                    Merged PRs where an agent session ran in the same repository while the PR \
                    was open. Repo-and-date overlap, not proof the agent wrote the code.
                    """
                )
            }

            if !metrics.ai.costByModel.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    ForEach(metrics.ai.costByModel.prefix(4)) { spend in
                        HStack(spacing: Theme.Space.sm) {
                            Text(spend.model)
                                .font(.caption2.monospaced())
                                .lineLimit(1)
                            Spacer(minLength: Theme.Space.xs)
                            Text(Self.compact(spend.usage.total))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(spend.cost.map(Self.money) ?? "unpriced")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(spend.cost == nil ? .orange : .secondary)
                                .frame(width: 56, alignment: .trailing)
                        }
                    }
                }
                .padding(.top, Theme.Space.xs)
            }
        }
    }

    private func dailyTrend(_ metrics: OrgMetrics) -> some View {
        let maxCost = metrics.ai.costByDay.map(\.cost).max() ?? 0

        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            MetricSectionHeader(title: "Daily", subtitle: "spend · merges")
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(metrics.ai.costByDay) { day in
                    VStack(spacing: 2) {
                        // Merge markers sit above the spend bar for the same day.
                        Circle()
                            .fill(day.merged > 0 ? Color.green : Color.clear)
                            .frame(width: 4, height: 4)
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(day.cost > 0 ? Color.accentColor.opacity(0.75) : Theme.rowBorder)
                            .frame(height: barHeight(day.cost, max: maxCost))
                    }
                    .frame(maxWidth: .infinity)
                    .help("\(day.day) · \(Self.money(day.cost))\(day.merged > 0 ? " · \(day.merged) merged" : "")")
                }
            }
            .frame(height: 48)

            HStack {
                Text(metrics.ai.costByDay.first?.day ?? "")
                Spacer()
                Text(metrics.ai.costByDay.last?.day ?? "")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }

    private func barHeight(_ value: Double, max maxValue: Double) -> CGFloat {
        guard maxValue > 0, value > 0 else { return 2 }
        return max(2, CGFloat(value / maxValue) * 40)
    }

    private func repositories(_ metrics: OrgMetrics) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            MetricSectionHeader(title: "By repository", subtitle: nil)
            VStack(spacing: Theme.Space.xs) {
                ForEach(metrics.contribution.byRepository.prefix(6)) { repo in
                    HStack(spacing: Theme.Space.sm) {
                        Text(repo.shortName)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer(minLength: Theme.Space.xs)
                        contributionChip("\(repo.pullRequests)", "PR", .blue)
                        contributionChip("\(repo.commits)", "c", .secondary)
                        contributionChip("\(repo.reviews)", "rev", .purple)
                    }
                }
            }
        }
    }

    private func contributionChip(_ value: String, _ suffix: String, _ color: Color) -> some View {
        Text("\(value)\(suffix)")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(color)
            .frame(width: 42, alignment: .trailing)
    }

    private func tools(_ metrics: OrgMetrics) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            MetricSectionHeader(title: "Tool use", subtitle: nil)
            let total = max(1, metrics.ai.topTools.reduce(0) { $0 + $1.count })
            VStack(spacing: Theme.Space.xs) {
                ForEach(metrics.ai.topTools.prefix(5)) { tool in
                    HStack(spacing: Theme.Space.sm) {
                        Text(tool.name)
                            .font(.caption)
                            .lineLimit(1)
                            .frame(width: 74, alignment: .leading)
                        GeometryReader { proxy in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.accentColor.opacity(0.55))
                                .frame(width: proxy.size.width * CGFloat(tool.count) / CGFloat(total))
                        }
                        .frame(height: 6)
                        Text("\(tool.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func footnote(_ metrics: OrgMetrics) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            if !metrics.ai.unpricedModels.isEmpty {
                Label(
                    "Spend excludes unpriced models: \(metrics.ai.unpricedModels.joined(separator: ", "))",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption2)
                .foregroundStyle(.orange)
            }
            Text("""
            Spend is a list-price estimate from local session data (rates as of \
            \(ModelPricing.ratesAsOf)); it is not a bill. Delivery figures come from the GitHub API.
            """)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, Theme.Space.xs)
    }

    // MARK: - Formatting

    static func money(_ value: Double) -> String {
        if value >= 100 { return String(format: "$%.0f", value) }
        if value >= 1 { return String(format: "$%.2f", value) }
        if value > 0 { return String(format: "$%.3f", value) }
        return "$0"
    }

    static func compact(_ value: Int) -> String {
        switch value {
        case 1_000_000...: return String(format: "%.1fM", Double(value) / 1_000_000)
        case 1_000...: return String(format: "%.1fk", Double(value) / 1_000)
        default: return "\(value)"
        }
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }

    static func duration(_ hours: Double) -> String {
        if hours < 1 { return String(format: "%.0fm", hours * 60) }
        if hours < 48 { return String(format: "%.1fh", hours) }
        return String(format: "%.1fd", hours / 24)
    }
}

// MARK: - Building blocks

private struct MetricSectionHeader: View {
    let title: String
    let subtitle: String?

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct MetricGrid<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: Theme.Space.sm),
                      GridItem(.flexible(), spacing: Theme.Space.sm),
                      GridItem(.flexible(), spacing: Theme.Space.sm)],
            spacing: Theme.Space.sm
        ) {
            content
        }
    }
}

private struct MetricTile: View {
    let value: String
    let label: String
    var accent: Bool = false
    var help: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(.body, design: .rounded).weight(.semibold).monospacedDigit())
                .foregroundStyle(accent ? Color.accentColor : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.sm)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.row).fill(Theme.rowBackground))
        .help(help ?? "")
    }
}
