import AppKit
import Foundation
import Observation
import PRFloatCore

/// Open PRs authored by the signed-in user, and open PRs where they're requested as a
/// reviewer, across every repo they can see.
@MainActor
@Observable
final class PRStatusStore {
    /// PRs for one repository, so the panel can show grouped headers.
    struct Group: Identifiable {
        let repository: String
        let prs: [PRSummary]
        var id: String { repository }
    }

    private(set) var prs: [PRSummary] = []
    private(set) var reviewRequestedPRs: [PRSummary] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var isOffline = false
    private(set) var lastRefresh: Date?
    var isCollapsed = false

    let session: GitHubSession
    private let settings: AppSettings
    private var timerTask: Task<Void, Never>?
    private var inFlight = false
    private var consecutiveFailures = 0

    init(session: GitHubSession, settings: AppSettings) {
        self.session = session
        self.settings = settings
    }

    // MARK: - Derived state

    var groups: [Group] { grouped(prs) }
    var reviewGroups: [Group] { grouped(reviewRequestedPRs) }

    private func grouped(_ list: [PRSummary]) -> [Group] {
        Dictionary(grouping: list, by: \.repository)
            .map { Group(repository: $0.key, prs: $0.value.sorted { $0.number > $1.number }) }
            .sorted { $0.repository.localizedCaseInsensitiveCompare($1.repository) == .orderedAscending }
    }

    var attentionCount: Int {
        prs.filter(\.needsAttention).count
    }

    /// True once we have shown authored PRs, so a failed refresh can keep the old list.
    var hasData: Bool { !prs.isEmpty }

    /// True once we have shown review-requested PRs, so a failed refresh can keep the old list.
    var hasReviewData: Bool { !reviewRequestedPRs.isEmpty }

    // MARK: - Lifecycle

    func start() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            await self?.restoreAndRefresh()
            while !Task.isCancelled {
                guard let interval = self?.currentInterval(), interval > 0 else {
                    try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
                    continue
                }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await self?.refresh()
            }
        }
    }

    func stop() {
        timerTask?.cancel()
        timerTask = nil
    }

    private func currentInterval() -> TimeInterval {
        TimeInterval(settings.pollInterval.rawValue)
    }

    private func restoreAndRefresh() async {
        await session.restore()
        await refresh()
    }

    // MARK: - Refresh

    func refresh() async {
        guard let client = session.apiClient else {
            prs = []
            reviewRequestedPRs = []
            errorMessage = nil
            return
        }
        guard !inFlight else { return }
        inFlight = true
        isLoading = true
        defer {
            inFlight = false
            isLoading = false
        }

        do {
            async let authored = PullRequestQuery.fetch(using: client)
            async let reviewRequested = PullRequestQuery.fetch(
                using: client,
                query: PullRequestQuery.reviewRequestedSearchQuery
            )
            let (list, reviewList) = try await (authored, reviewRequested)
            prs = list
            reviewRequestedPRs = reviewList
            errorMessage = nil
            isOffline = false
            consecutiveFailures = 0
            lastRefresh = Date()
        } catch GitHubAPIError.unauthorized {
            // Expiry is not a data problem — hand it to the session so the UI explains it.
            session.markExpired()
            prs = []
            reviewRequestedPRs = []
            errorMessage = GitHubAPIError.unauthorized.localizedDescription
        } catch let error as GitHubAPIError {
            consecutiveFailures += 1
            isOffline = (error == .offline)
            // Keep whatever we last showed; a failed poll must not blank the panel.
            errorMessage = error.localizedDescription
        } catch {
            consecutiveFailures += 1
            errorMessage = error.localizedDescription
        }
    }

    func openPR(_ pr: PRSummary) {
        NSWorkspace.shared.open(pr.url)
    }

    // MARK: - Presentation helpers

    var statusLine: String {
        if isOffline, let last = lastRefresh {
            return "Offline · last updated \(Self.timeFormatter.string(from: last))"
        }
        if isOffline { return "Offline" }
        guard let last = lastRefresh else { return "Not refreshed yet" }
        let seconds = Int(Date().timeIntervalSince(last))
        if seconds < 5 { return "Updated just now" }
        if seconds < 60 { return "Updated \(seconds)s ago" }
        if seconds < 3600 { return "Updated \(seconds / 60)m ago" }
        return "Updated \(Self.timeFormatter.string(from: last))"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}
