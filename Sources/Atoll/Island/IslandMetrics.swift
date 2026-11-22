import SwiftUI

/// Sizes in logical points (before `AtollSettings.scale`, which the view applies to the whole island).
/// Sources and estimates: plans/RESEARCH.md §2.
enum IslandMetrics {
    /// Idle / compact height (iPhone 14 Pro pill, community measurement).
    static let height: CGFloat = 37.33
    static let bubbleSize: CGFloat = 36.67
    static let bubbleGap: CGFloat = 8
    /// Space between the outer edge of a compact side and its content.
    static let compactInset: CGFloat = 10
    static let expandedRadius: CGFloat = 44
    static let expandedInsetV: CGFloat = 16
    static let expandedInsetH: CGFloat = 20
    /// Content height of the idle "Nothing playing" card.
    static let idleCardHeight: CGFloat = 92

    /// The panel's logical canvas. The panel is fixed at this size (times scale).
    static let canvasWidth: CGFloat = 620
    static let canvasHeight: CGFloat = 300
    /// Room above the island inside the canvas so blur and shadows are not clipped at the screen edge.
    static let topInset: CGFloat = 24
    static let maxExpandedWidth: CGFloat = 560
    static let maxExpandedHeight: CGFloat = canvasHeight - topInset - 40

    static func idleWidth(_ style: IslandStyle) -> CGFloat {
        style == .modern ? 126 : 82
    }

    static func compactWidth(style: IslandStyle, side: CGFloat) -> CGFloat {
        idleWidth(style) + 2 * (side + compactInset)
    }

    static func defaultExpandedWidth(scale: Double) -> CGFloat {
        scale >= 1.1 ? 408 : 371
    }
}
