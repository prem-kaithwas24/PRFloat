import AppKit
import Foundation
import Observation
import PRFloatCore

@MainActor
@Observable
final class PRStatusStore {
    private static let repoPathKey = "repoPath"
    private static let pollInterval: TimeInterval = 60

    var repoPath: String? {
        didSet {
            if let repoPath {
                UserDefaults.standard.set(repoPath, forKey: Self.repoPathKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.repoPathKey)
            }
        }
    }

    var prs: [PRSummary] = []
    var isLoading = false
    var errorMessage: String?
    var lastRefresh: Date?
    var isCollapsed = false

    private let service: GitHubCLIService
    private var timerTask: Task<Void, Never>?
    private var inFlight = false

    var repoShortName: String {
        guard let repoPath else { return "No repo" }
        return URL(fileURLWithPath: repoPath).lastPathComponent
    }

    var attentionCount: Int {
        prs.filter(\.needsAttention).count
    }

    init(service: GitHubCLIService = GitHubCLIService()) {
        self.service = service
        self.repoPath = UserDefaults.standard.string(forKey: Self.repoPathKey)
    }

    func start() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await self?.refresh()
            }
        }
    }

    func stop() {
        timerTask?.cancel()
        timerTask = nil
    }

    func setRepoPath(_ path: String?) {
        repoPath = path
        prs = []
        errorMessage = nil
        lastRefresh = nil
        Task { await refresh() }
    }

    func refresh() async {
        guard let repoPath else {
            errorMessage = nil
            prs = []
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
            let list = try await service.fetchOpenAuthoredPRs(repoPath: repoPath)
            prs = list
            errorMessage = nil
            lastRefresh = Date()
        } catch let error as GitHubCLIError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openPR(_ pr: PRSummary) {
        NSWorkspace.shared.open(pr.url)
    }
}
