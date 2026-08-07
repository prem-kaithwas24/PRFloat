import AppKit
import Testing
@testable import PRFloatCore

/// Regression cover for the launch failure fixed in 9e2cd21: AppKit raises on
/// contradictory collection behavior, and because the panel is built during
/// `applicationDidFinishLaunching` the raise unwinds the whole launch and leaves a
/// running app with no visible UI. These assertions turn that into a test failure.
@Suite("Floating panel behavior")
struct PanelBehaviorTests {
    @Test("Shipping collection behavior is one AppKit accepts")
    func shippingBehaviorIsValid() {
        #expect(PanelBehavior.invalidPairReason(PanelBehavior.collectionBehavior) == nil)
    }

    @Test("Panel stays visible across spaces and over full-screen apps")
    func shippingBehaviorKeepsPanelVisible() {
        #expect(PanelBehavior.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(PanelBehavior.collectionBehavior.contains(.fullScreenAuxiliary))
    }

    @Test("Rejects canJoinAllSpaces combined with moveToActiveSpace")
    func detectsMutuallyExclusivePair() {
        let reason = PanelBehavior.invalidPairReason([.canJoinAllSpaces, .moveToActiveSpace])
        #expect(reason == "window behavior cannot be both canJoinAllSpaces and moveToActiveSpace")
    }

    @Test("Accepts combinations AppKit permits", arguments: [
        NSWindow.CollectionBehavior([.canJoinAllSpaces, .fullScreenAuxiliary]),
        NSWindow.CollectionBehavior([.moveToActiveSpace, .fullScreenAuxiliary]),
        NSWindow.CollectionBehavior([.managed, .participatesInCycle]),
        NSWindow.CollectionBehavior()
    ])
    func acceptsValidCombinations(_ behavior: NSWindow.CollectionBehavior) {
        #expect(PanelBehavior.invalidPairReason(behavior) == nil)
    }
}
