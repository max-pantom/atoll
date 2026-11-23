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

        V02ASupport.runDemo()   // `--demo=clipboard|capture|downloads`

        // `--demo`: start a 5-minute timer and bloom it (used by CI screenshots).
        if CommandLine.arguments.contains("--demo") {
            TimerActivity.shared.start(minutes: 5)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                ActivityCenter.shared.bloom(TimerActivity.shared.id, for: 8)
            }
        }
        FeatureDemo.run(CommandLine.arguments)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { TerminalPingActivity.handle(url) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NowPlayingActivity.shared.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func togglePause() {
        let paused = !(statusItem?.paused ?? false)
        statusItem?.setPaused(paused)
        island?.setPaused(paused)
    }
}
