// Registers every activity into ActivityCenter and starts their system listeners.
import SwiftUI

@MainActor
enum Activities {
    private static var registered = false

    /// Called once by the shell at launch.
    static func registerAll() {
        guard !registered else { return }
        registered = true
        let center = ActivityCenter.shared
        center.register(HUDActivity.volume)
        center.register(HUDActivity.brightness)
        center.register(BatteryActivity.shared)
        center.register(NowPlayingActivity.shared)
        center.register(TimerActivity.shared)
        center.register(ShelfActivity.shared)
        center.register(CalendarActivity.shared)
        center.register(ClipboardActivity.shared)
        center.register(QuickCaptureActivity.shared)
        center.register(DownloadsActivity.shared)
        V02ASupport.seedDefaults()

        HUDActivity.startMonitoring()
        BatteryActivity.shared.start()
        NowPlayingActivity.shared.start()
        CalendarActivity.shared.start()
        ClipboardActivity.shared.start()
        QuickCaptureActivity.shared.start()
        DownloadsActivity.shared.start()
    }

    /// Height of `idleCard()`; the shell uses it when the island expands with nothing active.
    static var idleExpandedHeight: CGFloat { 92 }

    /// "Nothing playing" + timer presets, shown when the island is expanded while idle.
    static func idleCard() -> AnyView { AnyView(IdleCard()) }
}

private struct IdleCard: View {
    var body: some View {
        VStack(spacing: 12) {
            Label("Nothing Playing", systemImage: "music.note")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
            TimerPresetsRow()
        }
        .expandedSlot(height: Activities.idleExpandedHeight)
    }
}
