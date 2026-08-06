import Foundation

public enum GitHubCLIError: LocalizedError, Equatable {
    case ghNotFound
    case notAuthenticated
    case notARepo
    case timedOut
    case commandFailed(exitCode: Int32, stderr: String)
    case invalidJSON(String)

    public var errorDescription: String? {
        switch self {
        case .ghNotFound:
            return "Install GitHub CLI (gh) and ensure it is on PATH"
        case .notAuthenticated:
            return "Run `gh auth login` in Terminal"
        case .notARepo:
            return "Folder is not a GitHub repo `gh` can use"
        case .timedOut:
            return "`gh` timed out"
        case .commandFailed(_, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return "gh command failed" }
            return String(trimmed.prefix(280))
        case .invalidJSON(let detail):
            return "Could not parse gh output: \(detail)"
        }
    }
}

/// Runs `gh` with argv (never shell) and decodes PR list JSON.
public struct GitHubCLIService: Sendable {
    public var ghPath: String
    public var timeoutSeconds: TimeInterval

    public init(ghPath: String = "gh", timeoutSeconds: TimeInterval = 30) {
        self.ghPath = ghPath
        self.timeoutSeconds = timeoutSeconds
    }

    public func fetchOpenAuthoredPRs(repoPath: String) async throws -> [PRSummary] {
        let data = try await run(
            arguments: [
                "pr", "list",
                "--author", "@me",
                "--state", "open",
                "--limit", "20",
                "--json", "number,title,headRefName,url,body,statusCheckRollup"
            ],
            cwd: repoPath
        )
        return try Self.decodePRList(data)
    }

    /// Decode `gh pr list --json …` payload into summaries (also used by tests/validate).
    public static func decodePRList(_ data: Data) throws -> [PRSummary] {
        do {
            let rows = try JSONDecoder().decode([GHPRListItem].self, from: data)
            return rows.map { $0.toSummary() }
        } catch {
            throw GitHubCLIError.invalidJSON(error.localizedDescription)
        }
    }

    public func resolveGhPath() throws -> String {
        if ghPath != "gh", FileManager.default.isExecutableFile(atPath: ghPath) {
            return ghPath
        }
        if let path = which("gh") {
            return path
        }
        // Common Homebrew locations when GUI apps get a minimal PATH
        for candidate in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        throw GitHubCLIError.ghNotFound
    }

    // MARK: - Process

    private func run(arguments: [String], cwd: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try self.runSync(arguments: arguments, cwd: cwd)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func runSync(arguments: [String], cwd: String) throws -> Data {
        let executable = try resolveGhPath()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = augmentedEnvironment()

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                throw GitHubCLIError.timedOut
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let errText = String(data: errData, encoding: .utf8) ?? ""

        let code = process.terminationStatus
        if code != 0 {
            throw classifyFailure(exitCode: code, stderr: errText)
        }
        return outData
    }

    private func classifyFailure(exitCode: Int32, stderr: String) -> GitHubCLIError {
        let lower = stderr.lowercased()
        if lower.contains("not logged into") || lower.contains("auth login") || lower.contains("authentication") {
            return .notAuthenticated
        }
        if lower.contains("not a git repository")
            || lower.contains("no git remotes")
            || lower.contains("could not determine")
            || lower.contains("no default remote")
        {
            return .notARepo
        }
        if lower.contains("executable file not found") || exitCode == 127 {
            return .ghNotFound
        }
        return .commandFailed(exitCode: exitCode, stderr: stderr)
    }

    private func augmentedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extras = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let path = env["PATH"] ?? ""
        let parts = path.split(separator: ":").map(String.init)
        var merged = extras
        for p in parts where !merged.contains(p) {
            merged.append(p)
        }
        env["PATH"] = merged.joined(separator: ":")
        return env
    }

    private func which(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        process.environment = augmentedEnvironment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else {
                return nil
            }
            return path
        } catch {
            return nil
        }
    }
}

// MARK: - gh JSON

struct GHPRListItem: Decodable {
    let number: Int
    let title: String
    let headRefName: String
    let url: URL
    let body: String?
    let statusCheckRollup: [GHCheck]?

    func toSummary() -> PRSummary {
        let checklist = ChecklistParser.parse(body)
        let checks = CheckSummary.from(rollup: statusCheckRollup ?? [])
        return PRSummary(
            number: number,
            title: title,
            headRefName: headRefName,
            url: url,
            checklistDone: checklist.done,
            checklistTotal: checklist.total,
            checks: checks
        )
    }
}

struct GHCheck: Decodable {
    let state: String?
    let status: String?
    let conclusion: String?
    let name: String?

    var normalized: String {
        // CheckRun uses conclusion (SUCCESS/FAILURE) + status (COMPLETED/IN_PROGRESS).
        // StatusContext uses state (SUCCESS/PENDING/FAILURE).
        let raw = (conclusion ?? state ?? status ?? "").lowercased()
        return raw
    }
}

extension CheckSummary {
    public static func from(rollupStates: [String]) -> CheckSummary {
        let checks = rollupStates.map { GHCheck(state: $0, status: nil, conclusion: nil, name: nil) }
        return from(rollup: checks)
    }

    static func from(rollup: [GHCheck]) -> CheckSummary {
        var passing = 0
        var failing = 0
        var pending = 0

        for check in rollup {
            let s = check.normalized
            if s.isEmpty {
                pending += 1
                continue
            }
            if ["success", "pass", "passed", "completed_success", "neutral", "skipped"].contains(s) {
                // GitHub rollup often uses SUCCESS / FAILURE / PENDING
                if s == "neutral" || s == "skipped" {
                    passing += 1
                } else {
                    passing += 1
                }
            } else if ["failure", "failed", "error", "timed_out", "cancelled", "action_required", "startup_failure"].contains(s) {
                failing += 1
            } else if ["pending", "queued", "in_progress", "expected", "waiting", "requested", "running"].contains(s) {
                pending += 1
            } else if s == "success" || s.hasSuffix("success") {
                passing += 1
            } else {
                // Unknown → treat as pending so user notices
                pending += 1
            }
        }

        return CheckSummary(passing: passing, failing: failing, pending: pending)
    }
}
