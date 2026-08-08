import Foundation

public struct GitRepoInfo: Equatable, Sendable {
    /// `owner/repo` when the origin remote points at GitHub.
    public let nameWithOwner: String?
    public let branch: String?

    public init(nameWithOwner: String?, branch: String?) {
        self.nameWithOwner = nameWithOwner
        self.branch = branch
    }
}

/// Maps a session's working directory to the GitHub repo and branch it is sitting on,
/// which is what lets an agent be matched to one of the user's pull requests.
public struct RepoResolver: Sendable {
    public init() {}

    public func resolve(cwd: String) -> GitRepoInfo? {
        guard let gitDir = Self.findGitDirectory(startingAt: cwd) else { return nil }
        return GitRepoInfo(
            nameWithOwner: Self.originNameWithOwner(commonDir: gitDir.commonDir),
            branch: Self.currentBranch(gitDir: gitDir.gitDir)
        )
    }

    struct GitPaths: Equatable {
        /// Where HEAD lives (a worktree has its own).
        let gitDir: URL
        /// Where config lives (shared across worktrees).
        let commonDir: URL
    }

    /// Walks up from `path` looking for `.git`, handling both a directory and the
    /// `gitdir:` pointer file that worktrees and submodules use.
    static func findGitDirectory(startingAt path: String) -> GitPaths? {
        var current = URL(fileURLWithPath: path).standardizedFileURL

        while true {
            let candidate = current.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false

            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    return GitPaths(gitDir: candidate, commonDir: candidate)
                }
                // A `.git` file points elsewhere: "gitdir: /path/to/.git/worktrees/name"
                if let contents = try? String(contentsOf: candidate, encoding: .utf8),
                   let pointer = contents
                       .split(separator: "\n")
                       .first(where: { $0.hasPrefix("gitdir:") })?
                       .dropFirst("gitdir:".count)
                       .trimmingCharacters(in: .whitespaces),
                   !pointer.isEmpty
                {
                    let gitDir = URL(fileURLWithPath: pointer, relativeTo: current).standardizedFileURL
                    return GitPaths(gitDir: gitDir, commonDir: commonDirectory(for: gitDir))
                }
                return nil
            }

            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent == current { return nil }
            current = parent
        }
    }

    /// For `…/.git/worktrees/foo`, config lives two levels up in `…/.git`.
    static func commonDirectory(for gitDir: URL) -> URL {
        let commonFile = gitDir.appendingPathComponent("commondir")
        if let contents = try? String(contentsOf: commonFile, encoding: .utf8) {
            let relative = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            if !relative.isEmpty {
                return URL(fileURLWithPath: relative, relativeTo: gitDir).standardizedFileURL
            }
        }
        return gitDir
    }

    static func currentBranch(gitDir: URL) -> String? {
        guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8) else {
            return nil
        }
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        // Detached HEAD holds a bare SHA and has no branch to report.
        guard trimmed.hasPrefix("ref:") else { return nil }
        let ref = trimmed.dropFirst("ref:".count).trimmingCharacters(in: .whitespaces)
        guard ref.hasPrefix("refs/heads/") else { return nil }
        let branch = String(ref.dropFirst("refs/heads/".count))
        return branch.isEmpty ? nil : branch
    }

    static func originNameWithOwner(commonDir: URL) -> String? {
        guard let config = try? String(contentsOf: commonDir.appendingPathComponent("config"), encoding: .utf8) else {
            return nil
        }
        guard let url = originURL(inConfig: config) else { return nil }
        return nameWithOwner(fromRemoteURL: url)
    }

    /// Minimal git-config reader: finds `url` inside the `[remote "origin"]` section.
    static func originURL(inConfig config: String) -> String? {
        var inOrigin = false
        for rawLine in config.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                let normalized = line.replacingOccurrences(of: " ", with: "")
                inOrigin = normalized.hasPrefix("[remote\"origin\"]")
                continue
            }
            guard inOrigin, line.hasPrefix("url") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { return value }
        }
        return nil
    }

    /// Normalises the remote forms git accepts down to `owner/repo`.
    static func nameWithOwner(fromRemoteURL remote: String) -> String? {
        var path = remote.trimmingCharacters(in: .whitespaces)

        if let range = path.range(of: "://") {
            // https://github.com/owner/repo.git or ssh://git@github.com/owner/repo.git
            path = String(path[range.upperBound...])
            if let slash = path.firstIndex(of: "/") {
                path = String(path[path.index(after: slash)...])
            }
        } else if let colon = path.firstIndex(of: ":") {
            // git@github.com:owner/repo.git
            path = String(path[path.index(after: colon)...])
        }

        if path.hasSuffix(".git") {
            path = String(path.dropLast(4))
        }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        let components = path.split(separator: "/")
        guard components.count >= 2 else { return nil }
        return "\(components[components.count - 2])/\(components[components.count - 1])"
    }
}
