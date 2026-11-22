import AppKit

@main
struct AtollApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var island: IslandWindowController?
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Activities.registerAll()

        let island = IslandWindowController()
        self.island = island
        island.start()

        statusItem = StatusItemController(
            onSettings: {
                NSApp.activate()
                SettingsWindow.show()
            },
            onTogglePause: { [weak self] in self?.togglePause() }
        )
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func togglePause() {
        let paused = !(statusItem?.paused ?? false)
        statusItem?.setPaused(paused)
        island?.setPaused(paused)
    }
}
