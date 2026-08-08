import Foundation
import Testing
@testable import PRFloatCore

/// Builds a throwaway sessions directory so tests never touch the real registry.
private struct TempDirectory {
    let url: URL

    init() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prfloat-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func write(_ contents: String, to name: String) throws {
        try contents.write(to: url.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: url)
    }
}

private func sessionJSON(
    pid: Int,
    status: String,
    name: String = "agent-1",
    cwd: String = "/Users/test/project",
    sessionID: String = "sess-1",
    statusUpdatedAt: Int = 1_786_157_154_547,
    extra: String = ""
) -> String {
    """
    {"pid":\(pid),"sessionId":"\(sessionID)","cwd":"\(cwd)",
     "startedAt":1786155797785,"version":"2.1.224","kind":"interactive",
     "entrypoint":"cli","name":"\(name)","status":"\(status)",
     "updatedAt":\(statusUpdatedAt),"statusUpdatedAt":\(statusUpdatedAt)\(extra)}
    """
}

@Suite("Session registry")
struct SessionRegistryTests {
    @Test("Reads live sessions from the registry directory")
    func readsSessions() throws {
        let temp = try TempDirectory()
        defer { temp.cleanUp() }

        try temp.write(sessionJSON(pid: 100, status: "busy", name: "alpha"), to: "100.json")
        try temp.write(sessionJSON(pid: 200, status: "idle", name: "beta"), to: "200.json")

        let registry = SessionRegistry(directory: temp.url, isAlive: { _ in true })
        let sessions = registry.load().sorted { $0.pid < $1.pid }

        #expect(sessions.count == 2)
        #expect(sessions[0].name == "alpha")
        #expect(sessions[0].status == .working)
        #expect(sessions[1].status == .done)
    }

    @Test("Dead processes are pruned so exited sessions disappear")
    func prunesDeadProcesses() throws {
        let temp = try TempDirectory()
        defer { temp.cleanUp() }

        try temp.write(sessionJSON(pid: 100, status: "busy"), to: "100.json")
        try temp.write(sessionJSON(pid: 200, status: "busy"), to: "200.json")

        let registry = SessionRegistry(directory: temp.url, isAlive: { $0 == 100 })
        let sessions = registry.load()

        #expect(sessions.count == 1)
        #expect(sessions.first?.pid == 100)
    }

    @Test("A malformed file does not take down the rest of the list")
    func skipsMalformedFiles() throws {
        let temp = try TempDirectory()
        defer { temp.cleanUp() }

        try temp.write("{ this is not json", to: "1.json")
        try temp.write(#"{"sessionId":"x"}"#, to: "2.json")
        try temp.write(sessionJSON(pid: 300, status: "busy", name: "survivor"), to: "300.json")

        let sessions = SessionRegistry(directory: temp.url, isAlive: { _ in true }).load()

        #expect(sessions.count == 1)
        #expect(sessions.first?.name == "survivor")
    }

    @Test("A missing registry directory means no agents, not an error")
    func missingDirectory() {
        let missing = URL(fileURLWithPath: "/nonexistent/prfloat/\(UUID().uuidString)")
        #expect(SessionRegistry(directory: missing, isAlive: { _ in true }).load().isEmpty)
    }

    @Test("waitingFor is carried through for blocked sessions")
    func waitingFor() throws {
        let temp = try TempDirectory()
        defer { temp.cleanUp() }

        try temp.write(
            sessionJSON(pid: 100, status: "waiting", extra: #","waitingFor":"dialog open""#),
            to: "100.json"
        )

        let session = try #require(SessionRegistry(directory: temp.url, isAlive: { _ in true }).load().first)
        #expect(session.status == .blocked)
        #expect(session.waitingFor == "dialog open")
        #expect(session.statusDetail().contains("dialog open"))
    }

    @Test("Millisecond timestamps are converted to dates")
    func timestamps() {
        let date = SessionRegistry.millisecondDate(1_786_157_154_547)
        #expect(date?.timeIntervalSince1970 == 1_786_157_154.547)
        #expect(SessionRegistry.millisecondDate(nil) == nil)
        #expect(SessionRegistry.millisecondDate(0) == nil)
    }

    @Test("Falls back to the folder name when the registry has no name")
    func fallbackName() {
        let session = SessionRegistry.decode([
            "pid": 42, "cwd": "/Users/test/my-project", "status": "busy"
        ])
        #expect(session?.name == "my-project")
    }

    @Test("A record with no pid or cwd is rejected")
    func rejectsIncomplete() {
        #expect(SessionRegistry.decode(["cwd": "/tmp", "status": "busy"]) == nil)
        #expect(SessionRegistry.decode(["pid": 1, "status": "busy"]) == nil)
        #expect(SessionRegistry.decode(["pid": 1, "cwd": "", "status": "busy"]) == nil)
    }

    @Test("The live process check treats the current process as alive")
    func livenessCheck() {
        #expect(SessionRegistry.processIsAlive(ProcessInfo.processInfo.processIdentifier))
        #expect(!SessionRegistry.processIsAlive(0))
    }
}

@Suite("Agent status")
struct AgentStatusTests {
    @Test("Registry vocabulary maps onto panel states", arguments: [
        ("busy", AgentStatus.working),
        ("idle", AgentStatus.done),
        ("waiting", AgentStatus.blocked),
        ("something-new", AgentStatus.unknown)
    ])
    func mapping(raw: String, expected: AgentStatus) {
        #expect(AgentStatus(registryValue: raw) == expected)
    }

    @Test("Blocked agents sort above working ones, finished last")
    func ordering() {
        let now = Date()
        func make(_ pid: Int32, _ status: AgentStatus, justFinished: Bool = false) -> AgentSession {
            AgentSession(
                pid: pid, sessionID: "s", cwd: "/tmp", name: "n",
                status: status, rawStatus: status.rawValue,
                startedAt: now, statusUpdatedAt: now, justFinished: justFinished
            )
        }

        let sorted = [
            make(1, .done),
            make(2, .working),
            make(3, .blocked),
            make(4, .done, justFinished: true)
        ].sorted(by: AgentSession.displayOrder)

        #expect(sorted.map(\.pid) == [3, 4, 2, 1])
    }

    @Test("Elapsed times read naturally")
    func elapsed() {
        let now = Date()
        #expect(AgentSession.elapsedLabel(since: now.addingTimeInterval(-30), now: now) == "30s")
        #expect(AgentSession.elapsedLabel(since: now.addingTimeInterval(-120), now: now) == "2m")
        #expect(AgentSession.elapsedLabel(since: now.addingTimeInterval(-7200), now: now) == "2h")
    }

    @Test("A just-finished agent is called out differently from a long-idle one")
    func justFinishedLabel() {
        let now = Date()
        func session(justFinished: Bool) -> AgentSession {
            AgentSession(
                pid: 1, sessionID: "s", cwd: "/tmp/repo", name: "n",
                status: .done, rawStatus: "idle",
                startedAt: now, statusUpdatedAt: now.addingTimeInterval(-120),
                justFinished: justFinished
            )
        }
        #expect(session(justFinished: true).statusDetail(now: now) == "Just finished")
        #expect(session(justFinished: false).statusDetail(now: now) == "Finished 2m ago")
    }

    @Test("Location shows repo and branch, falling back to the folder")
    func locationLabel() {
        let now = Date()
        var session = AgentSession(
            pid: 1, sessionID: "s", cwd: "/Users/test/my-project", name: "n",
            status: .working, rawStatus: "busy", startedAt: now, statusUpdatedAt: now
        )
        #expect(session.locationLabel == "my-project")

        session.repository = "acme/my-project"
        session.branch = "feature/x"
        #expect(session.locationLabel == "my-project · feature/x")
    }
}
