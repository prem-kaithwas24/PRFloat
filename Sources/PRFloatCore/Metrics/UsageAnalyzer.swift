import Foundation

/// Per-transcript usage rollup. One of these is cached per session file.
public struct TranscriptUsage: Codable, Sendable, Equatable {
    public var sessionID: String
    public var cwd: String
    /// `yyyy-MM-dd` → model id → tokens.
    public var byDayModel: [String: [String: TokenUsage]]
    /// `yyyy-MM-dd` → assistant messages, a proxy for how much work happened.
    public var messagesByDay: [String: Int]
    /// `yyyy-MM-dd` → tool name → invocations. Day-scoped so a period filter is exact.
    public var toolCountsByDay: [String: [String: Int]]
    /// `yyyy-MM-dd` → distinct days this session was active (for session counting).
    public var activeDays: Set<String>

    public init(
        sessionID: String = "",
        cwd: String = "",
        byDayModel: [String: [String: TokenUsage]] = [:],
        messagesByDay: [String: Int] = [:],
        toolCountsByDay: [String: [String: Int]] = [:],
        activeDays: Set<String> = []
    ) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.byDayModel = byDayModel
        self.messagesByDay = messagesByDay
        self.toolCountsByDay = toolCountsByDay
        self.activeDays = activeDays
    }
}

/// Reads Claude Code transcripts and rolls up token usage, model mix, and tool activity.
///
/// Transcripts are large (multi-MB) and mostly immutable, so results are cached per file on
/// `(size, modified)` and persisted to Application Support. A refresh re-parses only the
/// sessions that actually moved.
public final class UsageAnalyzer: @unchecked Sendable {
    public static let defaultProjectsDirectory = TranscriptReader.defaultProjectsDirectory

    private struct CacheEntry: Codable {
        let size: Int
        let modified: Date
        let usage: TranscriptUsage
    }

    private let projectsDirectory: URL
    private let cacheURL: URL
    private let lock = NSLock()
    private var cache: [String: CacheEntry] = [:]
    private var loadedCache = false

    public init(
        projectsDirectory: URL = UsageAnalyzer.defaultProjectsDirectory,
        cacheURL: URL = UsageAnalyzer.defaultCacheURL()
    ) {
        self.projectsDirectory = projectsDirectory
        self.cacheURL = cacheURL
    }

    public static func defaultCacheURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("PRFloat", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("usage-cache.json")
    }

    /// Every transcript's rollup. Call off the main thread — the first run parses everything.
    public func loadAll() -> [TranscriptUsage] {
        loadCacheIfNeeded()

        guard let projectDirectories = try? FileManager.default.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        var results: [TranscriptUsage] = []
        var touched: Set<String> = []

        for directory in projectDirectories {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
            )) ?? []

            for file in files where file.pathExtension == "jsonl" {
                let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
                let size = (attributes?[.size] as? Int) ?? 0
                let modified = (attributes?[.modificationDate] as? Date) ?? .distantPast
                let key = file.path
                touched.insert(key)

                lock.lock()
                let cached = cache[key]
                lock.unlock()

                if let cached, cached.size == size, cached.modified == modified {
                    results.append(cached.usage)
                    continue
                }

                let usage = Self.parse(file: file)
                lock.lock()
                cache[key] = CacheEntry(size: size, modified: modified, usage: usage)
                lock.unlock()
                results.append(usage)
            }
        }

        // Drop entries for transcripts that no longer exist.
        lock.lock()
        cache = cache.filter { touched.contains($0.key) }
        lock.unlock()

        saveCache()
        return results
    }

    // MARK: - Parsing

    static func parse(file: URL) -> TranscriptUsage {
        var summary = TranscriptUsage(sessionID: file.deletingPathExtension().lastPathComponent)

        guard let handle = try? FileHandle(forReadingFrom: file) else { return summary }
        defer { try? handle.close() }
        guard let data = try? handle.readToEnd() else { return summary }

        // Split on newlines without materialising a [String] of the whole file.
        var lineStart = data.startIndex
        while lineStart < data.endIndex {
            let lineEnd = data[lineStart...].firstIndex(of: 0x0A) ?? data.endIndex
            if lineEnd > lineStart {
                accumulate(line: data[lineStart..<lineEnd], into: &summary)
            }
            lineStart = lineEnd < data.endIndex ? data.index(after: lineEnd) : data.endIndex
        }
        return summary
    }

    private static func accumulate(line: Data.SubSequence, into summary: inout TranscriptUsage) {
        guard
            let object = try? JSONSerialization.jsonObject(with: Data(line)),
            let record = object as? [String: Any]
        else {
            return
        }

        if summary.cwd.isEmpty, let cwd = record["cwd"] as? String {
            summary.cwd = cwd
        }

        guard record["type"] as? String == "assistant" else { return }
        guard let message = record["message"] as? [String: Any] else { return }

        let day = dayKey(from: record["timestamp"] as? String)
        summary.activeDays.insert(day)
        summary.messagesByDay[day, default: 0] += 1

        if let blocks = message["content"] as? [[String: Any]] {
            for block in blocks where block["type"] as? String == "tool_use" {
                if let name = block["name"] as? String {
                    summary.toolCountsByDay[day, default: [:]][name, default: 0] += 1
                }
            }
        }

        // `<synthetic>` marks locally-generated messages that were never billed.
        guard
            let model = message["model"] as? String,
            !model.isEmpty,
            model != "<synthetic>",
            let usageDict = message["usage"] as? [String: Any]
        else {
            return
        }

        let usage = tokenUsage(from: usageDict)
        guard usage.total > 0 else { return }
        summary.byDayModel[day, default: [:]][model, default: .zero] += usage
    }

    static func tokenUsage(from dict: [String: Any]) -> TokenUsage {
        func int(_ key: String, in source: [String: Any]) -> Int {
            if let value = source[key] as? Int { return value }
            if let value = source[key] as? Double { return Int(value) }
            return 0
        }

        // The cache_creation breakdown is authoritative when present; the flat
        // cache_creation_input_tokens is its total, so using both would double-count.
        var write5m = 0
        var write1h = 0
        if let creation = dict["cache_creation"] as? [String: Any] {
            write5m = int("ephemeral_5m_input_tokens", in: creation)
            write1h = int("ephemeral_1h_input_tokens", in: creation)
        } else {
            write5m = int("cache_creation_input_tokens", in: dict)
        }

        return TokenUsage(
            input: int("input_tokens", in: dict),
            output: int("output_tokens", in: dict),
            cacheRead: int("cache_read_input_tokens", in: dict),
            cacheWrite5m: write5m,
            cacheWrite1h: write1h
        )
    }

    // MARK: - Dates

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoFormatterNoFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// Transcript timestamps are UTC; days are bucketed in the user's local time, since
    /// "how am I doing today" means their today.
    static func dayKey(from timestamp: String?) -> String {
        guard let timestamp else { return dayFormatter.string(from: Date()) }
        let date = isoFormatter.date(from: timestamp)
            ?? isoFormatterNoFraction.date(from: timestamp)
        return dayFormatter.string(from: date ?? Date())
    }

    public static func dayKey(for date: Date) -> String {
        dayFormatter.string(from: date)
    }

    // MARK: - Cache persistence

    private func loadCacheIfNeeded() {
        lock.lock()
        let alreadyLoaded = loadedCache
        loadedCache = true
        lock.unlock()
        guard !alreadyLoaded else { return }

        guard
            let data = try? Data(contentsOf: cacheURL),
            let decoded = try? JSONDecoder().decode([String: CacheEntry].self, from: data)
        else {
            return
        }
        lock.lock()
        cache = decoded
        lock.unlock()
    }

    private func saveCache() {
        lock.lock()
        let snapshot = cache
        lock.unlock()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}
