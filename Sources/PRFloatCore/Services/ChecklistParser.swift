import Foundation

/// Parses GitHub-style markdown task lists from a PR body.
public enum ChecklistParser {
    /// Matches lines like `- [ ] task`, `* [x] task`, `1. [X] task` with optional leading whitespace.
    private static let taskPattern = try! NSRegularExpression(
        pattern: #"^\s*(?:[-*]|\d+\.)\s*\[([ xX])\]\s+"#,
        options: [.anchorsMatchLines]
    )

    public static func parse(_ body: String?) -> (done: Int, total: Int) {
        guard let body, !body.isEmpty else { return (0, 0) }

        let ns = body as NSString
        let range = NSRange(location: 0, length: ns.length)
        let matches = taskPattern.matches(in: body, options: [], range: range)

        var done = 0
        for match in matches {
            guard match.numberOfRanges >= 2 else { continue }
            let mark = ns.substring(with: match.range(at: 1))
            if mark.lowercased() == "x" {
                done += 1
            }
        }
        return (done, matches.count)
    }
}
