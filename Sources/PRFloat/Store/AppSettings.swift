import Foundation
import Observation

/// User-facing preferences, persisted to `UserDefaults`.
@MainActor
@Observable
final class AppSettings {
    enum PollInterval: Int, CaseIterable, Identifiable {
        case thirtySeconds = 30
        case oneMinute = 60
        case fiveMinutes = 300
        case manual = 0

        var id: Int { rawValue }

        var label: String {
            switch self {
            case .thirtySeconds: return "Every 30 seconds"
            case .oneMinute: return "Every minute"
            case .fiveMinutes: return "Every 5 minutes"
            case .manual: return "Manually"
            }
        }
    }

    private enum Key {
        static let pollInterval = "pollIntervalSeconds"
        static let showAgents = "showAgentsSection"
        static let showPRs = "showPullRequestsSection"
        static let launchAtLogin = "launchAtLogin"
        static let alwaysOnTop = "alwaysOnTop"
    }

    private let defaults: UserDefaults

    var pollInterval: PollInterval {
        didSet { defaults.set(pollInterval.rawValue, forKey: Key.pollInterval) }
    }

    var showAgents: Bool {
        didSet { defaults.set(showAgents, forKey: Key.showAgents) }
    }

    var showPullRequests: Bool {
        didSet { defaults.set(showPullRequests, forKey: Key.showPRs) }
    }

    var alwaysOnTop: Bool {
        didSet { defaults.set(alwaysOnTop, forKey: Key.alwaysOnTop) }
    }

    var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Key.launchAtLogin) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.pollInterval: PollInterval.oneMinute.rawValue,
            Key.showAgents: true,
            Key.showPRs: true,
            Key.alwaysOnTop: true,
            Key.launchAtLogin: false
        ])
        self.pollInterval = PollInterval(rawValue: defaults.integer(forKey: Key.pollInterval)) ?? .oneMinute
        self.showAgents = defaults.bool(forKey: Key.showAgents)
        self.showPullRequests = defaults.bool(forKey: Key.showPRs)
        self.alwaysOnTop = defaults.bool(forKey: Key.alwaysOnTop)
        self.launchAtLogin = defaults.bool(forKey: Key.launchAtLogin)
    }
}
