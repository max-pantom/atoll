import SwiftUI
import AppKit
import Observation

/// Accepts the first click so island buttons work while the panel is not key.
final class IslandHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the panel: positions it on the chosen screen, keeps it click-through outside the island
/// and feeds pointer position to the model (hover) through mouse monitors.
@MainActor
final class IslandWindowController {
    private let panel = IslandPanel()
    private let model = IslandModel.shared
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var dragTimer: Timer?

    func start() {
        let host = IslandHostingView(rootView: IslandView(model: model))
        host.sizingOptions = []
        let drop = IslandDropView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        host.frame = drop.bounds
        host.autoresizingMask = [.width, .height]
        drop.addSubview(host)
        panel.contentView = drop

        model.onLayoutChange = { [weak self] in self?.updateMouse() }
        model.start()
        reposition()
        applyPause()
        installMonitors()

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reposition() }
        })
        observeSettings()
    }

    func setPaused(_ paused: Bool) {
        model.isPaused = paused
        if paused { model.collapse() }
        applyPause()
    }

    private func applyPause() {
        if model.isPaused {
            panel.ignoresMouseEvents = true
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
            updateMouse()
        }
    }

    // MARK: Placement

    private func targetScreen() -> NSScreen? {
        let id = AtollSettings.shared.displayID
        if id != 0 {
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            if let match = NSScreen.screens.first(where: {
                ($0.deviceDescription[key] as? NSNumber)?.uint32Value == id
            }) { return match }
        }
        return NSScreen.screens.first ?? NSScreen.main
    }

    private func reposition() {
        guard let screen = targetScreen() else { return }
        let settings = AtollSettings.shared
        let s = CGFloat(settings.scale)
        let w = IslandMetrics.canvasWidth * s
        let h = IslandMetrics.canvasHeight * s
        let x = screen.frame.midX + CGFloat(settings.offsetX) - w / 2
        // Island top sits `offsetY` below the screen top; the canvas has `topInset` of room above it.
        let top = screen.frame.maxY - CGFloat(settings.offsetY) + IslandMetrics.topInset * s
        panel.setFrame(NSRect(x: x, y: top - h, width: w, height: h), display: true)
        updateMouse()
    }

    private func observeSettings() {
        withObservationTracking {
            let s = AtollSettings.shared
            _ = s.displayID
            _ = s.scale
            _ = s.offsetX
            _ = s.offsetY
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.reposition()
                self?.observeSettings()
            }
        }
    }

    // MARK: Pointer

    /// Screen-space rectangle of everything interactive.
    private func hitRect() -> NSRect {
        let s = CGFloat(AtollSettings.shared.scale)
        let e = model.hitExtent()
        let pad: CGFloat = 4
        let top = panel.frame.maxY - IslandMetrics.topInset * s
        // Extra reach above the screen makes the top edge easy to hit, unless a display sits above.
        let above: CGFloat = hasScreenAbove() ? 0 : 200
        return NSRect(
            x: panel.frame.midX - e.left * s - pad,
            y: top - e.height * s - pad,
            width: (e.left + e.right) * s + 2 * pad,
            height: e.height * s + pad + above
        )
    }

    private func hasScreenAbove() -> Bool {
        guard let screen = targetScreen() else { return false }
        return NSScreen.screens.contains { other in
            other !== screen
                && abs(other.frame.minY - screen.frame.maxY) < 1
                && other.frame.maxX > screen.frame.minX && other.frame.minX < screen.frame.maxX
        }
    }

    /// While a button is held (e.g. a Finder file drag) poll the pointer, since move events may not arrive.
    private func handleDragEvent(_ type: NSEvent.EventType) {
        switch type {
        case .leftMouseDragged:
            guard dragTimer == nil else { return }
            dragTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if NSEvent.pressedMouseButtons == 0 { self.stopDragPolling() }
                    self.updateMouse()
                }
            }
        case .leftMouseUp:
            stopDragPolling()
        default: break
        }
    }

    private func stopDragPolling() {
        dragTimer?.invalidate()
        dragTimer = nil
    }

    private func updateMouse() {
        let inside = !model.isPaused && hitRect().contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        model.setHovering(inside)
    }

    private func installMonitors() {
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .leftMouseUp]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] event in
            let type = event.type
            Task { @MainActor in
                self?.updateMouse()
                self?.handleDragEvent(type)
            }
        }) { monitors.append(g) }

        // Presses that reach the global monitor landed outside our (click-through) panel.
        let downs: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: downs, handler: { [weak self] _ in
            Task { @MainActor in self?.model.outsideClick() }
        }) { monitors.append(g) }

        if let l = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] event in
            Task { @MainActor in self?.updateMouse() }
            return event
        }) { monitors.append(l) }
    }
}
