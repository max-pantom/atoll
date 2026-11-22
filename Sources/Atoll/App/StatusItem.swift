import AppKit

/// Menu bar item: Settings…, Pause island, Quit.
@MainActor
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let pauseItem = NSMenuItem()
    private let onSettings: () -> Void
    private let onTogglePause: () -> Void
    private(set) var paused = false

    init(onSettings: @escaping () -> Void, onTogglePause: @escaping () -> Void) {
        self.onSettings = onSettings
        self.onTogglePause = onTogglePause
        super.init()

        if let button = item.button {
            let image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Atoll")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Atoll"
        }

        let menu = NSMenu()
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        pauseItem.action = #selector(togglePause)
        pauseItem.target = self
        menu.addItem(pauseItem)
        setPaused(false)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Atoll", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
    }

    func setPaused(_ paused: Bool) {
        self.paused = paused
        pauseItem.title = paused ? "Resume island" : "Pause island"
        pauseItem.state = paused ? .on : .off
    }

    @objc private func openSettings() { onSettings() }
    @objc private func togglePause() { onTogglePause() }
    @objc private func quit() { NSApp.terminate(nil) }
}
