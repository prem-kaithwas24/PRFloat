import Foundation
import Testing
@testable import PRFloatCore

/// Builds a minimal on-disk git layout — enough for the resolver, without invoking git.
private struct TempRepo {
    let root: URL

    init(remote: String?, head: String = "ref: refs/heads/main") throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prfloat-repo-\(UUID().uuidString)", isDirectory: true)
        let gitDir = root.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)

        var config = "[core]\n\trepositoryformatversion = 0\n"
        if let remote {
            config += "[remote \"origin\"]\n\turl = \(remote)\n\tfetch = +refs/heads/*\n"
        }
        config += "[branch \"main\"]\n\tremote = origin\n"

        try config.write(to: gitDir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try head.write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
    }

    func makeSubdirectory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("Repo resolution")
struct RepoResolverTests {
    @Test("Resolves an SSH remote and the current branch")
    func sshRemote() throws {
        let repo = try TempRepo(remote: "git@github.com:acme/widgets.git")
        defer { repo.cleanUp() }

        let info = try #require(RepoResolver().resolve(cwd: repo.root.path))
        #expect(info.nameWithOwner == "acme/widgets")
        #expect(info.branch == "main")
    }

    @Test("Resolves an HTTPS remote")
    func httpsRemote() throws {
        let repo = try TempRepo(
            remote: "https://github.com/acme/widgets.git",
            head: "ref: refs/heads/feature/login"
        )
        defer { repo.cleanUp() }

        let info = try #require(RepoResolver().resolve(cwd: repo.root.path))
        #expect(info.nameWithOwner == "acme/widgets")
        #expect(info.branch == "feature/login")
    }

    @Test("Finds the repo from a nested subdirectory, as sessions often sit deep in a tree")
    func nestedDirectory() throws {
        let repo = try TempRepo(remote: "git@github.com:acme/widgets.git")
        defer { repo.cleanUp() }

        let nested = try repo.makeSubdirectory("src/deep/nested")
        let info = try #require(RepoResolver().resolve(cwd: nested.path))
        #expect(info.nameWithOwner == "acme/widgets")
    }

    @Test("Detached HEAD reports no branch rather than a SHA")
    func detachedHead() throws {
        let repo = try TempRepo(
            remote: "git@github.com:acme/widgets.git",
            head: "9fceb02c1b4e5d3a8f0e2b1c7d6a5948e3f2b1c0"
        )
        defer { repo.cleanUp() }

        let info = try #require(RepoResolver().resolve(cwd: repo.root.path))
        #expect(info.branch == nil)
        #expect(info.nameWithOwner == "acme/widgets")
    }

    @Test("A repo with no origin still reports its branch")
    func noRemote() throws {
        let repo = try TempRepo(remote: nil)
        defer { repo.cleanUp() }

        let info = try #require(RepoResolver().resolve(cwd: repo.root.path))
        #expect(info.nameWithOwner == nil)
        #expect(info.branch == "main")
    }

    @Test("A directory that is not a repo resolves to nothing")
    func notARepo() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prfloat-plain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(RepoResolver().resolve(cwd: directory.path) == nil)
    }

    @Test("Remote URL forms all normalise to owner/repo", arguments: [
        ("git@github.com:acme/widgets.git", "acme/widgets"),
        ("git@github.com:acme/widgets", "acme/widgets"),
        ("https://github.com/acme/widgets.git", "acme/widgets"),
        ("https://github.com/acme/widgets", "acme/widgets"),
        ("ssh://git@github.com/acme/widgets.git", "acme/widgets"),
        ("https://user@github.com/acme/widgets.git", "acme/widgets")
    ])
    func remoteForms(remote: String, expected: String) {
        #expect(RepoResolver.nameWithOwner(fromRemoteURL: remote) == expected)
    }

    @Test("A remote with no owner segment is rejected")
    func malformedRemote() {
        #expect(RepoResolver.nameWithOwner(fromRemoteURL: "notaurl") == nil)
    }

    @Test("Only the origin section is read, not other remotes")
    func ignoresOtherRemotes() {
        let config = """
        [remote "upstream"]
        \turl = git@github.com:upstream/widgets.git
        [remote "origin"]
        \turl = git@github.com:acme/widgets.git
        """
        #expect(RepoResolver.originURL(inConfig: config) == "git@github.com:acme/widgets.git")
    }
}

@Suite("Agent correlation")
struct AgentCorrelatorTests {
    private func agent(pid: Int32, repository: String?, branch: String?) -> AgentSession {
        var session = AgentSession(
            pid: pid, sessionID: "s\(pid)", cwd: "/tmp/\(pid)", name: "agent-\(pid)",
            status: .working, rawStatus: "busy", startedAt: Date(), statusUpdatedAt: Date()
        )
        session.repository = repository
        session.branch = branch
        return session
    }

    private func pr(repository: String, number: Int, branch: String) -> PRSummary {
        PRSummary(
            repository: repository, number: number, title: "t", headRefName: branch,
            url: URL(string: "https://example.com")!,
            checklistDone: 0, checklistTotal: 0, checks: .empty
        )
    }

    @Test("An agent on a PR's branch is linked to it")
    func matches() {
        let prs = [pr(repository: "acme/widgets", number: 1, branch: "feature/x")]
        let index = AgentCorrelator.index(
            agents: [agent(pid: 1, repository: "acme/widgets", branch: "feature/x")],
            prs: prs
        )
        #expect(index[prs[0].id]?.count == 1)
    }

    @Test("The same branch name in a different repo is not a match")
    func repositoryMustMatch() {
        let prs = [pr(repository: "acme/widgets", number: 1, branch: "main")]
        let index = AgentCorrelator.index(
            agents: [agent(pid: 1, repository: "other/thing", branch: "main")],
            prs: prs
        )
        #expect(index.isEmpty)
    }

    @Test("An agent with unresolved git metadata matches nothing")
    func unresolvedAgent() {
        let prs = [pr(repository: "acme/widgets", number: 1, branch: "main")]
        let index = AgentCorrelator.index(
            agents: [agent(pid: 1, repository: nil, branch: nil)],
            prs: prs
        )
        #expect(index.isEmpty)
    }

    @Test("Two agents on one branch are both linked")
    func multipleAgents() {
        let prs = [pr(repository: "acme/widgets", number: 1, branch: "feature/x")]
        let index = AgentCorrelator.index(
            agents: [
                agent(pid: 1, repository: "acme/widgets", branch: "feature/x"),
                agent(pid: 2, repository: "acme/widgets", branch: "feature/x")
            ],
            prs: prs
        )
        #expect(index[prs[0].id]?.count == 2)
    }

    @Test("Empty inputs produce an empty index")
    func emptyInputs() {
        #expect(AgentCorrelator.index(agents: [], prs: []).isEmpty)
    }
}
