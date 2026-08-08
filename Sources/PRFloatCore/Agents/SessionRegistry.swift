import Foundation

/// Reads Claude Code's session registry: one small JSON file per running session in
/// `~/.claude/sessions/<pid>.json`.
///
/// The format belongs to another application, so every field beyond pid/cwd/status is
/// optional and a file that fails to parse is skipped rather than failing the whole load.
public struct SessionRegistry: Sendable {
    public static let defaultDirectory = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/sessions", isDirectory: true)

    private let directory: URL
    private let isAlive: @Sendable (Int32) -> Bool

    public init(
        directory: URL = SessionRegistry.defaultDirectory,
        isAlive: @escaping @Sendable (Int32) -> Bool = SessionRegistry.processIsAlive
    ) {
        self.directory = directory
        self.isAlive = isAlive
    }

    /// True while the process exists. `EPERM` still means alive — just not ours to signal.
    public static let processIsAlive: @Sendable (Int32) -> Bool = { pid in
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Every live session, unsorted. Dead PIDs and unreadable files are dropped.
    public func load() -> [AgentSession] {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
        } catch {
            // No sessions directory simply means no agents are running.
            return []
        }

        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { Self.decode(fileAt: $0) }
            .filter { isAlive($0.pid) }
    }

    static func decode(fileAt url: URL) -> AgentSession? {
        guard
            let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data),
            let dict = object as? [String: Any]
        else {
            return nil
        }
        return decode(dict)
    }

    static func decode(_ dict: [String: Any]) -> AgentSession? {
        guard
            let pidValue = dict["pid"] as? Int,
            let cwd = dict["cwd"] as? String,
            !cwd.isEmpty
        else {
            return nil
        }

        let rawStatus = dict["status"] as? String ?? ""
        let sessionID = dict["sessionId"] as? String ?? ""
        let startedAt = millisecondDate(dict["startedAt"]) ?? Date()
        let statusUpdatedAt = millisecondDate(dict["statusUpdatedAt"])
            ?? millisecondDate(dict["updatedAt"])
            ?? startedAt

        let waitingFor = (dict["waitingFor"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let name = (dict["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? URL(fileURLWithPath: cwd).lastPathComponent

        return AgentSession(
            pid: Int32(pidValue),
            sessionID: sessionID,
            cwd: cwd,
            name: name,
            status: AgentStatus(registryValue: rawStatus),
            rawStatus: rawStatus,
            startedAt: startedAt,
            statusUpdatedAt: statusUpdatedAt,
            waitingFor: waitingFor,
            tmux: dict["tmux"] as? String
        )
    }

    /// Registry timestamps are milliseconds since the epoch.
    static func millisecondDate(_ value: Any?) -> Date? {
        guard let millis = value as? Double, millis > 0 else {
            if let intMillis = value as? Int, intMillis > 0 {
                return Date(timeIntervalSince1970: Double(intMillis) / 1000)
            }
            return nil
        }
        return Date(timeIntervalSince1970: millis / 1000)
    }
}
