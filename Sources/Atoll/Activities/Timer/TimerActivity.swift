// Timer: orange glyph + numericText countdown, presets, pause/resume/cancel, bloom on finish.
import SwiftUI
import AppKit

@MainActor
@Observable
final class TimerActivity: IslandActivity {
    enum Phase { case idle, running, paused, finished }

    static let shared = TimerActivity()

    let id = "timer"
    let priority = 40

    private(set) var phase: Phase = .idle
    private(set) var total: TimeInterval = 0
    /// Whole seconds shown on screen; only changes once a second so numericText rolls cleanly.
    private(set) var seconds = 0
    var customMinutes = 15

    @ObservationIgnored private var endDate: Date?
    @ObservationIgnored private var pausedRemaining: TimeInterval = 0
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var resetTask: Task<Void, Never>?

    private init() {}

    // MARK: IslandActivity

    var isActive: Bool { phase != .idle }
    var tint: Color { AtollPalette.orange }
    var compactSideWidth: CGFloat { 58 }
    var expandedHeight: CGFloat { phase == .idle ? 128 : 100 }

    func compactLeading() -> AnyView { AnyView(TimerLeading(activity: self).compactSlot(.leading, width: compactSideWidth)) }
    func compactTrailing() -> AnyView { AnyView(TimerTrailing(activity: self).compactSlot(.trailing, width: compactSideWidth)) }
    func minimal() -> AnyView { AnyView(TimerLeading(activity: self).minimalSlot()) }
    func expanded() -> AnyView { AnyView(TimerExpanded(activity: self).expandedSlot(height: expandedHeight)) }

    // MARK: Control

    func start(minutes: Int) { start(seconds: TimeInterval(minutes * 60)) }

    func start(seconds duration: TimeInterval) {
        guard duration > 0 else { return }
        resetTask?.cancel()
        total = duration
        endDate = Date().addingTimeInterval(duration)
        seconds = Int(duration.rounded(.up))
        phase = .running
        startTicker()
    }

    func pause() {
        guard phase == .running, let end = endDate else { return }
        pausedRemaining = max(0, end.timeIntervalSinceNow)
        endDate = nil
        stopTicker()
        phase = .paused
    }

    func resume() {
        guard phase == .paused else { return }
        endDate = Date().addingTimeInterval(pausedRemaining)
        phase = .running
        startTicker()
    }

    func togglePause() { phase == .running ? pause() : resume() }

    func cancel() {
        resetTask?.cancel()
        stopTicker()
        endDate = nil
        phase = .idle
        seconds = 0
    }

    private func startTicker() {
        stopTicker()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(ticker!, forMode: .common)
    }

    private func stopTicker() { ticker?.invalidate(); ticker = nil }

    private func tick() {
        guard phase == .running, let end = endDate else { return }
        let remaining = end.timeIntervalSinceNow
        if remaining <= 0 { finish(); return }
        let whole = Int(remaining.rounded(.up))
        if whole != seconds { seconds = whole }
    }

    private func finish() {
        stopTicker()
        endDate = nil
        seconds = 0
        phase = .finished
        NSSound(named: NSSound.Name("Glass"))?.play()
        ActivityCenter.shared.bloom(id, for: 4)
        resetTask?.cancel()
        resetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            if self?.phase == .finished { self?.cancel() }
        }
    }

    static func format(_ s: Int) -> String {
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

// MARK: - Views

private struct TimerLeading: View {
    let activity: TimerActivity
    var body: some View {
        Image(systemName: "timer")
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(AtollPalette.orange)
            .symbolEffect(.pulse, isActive: activity.phase == .finished)
    }
}

private struct TimerTrailing: View {
    let activity: TimerActivity
    var body: some View {
        Text(TimerActivity.format(activity.seconds))
            .font(.island(15))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(AtollPalette.orange)
            .opacity(activity.phase == .paused ? 0.55 : 1)
            .contentTransition(.numericText(countsDown: true))
            .animation(.smooth(duration: 0.25), value: activity.seconds)
            .animation(.smooth(duration: 0.2), value: activity.phase)
    }
}

/// Preset row (1, 5, 10, 25 min), shared with the idle card.
struct TimerPresetsRow: View {
    var body: some View {
        HStack(spacing: 8) {
            ForEach([1, 5, 10, 25], id: \.self) { m in
                ActivityChip(title: "\(m) min") { TimerActivity.shared.start(minutes: m) }
            }
        }
    }
}

private struct TimerExpanded: View {
    let activity: TimerActivity

    var body: some View {
        Group {
            switch activity.phase {
            case .idle: idle
            case .running, .paused: running
            case .finished: finished
            }
        }
        .animation(.smooth(duration: 0.25), value: activity.phase)
    }

    private var idle: some View {
        VStack(spacing: 10) {
            Text("Timer")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
            TimerPresetsRow()
            HStack(spacing: 12) {
                Button { activity.customMinutes = max(1, activity.customMinutes - 1) } label: {
                    Image(systemName: "minus.circle.fill").font(.system(size: 22))
                }
                Text("\(activity.customMinutes) min")
                    .font(.island(16))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .frame(minWidth: 70)
                    .animation(.smooth(duration: 0.2), value: activity.customMinutes)
                Button { activity.customMinutes = min(180, activity.customMinutes + 1) } label: {
                    Image(systemName: "plus.circle.fill").font(.system(size: 22))
                }
                Button { activity.start(minutes: activity.customMinutes) } label: {
                    Text("Start")
                        .font(.island(14))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 16)
                        .frame(height: 30)
                        .background(Capsule(style: .continuous).fill(AtollPalette.orange))
                }
            }
            .buttonStyle(ActivityPressStyle())
            .foregroundStyle(.white.opacity(0.7))
        }
    }

    private var running: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                Text(TimerActivity.format(activity.seconds))
                    .font(.island(46))
                    .monospacedDigit()
                    .foregroundStyle(AtollPalette.orange)
                    .opacity(activity.phase == .paused ? 0.55 : 1)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.smooth(duration: 0.25), value: activity.seconds)
                Text(activity.phase == .paused ? "Paused" : "Timer")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 0)
            ActivityCircleButton(symbol: "xmark", fill: Color.white.opacity(0.18)) { activity.cancel() }
            ActivityCircleButton(symbol: activity.phase == .paused ? "play.fill" : "pause.fill",
                                 fill: AtollPalette.orange, glyph: .black) { activity.togglePause() }
        }
    }

    private var finished: some View {
        HStack(spacing: 14) {
            Image(systemName: "timer")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(AtollPalette.orange)
                .symbolEffect(.pulse)
            VStack(alignment: .leading, spacing: 0) {
                Text("Time's Up")
                    .font(.island(24))
                Text(TimerActivity.format(Int(activity.total)))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 0)
            ActivityCircleButton(symbol: "checkmark", fill: AtollPalette.orange, glyph: .black) { activity.cancel() }
        }
    }
}
