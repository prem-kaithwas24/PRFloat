import Foundation
import Testing
@testable import PRFloatCore

/// Builds a fake `~/.claude/projects` tree.
private struct TempProjects {
    let root: URL

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prfloat-transcripts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    @discardableResult
    func addTranscript(project: String, sessionID: String, lines: [String]) throws -> URL {
        let directory = root.appendingPathComponent(project, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(sessionID).jsonl")
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func userLine(_ text: String) -> String {
    let payload: [String: Any] = [
        "type": "user",
        "message": ["role": "user", "content": text]
    ]
    return String(decoding: try! JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
}

private func assistantLine(_ text: String) -> String {
    let payload: [String: Any] = [
        "type": "assistant",
        "message": ["role": "assistant", "content": [["type": "text", "text": text]]]
    ]
    return String(decoding: try! JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
}

private func toolResultLine() -> String {
    let payload: [String: Any] = [
        "type": "user",
        "message": ["role": "user", "content": [
            ["type": "tool_result", "tool_use_id": "abc", "content": "some big output"]
        ]]
    ]
    return String(decoding: try! JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
}

@Suite("Transcript reader")
struct TranscriptReaderTests {
    @Test("Finds the most recent user prompt")
    func findsLastPrompt() throws {
        let temp = try TempProjects()
        defer { temp.cleanUp() }

        try temp.addTranscript(project: "-Users-test-proj", sessionID: "s1", lines: [
            userLine("first thing"),
            assistantLine("ok"),
            userLine("make it professional"),
            assistantLine("working on it")
        ])

        let reader = TranscriptReader(projectsDirectory: temp.root)
        #expect(reader.lastPrompt(sessionID: "s1") == "make it professional")
    }

    /// The measured real-world case: the prompt is buried far above the file's tail.
    @Test("Finds a prompt buried hundreds of lines deep under tool results")
    func findsDeeplyBuriedPrompt() throws {
        let temp = try TempProjects()
        defer { temp.cleanUp() }

        var lines = [userLine("deeply buried request")]
        for _ in 0..<400 {
            lines.append(toolResultLine())
            lines.append(assistantLine(String(repeating: "padding ", count: 200)))
        }

        try temp.addTranscript(project: "-Users-test-proj", sessionID: "deep", lines: lines)

        let reader = TranscriptReader(projectsDirectory: temp.root)
        #expect(reader.lastPrompt(sessionID: "deep") == "deeply buried request")
    }

    @Test("Tool results are not mistaken for prompts")
    func ignoresToolResults() throws {
        let temp = try TempProjects()
        defer { temp.cleanUp() }

        try temp.addTranscript(project: "p", sessionID: "s", lines: [
            userLine("the real prompt"),
            toolResultLine(),
            toolResultLine()
        ])

        #expect(TranscriptReader(projectsDirectory: temp.root).lastPrompt(sessionID: "s") == "the real prompt")
    }

    @Test("Sidechain and meta records are skipped")
    func skipsSidechainAndMeta() throws {
        let temp = try TempProjects()
        defer { temp.cleanUp() }

        let sidechain = #"{"type":"user","isSidechain":true,"message":{"content":"subagent task"}}"#
        let meta = #"{"type":"user","isMeta":true,"message":{"content":"meta bookkeeping"}}"#

        try temp.addTranscript(project: "p", sessionID: "s", lines: [
            userLine("genuine prompt"), sidechain, meta
        ])

        #expect(TranscriptReader(projectsDirectory: temp.root).lastPrompt(sessionID: "s") == "genuine prompt")
    }

    @Test("System reminder wrappers are stripped")
    func stripsWrappers() {
        let raw = "<system-reminder>ignore me</system-reminder>actual request"
        #expect(TranscriptReader.clean(raw) == "actual request")
    }

    @Test("A message that is only machinery yields nothing")
    func rejectsPureMachinery() {
        #expect(TranscriptReader.clean("<command-name>/loop</command-name>") == nil)
        #expect(TranscriptReader.clean("   ") == nil)
        #expect(TranscriptReader.clean("Caveat: The messages below were generated…") == nil)
    }

    @Test("Multi-line prompts collapse to a single display line")
    func collapsesWhitespace() {
        #expect(TranscriptReader.clean("do this\n\nand    that") == "do this and that")
    }

    @Test("A transcript with no user message returns nothing rather than guessing")
    func noUserMessage() throws {
        let temp = try TempProjects()
        defer { temp.cleanUp() }

        try temp.addTranscript(project: "p", sessionID: "s", lines: [
            assistantLine("only assistant output"), toolResultLine()
        ])

        #expect(TranscriptReader(projectsDirectory: temp.root).lastPrompt(sessionID: "s") == nil)
    }

    @Test("Corrupt lines are skipped without failing the read")
    func skipsCorruptLines() throws {
        let temp = try TempProjects()
        defer { temp.cleanUp() }

        try temp.addTranscript(project: "p", sessionID: "s", lines: [
            userLine("good prompt"),
            "{ not json at all",
            "",
            "]]]"
        ])

        #expect(TranscriptReader(projectsDirectory: temp.root).lastPrompt(sessionID: "s") == "good prompt")
    }

    @Test("Locates a transcript by session ID across several project directories")
    func locatesAcrossProjects() throws {
        let temp = try TempProjects()
        defer { temp.cleanUp() }

        try temp.addTranscript(project: "-Users-a", sessionID: "other", lines: [userLine("wrong")])
        try temp.addTranscript(project: "-Users-b-deep", sessionID: "target", lines: [userLine("right")])
        try temp.addTranscript(project: "-Users-c", sessionID: "another", lines: [userLine("wrong")])

        #expect(TranscriptReader(projectsDirectory: temp.root).lastPrompt(sessionID: "target") == "right")
    }

    @Test("An unknown session ID yields nothing")
    func unknownSession() throws {
        let temp = try TempProjects()
        defer { temp.cleanUp() }
        try temp.addTranscript(project: "p", sessionID: "s", lines: [userLine("hi")])

        let reader = TranscriptReader(projectsDirectory: temp.root)
        #expect(reader.lastPrompt(sessionID: "missing") == nil)
        #expect(reader.lastPrompt(sessionID: "") == nil)
    }

    @Test("An unchanged file is served from cache without re-reading")
    func cachesByModificationTime() throws {
        let temp = try TempProjects()
        defer { temp.cleanUp() }

        let file = try temp.addTranscript(project: "p", sessionID: "s", lines: [userLine("first")])
        let reader = TranscriptReader(projectsDirectory: temp.root)
        #expect(reader.lastPrompt(sessionID: "s") == "first")

        // Rewrite with a fresh timestamp; the reader must notice and re-read.
        try [userLine("second")].joined().write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)

        #expect(reader.lastPrompt(sessionID: "s") == "second")
    }
}
