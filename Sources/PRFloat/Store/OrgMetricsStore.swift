import Foundation
import Observation
import PRFloatCore

/// Drives the Org metric tab: GitHub contributions for the selected organization, combined
/// with local Claude Code usage for the same window.
@MainActor
@Observable
final class OrgMetricsStore {
    private enum Key {
        static let organization = "orgMetricsOrganization"
        static let period = "orgMetricsPeriod"
    }

    private(set) var metrics: OrgMetrics?
    private(set) var organizations: [GitHubOrganization] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var lastRefresh: Date?
    /// True while the first transcript scan runs — it parses every session file once.
    private(set) var isIndexing = false

    var organization: String {
        didSet {
            guard organization != oldValue else { return }
            defaults.set(organization, forKey: Key.organization)
            Task { await refresh(force: true) }
        }
    }

    var period: MetricsPeriod {
        didSet {
            guard period != oldValue else { return }
            defaults.set(period.rawValue, forKey: Key.period)
            Task { await refresh(force: true) }
        }
    }

    private let session: GitHubSession
    private let settings: AppSettings
    private let analyzer: UsageAnalyzer
    private let resolver: RepoResolver
    private let defaults: UserDefaults

    private var transcripts: [TranscriptUsage] = []
    private var repositoryCache: [String: String?] = [:]
    private var inFlight = false
    private var timerTask: Task<Void, Never>?

    init(
        session: GitHubSession,
        settings: AppSettings,
        analyzer: UsageAnalyzer = UsageAnalyzer(),
        resolver: RepoResolver = RepoResolver(),
        defaults: UserDefaults = .standard
    ) {
        self.session = session
        self.settings = settings
        self.analyzer = analyzer
        self.resolver = resolver
        self.defaults = defaults
        self.organization = defaults.string(forKey: Key.organization) ?? ""
        self.period = MetricsPeriod(rawValue: defaults.string(forKey: Key.period) ?? "") ?? .week
    }

    var hasData: Bool { metrics != nil }

    /// Shown when no organization is chosen yet.
    var needsOrganizationChoice: Bool {
        organization.isEmpty && !organizations.isEmpty
    }

    // MARK: - Lifecycle

    /// Starts polling while the Org metric tab is visible; an immediate refresh runs first.
    func start() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            await self?.refresh()
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

    /// Stops polling, e.g. when the tab is no longer visible.
    func stop() {
        timerTask?.cancel()
        timerTask = nil
    }

    private func currentInterval() -> TimeInterval {
        TimeInterval(settings.pollInterval.rawValue)
    }

    func refresh(force: Bool = false) async {
        guard let client = session.apiClient else {
            metrics = nil
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

        // Transcript scanning is CPU-bound over multi-MB files — keep it off the main actor.
        if transcripts.isEmpty || force {
            isIndexing = transcripts.isEmpty
            let analyzer = self.analyzer
            transcripts = await Task.detached(priority: .utility) { analyzer.loadAll() }.value
            isIndexing = false
        }

        do {
            let result = try await ContributionQuery.fetch(
                using: client,
                organization: organization,
                period: period
            )
            organizations = result.organizations

            // First run with no stored choice: default to the sole org if there is one.
            if organization.isEmpty, result.organizations.count == 1 {
                organization = result.organizations[0].login
                return
            }

            metrics = OrgMetricsBuilder.build(
                organization: organization,
                period: period,
                contribution: result.report,
                transcripts: transcripts,
                repositoryForDirectory: { [weak self] cwd in self?.repository(for: cwd) ?? nil }
            )
            errorMessage = nil
            lastRefresh = Date()
        } catch GitHubAPIError.unauthorized {
            session.markExpired()
            errorMessage = GitHubAPIError.unauthorized.localizedDescription
        } catch let error as GitHubAPIError {
            // Keep the last good numbers rather than blanking the tab.
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Git metadata per working directory, cached — the resolver reads files on every call.
    private func repository(for cwd: String) -> String? {
        if let cached = repositoryCache[cwd] { return cached }
        let resolved = resolver.resolve(cwd: cwd)?.nameWithOwner
        repositoryCache[cwd] = resolved
        return resolved
    }
}
