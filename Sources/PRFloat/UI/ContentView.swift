import SwiftUI
import PRFloatCore
import AppKit

struct ContentView: View {
    @Bindable var store: PRStatusStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.isCollapsed {
                collapsedStrip
            } else {
                mainBody
            }
        }
        .frame(minWidth: 280, idealWidth: 320, minHeight: store.isCollapsed ? 36 : 200)
        .background(.ultraThinMaterial)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("PR Float")
                .font(.headline)
            Text("·")
                .foregroundStyle(.secondary)
            Text(store.repoShortName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh")
            .disabled(store.repoPath == nil || store.isLoading)

            Button {
                store.isCollapsed.toggle()
            } label: {
                Image(systemName: store.isCollapsed ? "chevron.up" : "chevron.down")
            }
            .buttonStyle(.plain)
            .help(store.isCollapsed ? "Expand" : "Collapse")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var collapsedStrip: some View {
        HStack {
            Text(collapsedLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .contentShape(Rectangle())
        .onTapGesture { store.isCollapsed = false }
    }

    private var collapsedLabel: String {
        let n = store.prs.count
        let a = store.attentionCount
        if store.repoPath == nil { return "Choose a repo" }
        if n == 0 { return "No open PRs" }
        if a == 0 { return "\(n) PR\(n == 1 ? "" : "s") · all green" }
        return "\(n) PR\(n == 1 ? "" : "s") · \(a) need attention"
    }

    @ViewBuilder
    private var mainBody: some View {
        if let error = store.errorMessage {
            errorBanner(error)
        }

        if store.repoPath == nil {
            EmptyStateView(
                title: "Choose a git repo to watch",
                systemImage: "folder.badge.questionmark",
                actionTitle: "Choose Repo…",
                action: chooseRepo
            )
        } else if store.isLoading && store.prs.isEmpty {
            ProgressView("Loading PRs…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
        } else if store.prs.isEmpty && store.errorMessage == nil {
            EmptyStateView(
                title: "No open PRs by you in this repo",
                systemImage: "checkmark.circle",
                actionTitle: "Change Repo…",
                action: chooseRepo
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(store.prs) { pr in
                        PRRowView(pr: pr) {
                            store.openPR(pr)
                        }
                    }
                }
                .padding(12)
            }

            footer
        }
    }

    private var footer: some View {
        HStack {
            Button("Change Repo…", action: chooseRepo)
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if store.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            Text(footerRefreshText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var footerRefreshText: String {
        guard let last = store.lastRefresh else { return "Not refreshed yet" }
        let seconds = Int(Date().timeIntervalSince(last))
        if seconds < 5 { return "Updated just now" }
        if seconds < 60 { return "Updated \(seconds)s ago" }
        return "Updated \(seconds / 60)m ago"
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.caption)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.yellow.opacity(0.12))
    }

    private func chooseRepo() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Watch"
        panel.message = "Select a local git repository"
        if panel.runModal() == .OK, let url = panel.url {
            store.setRepoPath(url.path)
        }
    }
}

struct EmptyStateView: View {
    let title: String
    let systemImage: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button(actionTitle, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct PRRowView: View {
    let pr: PRSummary
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle()
                    .fill(healthColor)
                    .frame(width: 8, height: 8)
                Text("#\(pr.number)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(pr.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button("Open ↗", action: onOpen)
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.tint)
            }

            if pr.checklistTotal > 0 {
                ProgressView(value: pr.checklistFraction)
                    .progressViewStyle(.linear)
                    .tint(healthColor)
                Text(pr.checklistLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("No checklist")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack {
                Text(pr.checks.label)
                    .font(.caption2)
                    .foregroundStyle(checksColor)
                Spacer()
                Text(pr.headRefName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private var healthColor: Color {
        switch pr.health {
        case .green: return .green
        case .yellow: return .yellow
        case .red: return .red
        }
    }

    private var checksColor: Color {
        if pr.checks.failing > 0 { return .red }
        if pr.checks.pending > 0 { return .yellow }
        if pr.checks.passing > 0 { return .green }
        return .secondary
    }
}
