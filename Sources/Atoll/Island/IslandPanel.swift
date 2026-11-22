import AppKit

/// Borderless, non-activating, transparent panel that floats above the menu bar on every Space.
final class IslandPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { IslandModel.shared.layout.presentation == .expanded }
    override var canBecomeMain: Bool { false }

    /// The island sits partly above the screen edge; never let AppKit push it down.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Container view that accepts file drags and hands them to the shelf.
final class IslandDropView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func shelfAvailable() -> Bool {
        ActivityCenter.shared.activities.contains { $0.id == "shelf" }
            && AtollSettings.shared.isEnabled("shelf")
    }

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard shelfAvailable(), !fileURLs(sender).isEmpty else { return [] }
        IslandModel.shared.dragEntered()
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard shelfAvailable() else { return [] }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        IslandModel.shared.dragExited()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { shelfAvailable() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return false }
        ShelfActivity.shared.accept(urls: urls)
        IslandModel.shared.dragDropped()
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        IslandModel.shared.dragDropped()
    }
}
