import Foundation
import Observation
import PRFloatCore

/// Live Claude Code sessions, enriched with the repo they sit on and what they were asked.
///
/// The registry directory is watched so status changes appear near-instantly, with a slow
/// poll behind it in case an event is missed or the directory is recreated.
@MainActor
@Observable
final class AgentStore {
    /// How long a session that just went idle keeps its "just finished" treatment.
    static let justFinishedWindow: TimeInterval = 5 * 60
    private static let safetyPollInterval: TimeInterval = 5

    private(set) var agents: [AgentSession] = []
    private(set) var isAvailable = true

    private let registry: SessionRegistry
    private let transcripts: TranscriptReader
    private let resolver: RepoResolver
    private let directory: URL

    private var previousStatus: [Int32: AgentStatus] = [:]
    private var finishedAt: [Int32: Date] = [:]
    private var repoCache: [String: GitRepoInfo] = [:]

    private var watcher: DispatchSourceFileSystemObject?
    private var watchedDescriptor: Int32 = -1
    private var pollTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?

    init(
        directory: URL = SessionRegistry.defaultDirectory,
        registry: SessionRegistry = SessionRegistry(),
        transcripts: TranscriptReader = TranscriptReader(),
        resolver: RepoResolver = RepoResolver()
    ) {
        self.directory = directory
        self.registry = registry
        self.transcripts = transcripts
        self.resolver = resolver
    }

    // MARK: - Derived state

    var workingCount: Int { agents.filter { $0.status == .working }.count }
    var blockedCount: Int { agents.filter { $0.status == .blocked }.count }
    var justFinishedCount: Int { agents.filter(\.justFinished).count }

    /// One line for the collapsed strip; what is blocked outranks what is running.
    var summaryLine: String? {
        if blockedCount > 0 {
            return "\(blockedCount) agent\(blockedCount == 1 ? "" : "s") need\(blockedCount == 1 ? "s" : "") you"
        }
        if workingCount > 0 {
            return "\(workingCount) agent\(workingCount == 1 ? "" : "s") working"
        }
        if !agents.isEmpty {
            return "\(agents.count) agent\(agents.count == 1 ? "" : "s") idle"
        }
        return nil
    }

    // MARK: - Lifecycle

    func start() {
        reload()
        startWatching()
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.safetyPollInterval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                self?.reload()
                // The directory may have been recreated since the watch was installed.
                self?.restartWatchingIfNeeded()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        reloadTask?.cancel()
        reloadTask = nil
        stopWatching()
    }

    // MARK: - Loading

    func reload() {
        let now = Date()
        var loaded = registry.load()

        for index in loaded.indices {
            let session = loaded[index]

            // Transition tracking: working → done is the moment worth surfacing.
            if let previous = previousStatus[session.pid],
               previous == .working,
               session.status == .done,
               finishedAt[session.pid] == nil {
                finishedAt[session.pid] = now
            }
            if session.status != .done {
                finishedAt[session.pid] = nil
            }
            previousStatus[session.pid] = session.status

            if let finished = finishedAt[session.pid] {
                loaded[index].justFinished = now.timeIntervalSince(finished) < Self.justFinishedWindow
            }

            if let info = repoInfo(for: session.cwd) {
                loaded[index].repository = info.nameWithOwner
                loaded[index].branch = info.branch
            }
            loaded[index].task = transcripts.lastPrompt(sessionID: session.sessionID)
        }

        // Forget bookkeeping for sessions that have exited.
        let live = Set(loaded.map(\.pid))
        previousStatus = previousStatus.filter { live.contains($0.key) }
        finishedAt = finishedAt.filter { live.contains($0.key) }

        agents = loaded.sorted(by: AgentSession.displayOrder)
        isAvailable = FileManager.default.fileExists(atPath: directory.path)
    }

    /// Git metadata changes rarely; cache it per directory and refresh when HEAD moves.
    private func repoInfo(for cwd: String) -> GitRepoInfo? {
        let headPath = cwd + "/.git/HEAD"
        let modified = (try? FileManager.default.attributesOfItem(atPath: headPath))?[.modificationDate] as? Date
        let key = "\(cwd)|\(modified?.timeIntervalSince1970 ?? 0)"

        if let cached = repoCache[key] { return cached }
        guard let resolved = resolver.resolve(cwd: cwd) else { return nil }
        repoCache[key] = resolved
        // Bound the cache; sessions come and go but directories are few.
        if repoCache.count > 64 { repoCache.removeAll() }
        return resolved
    }

    // MARK: - Watching

    private func startWatching() {
        stopWatching()
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.scheduleReload()
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()

        watcher = source
        watchedDescriptor = descriptor
    }

    private func restartWatchingIfNeeded() {
        guard watcher == nil, FileManager.default.fileExists(atPath: directory.path) else { return }
        startWatching()
    }

    private func stopWatching() {
        watcher?.cancel()
        watcher = nil
        watchedDescriptor = -1
    }

    /// Writes arrive in bursts as several sessions update; coalesce them.
    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }
}
