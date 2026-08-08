import Foundation

/// Extracts the most recent thing the user asked an agent to do, from its transcript.
///
/// Locating the file: transcripts live at `~/.claude/projects/<slug>/<sessionId>.jsonl`,
/// where `<slug>` is a mangled working directory. The mangling is another application's
/// private detail, so rather than reimplement it we glob every project directory for the
/// session ID, which is unique.
///
/// Reading the file: a fixed tail is not enough. Measured against real transcripts the
/// last user message sat 100–180 lines from the end, buried under tool results, so a
/// 200KB tail found nothing. The reader starts at 256KB and doubles up to a cap.
public final class TranscriptReader: @unchecked Sendable {
    public static let defaultProjectsDirectory = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects", isDirectory: true)

    static let initialWindow = 256 * 1024
    static let maximumWindow = 4 * 1024 * 1024

    private struct CacheEntry {
        let modified: Date
        let size: Int
        let prompt: String?
    }

    private let projectsDirectory: URL
    private let lock = NSLock()
    private var cache: [String: CacheEntry] = [:]
    private var pathCache: [String: URL] = [:]

    public init(projectsDirectory: URL = TranscriptReader.defaultProjectsDirectory) {
        self.projectsDirectory = projectsDirectory
    }

    /// The last user prompt for a session, or nil when none can be found.
    public func lastPrompt(sessionID: String) -> String? {
        guard !sessionID.isEmpty, let url = transcriptURL(sessionID: sessionID) else { return nil }

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = attributes?[.modificationDate] as? Date ?? .distantPast
        let size = (attributes?[.size] as? Int) ?? 0

        lock.lock()
        if let cached = cache[sessionID], cached.modified == modified, cached.size == size {
            lock.unlock()
            return cached.prompt
        }
        lock.unlock()

        let prompt = Self.findLastPrompt(in: url, fileSize: size)

        lock.lock()
        cache[sessionID] = CacheEntry(modified: modified, size: size, prompt: prompt)
        lock.unlock()

        return prompt
    }

    // MARK: - Locating

    func transcriptURL(sessionID: String) -> URL? {
        lock.lock()
        let cached = pathCache[sessionID]
        lock.unlock()
        if let cached, FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }

        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return nil
        }

        for directory in directories {
            let candidate = directory.appendingPathComponent("\(sessionID).jsonl")
            if FileManager.default.fileExists(atPath: candidate.path) {
                lock.lock()
                pathCache[sessionID] = candidate
                lock.unlock()
                return candidate
            }
        }
        return nil
    }

    // MARK: - Reading

    static func findLastPrompt(in url: URL, fileSize: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var window = initialWindow
        while true {
            let offset = max(0, fileSize - window)
            guard
                (try? handle.seek(toOffset: UInt64(offset))) != nil,
                let data = try? handle.readToEnd()
            else {
                return nil
            }

            var text = String(decoding: data, as: UTF8.self)
            // A mid-file window almost certainly starts inside a line; drop the fragment.
            if offset > 0, let newline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: newline)...])
            }

            if let prompt = lastPrompt(inLines: text) {
                return prompt
            }
            // Read the whole file already, or hit the cap — give up rather than churn.
            if offset == 0 || window >= maximumWindow { return nil }
            window = min(window * 2, maximumWindow)
        }
    }

    static func lastPrompt(inLines text: String) -> String? {
        for line in text.split(separator: "\n").reversed() {
            guard
                let data = line.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data),
                let record = object as? [String: Any]
            else {
                continue
            }
            if let prompt = prompt(fromRecord: record) {
                return prompt
            }
        }
        return nil
    }

    static func prompt(fromRecord record: [String: Any]) -> String? {
        guard record["type"] as? String == "user" else { return nil }
        // Sidechains are subagent traffic and meta records are bookkeeping — neither is
        // something the user typed.
        if record["isSidechain"] as? Bool == true { return nil }
        if record["isMeta"] as? Bool == true { return nil }

        guard let message = record["message"] as? [String: Any] else { return nil }

        let text: String
        if let string = message["content"] as? String {
            text = string
        } else if let blocks = message["content"] as? [[String: Any]] {
            // Tool results share the `user` type; only real text blocks count.
            text = blocks
                .filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined(separator: " ")
        } else {
            return nil
        }

        return clean(text)
    }

    /// Strips wrapper blocks the CLI injects, so the panel shows what the user typed.
    static func clean(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        for tag in ["system-reminder", "command-name", "command-message", "command-args",
                    "local-command-stdout", "local-command-stderr", "user-prompt-submit-hook"] {
            text = removeTagBlocks(named: tag, from: text)
        }

        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Anything still opening with a tag is machinery, not a prompt.
        guard !text.isEmpty, !text.hasPrefix("<") else { return nil }
        guard !text.hasPrefix("Caveat: The messages below") else { return nil }

        let collapsed = text
            .split(whereSeparator: { $0.isNewline || $0 == "\t" })
            .joined(separator: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    static func removeTagBlocks(named tag: String, from text: String) -> String {
        var result = text
        while let start = result.range(of: "<\(tag)>"),
              let end = result.range(of: "</\(tag)>", range: start.upperBound..<result.endIndex) {
            result.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return result
    }
}
