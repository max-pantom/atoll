import AppKit

@MainActor
enum Haptics {
    /// No-op unless the user has haptics on and the Mac has a Force Touch trackpad.
    static func tap(_ pattern: NSHapticFeedbackManager.FeedbackPattern = .alignment) {
        guard AtollSettings.shared.haptics else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}
