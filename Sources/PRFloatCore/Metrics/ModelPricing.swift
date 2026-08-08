import Foundation

/// Tokens consumed by one or more model requests, split by how each class is billed.
public struct TokenUsage: Sendable, Equatable, Codable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite5m: Int
    public var cacheWrite1h: Int

    public init(
        input: Int = 0,
        output: Int = 0,
        cacheRead: Int = 0,
        cacheWrite5m: Int = 0,
        cacheWrite1h: Int = 0
    ) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
    }

    public static let zero = TokenUsage()

    /// Everything the model read, however it was billed.
    public var totalInput: Int { input + cacheRead + cacheWrite5m + cacheWrite1h }
    public var total: Int { totalInput + output }

    /// Share of input served from cache — the main efficiency lever in agent work.
    public var cacheHitRate: Double {
        guard totalInput > 0 else { return 0 }
        return Double(cacheRead) / Double(totalInput)
    }

    public static func += (lhs: inout TokenUsage, rhs: TokenUsage) {
        lhs.input += rhs.input
        lhs.output += rhs.output
        lhs.cacheRead += rhs.cacheRead
        lhs.cacheWrite5m += rhs.cacheWrite5m
        lhs.cacheWrite1h += rhs.cacheWrite1h
    }

    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        var copy = lhs
        copy += rhs
        return copy
    }
}

public struct ModelRate: Sendable, Equatable {
    /// USD per million tokens.
    public let input: Double
    public let output: Double

    public init(input: Double, output: Double) {
        self.input = input
        self.output = output
    }
}

/// List-price cost estimation for Claude models.
///
/// Rates are per million tokens and are a point-in-time snapshot, not a billing
/// authority: costs shown are estimates at public list prices and ignore any negotiated
/// discount. Cache multipliers are relative to the model's input rate.
public enum ModelPricing {
    /// Cache reads bill at a tenth of the input rate.
    public static let cacheReadMultiplier = 0.1
    /// Writing a 5-minute cache entry carries a 25% premium.
    public static let cacheWrite5mMultiplier = 1.25
    /// A 1-hour entry costs double, so it needs more reads to pay off.
    public static let cacheWrite1hMultiplier = 2.0

    /// Pricing snapshot date, surfaced in the UI so a stale table is visible rather than silent.
    public static let ratesAsOf = "2026-06-24"

    private static let rates: [String: ModelRate] = [
        "claude-fable-5": ModelRate(input: 10, output: 50),
        "claude-mythos-5": ModelRate(input: 10, output: 50),
        "claude-opus-5": ModelRate(input: 5, output: 25),
        "claude-opus-4-8": ModelRate(input: 5, output: 25),
        "claude-opus-4-7": ModelRate(input: 5, output: 25),
        "claude-opus-4-6": ModelRate(input: 5, output: 25),
        "claude-opus-4-5": ModelRate(input: 5, output: 25),
        "claude-sonnet-5": ModelRate(input: 3, output: 15),
        "claude-sonnet-4-6": ModelRate(input: 3, output: 15),
        "claude-sonnet-4-5": ModelRate(input: 3, output: 15),
        "claude-haiku-4-5": ModelRate(input: 1, output: 5)
    ]

    /// Claude Sonnet 5 carries introductory pricing through 2026-08-31.
    private static let sonnet5IntroRate = ModelRate(input: 2, output: 10)
    private static let sonnet5IntroEnds: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 1
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar.date(from: components) ?? .distantPast
    }()

    /// Rates for a model id, or nil when the model is unknown (so cost is reported as partial
    /// rather than silently wrong).
    public static func rate(for model: String, on date: Date = Date()) -> ModelRate? {
        let id = normalize(model)
        if id == "claude-sonnet-5", date < sonnet5IntroEnds {
            return sonnet5IntroRate
        }
        return rates[id]
    }

    /// Strips date suffixes and the `[1m]` context marker so `claude-opus-5[1m]` and
    /// `claude-haiku-4-5-20251001` both resolve.
    static func normalize(_ model: String) -> String {
        var id = model.lowercased()
        if let bracket = id.firstIndex(of: "[") {
            id = String(id[id.startIndex..<bracket])
        }
        id = id.trimmingCharacters(in: .whitespaces)

        // Trailing eight-digit date snapshot, e.g. -20251001
        let parts = id.split(separator: "-")
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) {
            id = parts.dropLast().joined(separator: "-")
        }
        return id
    }

    /// Estimated USD for one model's usage. Returns nil for an unpriced model.
    public static func cost(of usage: TokenUsage, model: String, on date: Date = Date()) -> Double? {
        guard let rate = rate(for: model, on: date) else { return nil }
        let perToken = rate.input / 1_000_000
        let outPerToken = rate.output / 1_000_000

        return Double(usage.input) * perToken
            + Double(usage.output) * outPerToken
            + Double(usage.cacheRead) * perToken * cacheReadMultiplier
            + Double(usage.cacheWrite5m) * perToken * cacheWrite5mMultiplier
            + Double(usage.cacheWrite1h) * perToken * cacheWrite1hMultiplier
    }

    public static func isPriced(_ model: String) -> Bool {
        rate(for: model) != nil
    }
}
