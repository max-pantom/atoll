import SwiftUI
import AppKit
import Observation

/// Owns the panel: positions it on the chosen screen, keeps it click-through outside the island
/// and feeds pointer position to the model (hover) through mouse monitors.
@MainActor
final class IslandWindowController {
    private let panel = IslandPanel()
    private let model = IslandModel.shared
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []

    func start() {
        let host = NSHostingView(rootView: IslandView(model: model))
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
        return NSRect(
            x: panel.frame.midX - e.left * s - pad,
            y: top - e.height * s - pad,
            width: (e.left + e.right) * s + 2 * pad,
            height: e.height * s + pad + 200   // extends above the screen so the top edge is easy to hit
        )
    }

    private func updateMouse() {
        let inside = !model.isPaused && hitRect().contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        model.setHovering(inside)
    }

    private func installMonitors() {
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .leftMouseUp]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in
            Task { @MainActor in self?.updateMouse() }
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
