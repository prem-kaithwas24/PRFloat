import Foundation

/// Where the GitHub OAuth client ID comes from.
///
/// Device flow has no client secret, so the ID is safe to ship in the bundle. It is read
/// from `Info.plist` first, with a `UserDefaults` override so a user can paste their own
/// without rebuilding.
public enum ClientConfiguration {
    public static let overrideKey = "githubClientIDOverride"
    static let infoPlistKey = "PRFloatGitHubClientID"

    public static func clientID(
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard
    ) -> String {
        if let override = defaults.string(forKey: overrideKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return override
        }
        if let value = bundle.object(forInfoDictionaryKey: infoPlistKey) as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            // The checked-in placeholder must not be mistaken for a real ID.
            if !trimmed.isEmpty, !trimmed.hasPrefix("$(") {
                return trimmed
            }
        }
        return ""
    }

    public static func setOverride(_ value: String?, defaults: UserDefaults = .standard) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            defaults.set(trimmed, forKey: overrideKey)
        } else {
            defaults.removeObject(forKey: overrideKey)
        }
    }

    /// Shown in the sign-in view when no client ID is configured.
    public static let setupInstructions = """
    PR Float needs a GitHub OAuth app to sign in.

    1. Open github.com/settings/developers → New OAuth App
    2. Any name and homepage URL will do
    3. Tick "Enable Device Flow", then Register
    4. Paste the Client ID below
    """
}
