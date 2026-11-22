import SwiftUI
import AppKit
import Observation

/// State machine behind the island: what to show (idle / compact / minimal / expanded),
/// when to expand (hover delay, click, long press, bloom, file drag) and how the change is staged
/// (content blurs out, shape springs, content blurs in).
@MainActor
@Observable
final class IslandModel {
    static let shared = IslandModel()

    /// Everything the view needs to draw one frame of the island.
    struct Layout: Equatable {
        var presentation: IslandPresentation = .idle
        /// Activity shown compact or expanded. nil while expanded = idle card.
        var primaryID: String? = nil
        /// Detached minimal bubbles (iPhone 18 Pro style allows up to two next to the compact one).
        var bubbleIDs: [String] = []
        var width: CGFloat = 126
        var height: CGFloat = IslandMetrics.height
        var radius: CGFloat = IslandMetrics.height / 2
        var hidden = false

        /// Changes when the content inside the island must be swapped (not when only bubbles change).
        var contentKey: String {
            switch presentation {
            case .expanded: return "x:" + (primaryID ?? "idle")
            case .idle: return "idle"
            case .compact, .minimal: return "c:" + (primaryID ?? "")
            }
        }
    }

    // MARK: Observed by the view

    private(set) var layout = Layout()
    private(set) var contentVisible = true
    private(set) var isPressed = false
    var isPaused = false { didSet { onLayoutChange?() } }

    // MARK: Internal state

    @ObservationIgnored private(set) var target = Layout()
    @ObservationIgnored private(set) var isHovering = false
    @ObservationIgnored private var userExpanded = false
    @ObservationIgnored private var pinnedID: String?
    @ObservationIgnored private var isDragTarget = false
    @ObservationIgnored private var lastBloomID: String?
    @ObservationIgnored private var lastBloomToken = 0
    @ObservationIgnored private var longPressFired = false
    @ObservationIgnored private var hoverTask: Task<Void, Never>?
    @ObservationIgnored private var collapseTask: Task<Void, Never>?
    @ObservationIgnored private var longPressTask: Task<Void, Never>?
    @ObservationIgnored private var transitionTask: Task<Void, Never>?
    @ObservationIgnored private var started = false
    /// Called after the target layout changes so the window controller can refresh hit-testing.
    @ObservationIgnored var onLayoutChange: (@MainActor () -> Void)?

    private init() {}

    var reduceMotion: Bool {
        AtollSettings.shared.reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    func activity(_ id: String) -> (any IslandActivity)? {
        ActivityCenter.shared.activities.first { $0.id == id }
    }

    func start() {
        guard !started else { return }
        started = true
        let first = targetLayout()
        target = first
        layout = first
        lastBloomToken = ActivityCenter.shared.bloomToken
        lastBloomID = ActivityCenter.shared.bloomingID
        observe()
    }

    // MARK: Observation of activities and settings

    private func observe() {
        withObservationTracking {
            let center = ActivityCenter.shared
            _ = center.bloomToken
            _ = center.bloomingID
            _ = targetLayout()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.externalChange()
                self.observe()
            }
        }
    }

    private func externalChange() {
        let center = ActivityCenter.shared
        if center.bloomToken != lastBloomToken {
            lastBloomToken = center.bloomToken
            if center.bloomingID != nil {
                collapseTask?.cancel()
                Haptics.tap(.levelChange)
            }
        }
        recompute()
    }

    // MARK: Layout

    private func targetLayout() -> Layout {
        let center = ActivityCenter.shared
        let settings = AtollSettings.shared
        let active = center.active
        let bloom = center.bloomingID.flatMap { settings.isEnabled($0) ? $0 : nil }
        var l = Layout()

        if userExpanded || isDragTarget || bloom != nil {
            let pinned = pinnedID.flatMap { id in
                (id == "shelf" || active.contains { $0.id == id }) ? id : nil
            }
            let id: String? = isDragTarget ? "shelf" : (bloom ?? pinned ?? active.first?.id)
            l.presentation = .expanded
            l.radius = IslandMetrics.expandedRadius
            if let id, let act = activity(id) {
                l.primaryID = id
                l.width = min(act.expandedWidth ?? IslandMetrics.defaultExpandedWidth(scale: settings.scale),
                              IslandMetrics.maxExpandedWidth)
                l.height = min(act.expandedHeight + 2 * IslandMetrics.expandedInsetV,
                               IslandMetrics.maxExpandedHeight)
            } else {
                l.primaryID = nil
                l.width = IslandMetrics.defaultExpandedWidth(scale: settings.scale)
                l.height = IslandMetrics.idleCardHeight + 2 * IslandMetrics.expandedInsetV
            }
            return l
        }

        guard let top = active.first else {
            l.width = IslandMetrics.idleWidth(settings.style)
            l.hidden = settings.hideIdlePill
            return l
        }
        l.primaryID = top.id
        l.bubbleIDs = active.dropFirst().prefix(2).map { $0.id }
        l.presentation = l.bubbleIDs.isEmpty ? .compact : .minimal
        l.width = IslandMetrics.compactWidth(style: settings.style, side: top.compactSideWidth)
        return l
    }

    private func recompute() {
        let center = ActivityCenter.shared
        // A bloom that ends while the pointer is on the island stays open until the pointer leaves.
        if let last = lastBloomID, center.bloomingID == nil, isHovering {
            userExpanded = true
            pinnedID = last
        }
        lastBloomID = center.bloomingID
        apply(targetLayout())
    }

    private func shapeAnimation(from old: Layout, to new: Layout) -> Animation {
        if new.presentation == .expanded { return IslandMotion.expand }
        if old.presentation == .expanded { return IslandMotion.collapse }
        return IslandMotion.resize
    }

    private func apply(_ new: Layout) {
        target = new
        onLayoutChange?()
        transitionTask?.cancel()

        if new == layout {
            if !contentVisible { withAnimation(IslandMotion.contentIn) { contentVisible = true } }
            return
        }
        let old = layout
        if reduceMotion {
            withAnimation(.easeInOut(duration: 0.2)) {
                layout = new
                contentVisible = true
            }
            return
        }

        let shrinking = new.height < old.height - 0.5 || new.width < old.width - 0.5
        let keyChanged = new.contentKey != old.contentKey
        let animation = shapeAnimation(from: old, to: new)

        if shrinking && keyChanged && contentVisible {
            // Content blurs out first, then the shape shrinks and the new content blurs in.
            withAnimation(IslandMotion.contentOut) { contentVisible = false }
            transitionTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled, let self else { return }
                withAnimation(animation) {
                    self.layout = self.target
                    self.contentVisible = true
                }
            }
        } else {
            withAnimation(animation) {
                layout = new
                contentVisible = true
            }
        }
    }

    // MARK: Expand / collapse

    func expand(id: String? = nil, haptic: Bool = true) {
        collapseTask?.cancel()
        hoverTask?.cancel()
        if haptic && target.presentation != .expanded { Haptics.tap(.levelChange) }
        userExpanded = true
        pinnedID = id
        recompute()
    }

    func collapse() {
        collapseTask?.cancel()
        hoverTask?.cancel()
        userExpanded = false
        pinnedID = nil
        recompute()
    }

    private func scheduleCollapse() {
        collapseTask?.cancel()
        collapseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self, !self.isHovering, !self.isDragTarget else { return }
            self.collapse()
        }
    }

    /// A mouse press landed outside the island (reported by the global monitor).
    func outsideClick() {
        if target.presentation == .expanded && !isDragTarget { collapse() }
    }

    // MARK: Pointer

    func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        hoverTask?.cancel()
        if hovering {
            collapseTask?.cancel()
            guard !userExpanded, AtollSettings.shared.trigger == .hover, !isPaused else { return }
            let delay = UInt64(max(0, AtollSettings.shared.hoverDelay) * 1_000_000_000)
            hoverTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: delay)
                // Skip while a button is down: the pointer is dragging something past the island.
                guard !Task.isCancelled, let self, self.isHovering, NSEvent.pressedMouseButtons == 0 else { return }
                self.expand()
            }
        } else if userExpanded && !isDragTarget {
            scheduleCollapse()
        }
    }

    func pressBegan() {
        guard !isPressed, target.presentation != .expanded else { return }
        isPressed = true
        longPressFired = false
        longPressTask?.cancel()
        longPressTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(IslandMotion.longPress * 1_000_000_000))
            guard !Task.isCancelled, let self, self.isPressed else { return }
            self.longPressFired = true
            self.isPressed = false
            self.expand()
        }
    }

    func pressEnded(distance: CGFloat) {
        longPressTask?.cancel()
        let wasPressed = isPressed
        isPressed = false
        if wasPressed && !longPressFired && distance < 8 && target.presentation != .expanded {
            expand()
        }
        longPressFired = false
    }

    /// Tap on a detached bubble: expand that activity.
    func tapBubble(_ id: String) {
        expand(id: id)
    }

    // MARK: File drag and drop

    func dragEntered() {
        collapseTask?.cancel()
        hoverTask?.cancel()
        guard !isDragTarget else { return }
        isDragTarget = true
        ShelfActivity.shared.isDragTarget = true
        Haptics.tap(.alignment)
        recompute()
    }

    func dragExited() {
        guard isDragTarget else { return }
        isDragTarget = false
        ShelfActivity.shared.isDragTarget = false
        // Keep the shelf open for the grace period, then collapse.
        userExpanded = true
        pinnedID = "shelf"
        recompute()
        scheduleCollapse()
    }

    func dragDropped() {
        guard isDragTarget else { return }
        isDragTarget = false
        ShelfActivity.shared.isDragTarget = false
        userExpanded = true
        pinnedID = "shelf"
        recompute()
    }

    // MARK: Hit testing

    /// Extents of everything interactive, in logical points: distance from the island centre to the
    /// left edge, to the right edge (bubbles included) and the height below the island top.
    func hitExtent() -> (left: CGFloat, right: CGFloat, height: CGFloat) {
        let half = target.width / 2
        var right = half
        if target.presentation == .minimal {
            right += CGFloat(target.bubbleIDs.count) * (IslandMetrics.bubbleSize + IslandMetrics.bubbleGap)
        }
        return (half, right, max(target.height, IslandMetrics.height))
    }
}
