import SwiftUI
import PRFloatCore
import AppKit

/// Top-level sections of the panel.
enum PanelTab: String, CaseIterable, Identifiable {
    case overview
    case orgMetric

    var id: String { rawValue }

    var label: String {
        switch self {
        case .overview: return "Overview"
        case .orgMetric: return "Org metric"
        }
    }
}

struct ContentView: View {
    @Bindable var store: PRStatusStore
    @Bindable var agentStore: AgentStore
    @Bindable var orgStore: OrgMetricsStore
    @Bindable var settings: AppSettings
    let onOpenSettings: () -> Void

    @State private var clientID = ClientConfiguration.clientID()
    @State private var tab: PanelTab = .overview

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.isCollapsed {
                collapsedStrip
            } else {
                content
            }
        }
        .frame(minWidth: 320, idealWidth: 360, minHeight: store.isCollapsed ? 40 : 240)
        .background(.regularMaterial)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Theme.Space.sm) {
            if let account = store.session.account {
                avatar(account)
                Text(account.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            } else {
                Image(systemName: "checklist")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("PR Float")
                    .font(.subheadline.weight(.semibold))
            }

            Spacer(minLength: Theme.Space.xs)

            if store.isLoading {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            }

            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Refresh")
            .disabled(!store.session.isSignedIn || store.isLoading)

            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Settings")

            Button {
                store.isCollapsed.toggle()
            } label: {
                Image(systemName: store.isCollapsed ? "chevron.down" : "chevron.up")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(store.isCollapsed ? "Expand" : "Collapse")
        }
        .font(.caption)
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
    }

    private func avatar(_ account: GitHubAccount) -> some View {
        AsyncImage(url: account.avatarURL) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            Circle().fill(Theme.rowBorder)
        }
        .frame(width: 18, height: 18)
        .clipShape(Circle())
    }

    // MARK: - Collapsed

    private var collapsedStrip: some View {
        HStack(spacing: Theme.Space.sm) {
            Text(collapsedLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
        .contentShape(Rectangle())
        .onTapGesture { store.isCollapsed = false }
    }

    private var collapsedLabel: String {
        guard store.session.isSignedIn else { return "Sign in to GitHub" }

        var parts: [String] = []
        let count = store.prs.count
        if settings.showPullRequests {
            parts.append(count == 0 ? "No PRs" : "\(count) PR\(count == 1 ? "" : "s")")
        }
        if settings.showReviewRequests {
            let reviewCount = store.reviewRequestedPRs.count
            if reviewCount > 0 {
                parts.append("\(reviewCount) to review")
            }
        }
        if settings.showAgents, let agentSummary = agentStore.summaryLine {
            parts.append(agentSummary)
        }
        if parts.isEmpty { return "PR Float" }
        return parts.joined(separator: " · ")
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch store.session.state {
        case .signedIn:
            signedInBody
        default:
            ScrollView {
                SignInView(
                    session: store.session,
                    clientID: clientID,
                    onSaveClientID: { value in
                        ClientConfiguration.setOverride(value)
                        clientID = ClientConfiguration.clientID()
                    }
                )
            }
        }
    }

    private var signedInBody: some View {
        VStack(spacing: 0) {
            tabBar

            switch tab {
            case .overview:
                overviewBody
            case .orgMetric:
                OrgMetricView(store: orgStore)
                Divider()
                orgFooter
            }
        }
    }

    private var tabBar: some View {
        Picker("", selection: $tab) {
            ForEach(PanelTab.allCases) { entry in
                Text(entry.label).tag(entry)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.small)
        .padding(.horizontal, Theme.Space.md)
        .padding(.top, Theme.Space.sm)
        .padding(.bottom, Theme.Space.xs)
        .onChange(of: tab) { _, newValue in
            if newValue == .orgMetric, !orgStore.hasData {
                Task { await orgStore.refresh() }
            }
        }
    }

    private var orgFooter: some View {
        HStack(spacing: Theme.Space.sm) {
            if orgStore.isLoading {
                ProgressView().controlSize(.small).scaleEffect(0.6)
            }
            Spacer(minLength: 0)
            Text(orgStore.errorMessage ?? "")
                .font(.caption2)
                .foregroundStyle(.orange)
                .lineLimit(1)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
    }

    private var overviewBody: some View {
        VStack(spacing: 0) {
            if let error = store.errorMessage {
                banner(error, offline: store.isOffline)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if settings.showAgents {
                        agentsSection
                    }
                    if settings.showPullRequests {
                        pullRequestsSection
                    }
                    if settings.showReviewRequests {
                        reviewRequestsSection
                    }
                }
                .padding(.bottom, Theme.Space.sm)
            }

            Divider()
            footer
        }
    }

    // MARK: - Agents

    @ViewBuilder
    private var agentsSection: some View {
        Section {
            if agentStore.agents.isEmpty {
                EmptyStateView(
                    title: "No Claude Code sessions running",
                    systemImage: "cpu",
                    message: agentStore.isAvailable
                        ? nil
                        : "Waiting for ~/.claude/sessions to appear."
                )
            } else {
                VStack(spacing: Theme.Space.sm) {
                    ForEach(agentStore.agents) { agent in
                        AgentRowView(agent: agent)
                    }
                }
                .padding(.horizontal, Theme.Space.md)
            }
        } header: {
            SectionHeader(title: "Agents", count: agentStore.agents.isEmpty ? nil : agentStore.agents.count)
                .background(.regularMaterial)
        }
    }

    // MARK: - Pull requests

    @ViewBuilder
    private var pullRequestsSection: some View {
        Section {
            if store.isLoading && !store.hasData {
                VStack(spacing: Theme.Space.sm) {
                    SkeletonRow()
                    SkeletonRow()
                    SkeletonRow()
                }
                .padding(.horizontal, Theme.Space.md)
            } else if store.prs.isEmpty {
                EmptyStateView(
                    title: "No open PRs by you",
                    systemImage: "checkmark.circle",
                    message: store.errorMessage == nil ? "Nothing waiting on you right now." : nil
                )
            } else {
                let index = AgentCorrelator.index(agents: agentStore.agents, prs: store.prs)
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    ForEach(store.groups) { group in
                        VStack(alignment: .leading, spacing: Theme.Space.sm) {
                            if store.groups.count > 1 {
                                Text(group.repository)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            ForEach(group.prs) { pr in
                                PRRowView(pr: pr, agents: index[pr.id] ?? []) {
                                    store.openPR(pr)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.Space.md)
            }
        } header: {
            SectionHeader(
                title: "Pull Requests",
                count: store.prs.isEmpty ? nil : store.prs.count
            )
            .background(.regularMaterial)
        }
    }

    // MARK: - Reviews

    @ViewBuilder
    private var reviewRequestsSection: some View {
        Section {
            if store.isLoading && !store.hasReviewData {
                VStack(spacing: Theme.Space.sm) {
                    SkeletonRow()
                    SkeletonRow()
                }
                .padding(.horizontal, Theme.Space.md)
            } else if store.reviewRequestedPRs.isEmpty {
                EmptyStateView(
                    title: "Nothing waiting on your review",
                    systemImage: "checkmark.circle",
                    message: nil
                )
            } else {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    ForEach(store.reviewGroups) { group in
                        VStack(alignment: .leading, spacing: Theme.Space.sm) {
                            if store.reviewGroups.count > 1 {
                                Text(group.repository)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            ForEach(group.prs) { pr in
                                PRRowView(pr: pr, agents: []) {
                                    store.openPR(pr)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.Space.md)
            }
        } header: {
            SectionHeader(
                title: "PRs to Review",
                count: store.reviewRequestedPRs.isEmpty ? nil : store.reviewRequestedPRs.count
            )
            .background(.regularMaterial)
        }
    }

    // MARK: - Chrome

    private var footer: some View {
        HStack(spacing: Theme.Space.sm) {
            if store.attentionCount > 0 {
                Text("\(store.attentionCount) need\(store.attentionCount == 1 ? "s" : "") attention")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
            Text(store.statusLine)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
    }

    private func banner(_ message: String, offline: Bool) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            Image(systemName: offline ? "wifi.slash" : "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(offline ? Color.secondary : Color.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
        .background(offline ? Color.secondary.opacity(0.10) : Color.orange.opacity(0.12))
    }
}
