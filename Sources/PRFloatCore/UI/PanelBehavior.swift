import AppKit

/// Window collection behavior for the floating panel.
///
/// AppKit validates collection behavior in `-[NSWindow _validateCollectionBehavior:]`
/// and raises `NSInternalInconsistencyException` for contradictory flags. The panel is
/// built inside `applicationDidFinishLaunching`, so that exception unwinds the entire
/// launch path — the panel never gets ordered front and the status item never renders —
/// while AppKit swallows it and keeps the run loop alive. The result is a running process
/// with no visible UI, which reads to a user as "the app didn't launch".
///
/// Keeping the value here, with `invalidPairReason` next to it, means a contradictory
/// combination fails a test run instead of a launch.
public enum PanelBehavior {
    /// Panel follows the user across spaces and stays available over full-screen apps.
    public static let collectionBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces,
        .fullScreenAuxiliary
    ]

    /// Flag pairs AppKit rejects. Verified empirically against macOS 26.4: of the
    /// combinations that look mutually exclusive in the headers, only this one raises.
    /// (`managed`/`transient`/`stationary`, `participatesInCycle`/`ignoresCycle`, and the
    /// `fullScreen*` flags are all accepted, so asserting on them would be wrong.)
    static let exclusivePairs: [(NSWindow.CollectionBehavior, NSWindow.CollectionBehavior, String)] = [
        (.canJoinAllSpaces, .moveToActiveSpace, "canJoinAllSpaces and moveToActiveSpace")
    ]

    /// Describes why `behavior` would make AppKit raise, or `nil` when it is safe to assign.
    public static func invalidPairReason(
        _ behavior: NSWindow.CollectionBehavior
    ) -> String? {
        for (a, b, label) in exclusivePairs where behavior.contains(a) && behavior.contains(b) {
            return "window behavior cannot be both \(label)"
        }
        return nil
    }
}
