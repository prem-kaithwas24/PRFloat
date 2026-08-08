import Foundation

/// What an agent is doing, normalised from Claude Code's registry vocabulary.
public enum AgentStatus: String, Sendable, Equatable, CaseIterable {
    /// Registry `busy` — actively working on a task.
    case working
    /// Registry `idle` — has handed control back to you.
    case done
    /// Registry `waiting` — blocked on you (a permission dialog, a question).
    case blocked
    case unknown

    public init(registryValue: String) {
        switch registryValue.lowercased() {
        case "busy": self = .working
        case "idle": self = .done
        case "waiting": self = .blocked
        default: self = .unknown
        }
    }

    public var label: String {
        switch self {
        case .working: return "Working"
        case .done: return "Done"
        case .blocked: return "Needs you"
        case .unknown: return "Unknown"
        }
    }

    /// Sort weight: what needs the user comes first, finished work last.
    public var priority: Int {
        switch self {
        case .blocked: return 0
        case .working: return 1
        case .done: return 2
        case .unknown: return 3
        }
    }
}

/// One live Claude Code session.
public struct AgentSession: Identifiable, Equatable, Sendable {
    public var id: Int32 { pid }

    public let pid: Int32
    public let sessionID: String
    public let cwd: String
    public let name: String
    public let status: AgentStatus
    /// The registry's own string, kept so an unrecognised value can still be shown.
    public let rawStatus: String
    public let startedAt: Date
    public let statusUpdatedAt: Date
    public let waitingFor: String?
    public let tmux: String?

    /// Filled in by enrichment, not present in the registry file.
    public var repository: String?
    public var branch: String?
    public var task: String?
    /// Set when this session moved from working to done very recently.
    public var justFinished: Bool = false

    public init(
        pid: Int32,
        sessionID: String,
        cwd: String,
        name: String,
        status: AgentStatus,
        rawStatus: String,
        startedAt: Date,
        statusUpdatedAt: Date,
        waitingFor: String? = nil,
        tmux: String? = nil,
        repository: String? = nil,
        branch: String? = nil,
        task: String? = nil,
        justFinished: Bool = false
    ) {
        self.pid = pid
        self.sessionID = sessionID
        self.cwd = cwd
        self.name = name
        self.status = status
        self.rawStatus = rawStatus
        self.startedAt = startedAt
        self.statusUpdatedAt = statusUpdatedAt
        self.waitingFor = waitingFor
        self.tmux = tmux
        self.repository = repository
        self.branch = branch
        self.task = task
        self.justFinished = justFinished
    }

    /// Folder name, used when the directory is not a git repo.
    public var folderName: String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }

    /// `repo · branch` when known, else the bare folder name.
    public var locationLabel: String {
        let repoPart = repository.map { $0.split(separator: "/").last.map(String.init) ?? $0 } ?? folderName
        if let branch, !branch.isEmpty {
            return "\(repoPart) · \(branch)"
        }
        return repoPart
    }

    /// "Working · 2m", "finished 4m ago", "Needs you · dialog open".
    public func statusDetail(now: Date = Date()) -> String {
        let elapsed = Self.elapsedLabel(since: statusUpdatedAt, now: now)
        switch status {
        case .working:
            return "Working · \(elapsed)"
        case .done:
            return justFinished ? "Just finished" : "Finished \(elapsed) ago"
        case .blocked:
            if let waitingFor, !waitingFor.isEmpty {
                return "Needs you · \(waitingFor)"
            }
            return "Needs you"
        case .unknown:
            return rawStatus.isEmpty ? "Unknown" : rawStatus
        }
    }

    static func elapsedLabel(since date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86_400)d"
    }

    /// Ordering for the panel: blocked, working, just finished, then idle by recency.
    public static func displayOrder(_ a: AgentSession, _ b: AgentSession) -> Bool {
        let aRank = a.justFinished && a.status == .done ? 1 : a.status.priority * 2
        let bRank = b.justFinished && b.status == .done ? 1 : b.status.priority * 2
        if aRank != bRank { return aRank < bRank }
        return a.statusUpdatedAt > b.statusUpdatedAt
    }
}
