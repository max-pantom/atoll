// Focus timer: work/break presets, a thin progress ring around the island, optional Do Not Disturb via Shortcuts,
// and a session log in Application Support.
import SwiftUI
import AppKit

enum FocusPalette {
    static let indigo = Color(red: 0x5E / 255.0, green: 0x5C / 255.0, blue: 0xE6 / 255.0)   // #5E5CE6
}

struct FocusPreset: Identifiable, Equatable {
    let work: Int
    let rest: Int
    var id: String { "\(work)/\(rest)" }
    var title: String { "\(work)/\(rest)" }
    static let all = [FocusPreset(work: 25, rest: 5), FocusPreset(work: 50, rest: 10), FocusPreset(work: 90, rest: 15)]
}

@MainActor
@Observable
final class FocusActivity: IslandActivity {
    enum Phase { case idle, work, rest }

    static let shared = FocusActivity()

    let id = "focus"
    var priority: Int { 45 }

    private(set) var phase: Phase = .idle
    private(set) var paused = false
    /// Length of the current phase in seconds.
    private(set) var total: TimeInterval = 0
    /// Whole seconds left; changes once a second so numericText rolls cleanly.
    private(set) var seconds = 0
    /// 0...1 of the current phase elapsed (~5 Hz); drives the ring.
    private(set) var progress: Double = 0
    var customMinutes = 30

    @ObservationIgnored private var endDate: Date?
    @ObservationIgnored private var pausedRemaining: TimeInterval = 0
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var sessionStart: Date?
    @ObservationIgnored private var restMinutes = 5
    @ObservationIgnored private var workMinutes = 25
    @ObservationIgnored private var dndOn = false

    private init() {}

    // MARK: IslandActivity

    var isActive: Bool { phase != .idle }
    var tint: Color { phase == .rest ? AtollPalette.green : FocusPalette.indigo }
    var compactSideWidth: CGFloat {
        let chars = TimerActivity.format(max(Int(total.rounded(.up)), seconds)).count
        return max(62, CGFloat(chars) * 11 + 18)
    }
    var expandedHeight: CGFloat { phase == .idle ? 128 : 100 }

    func compactLeading() -> AnyView { AnyView(FocusLeading(activity: self).compactSlot(.leading, width: compactSideWidth)) }
    func compactTrailing() -> AnyView { AnyView(FocusTrailing(activity: self).compactSlot(.trailing, width: compactSideWidth)) }
    func minimal() -> AnyView { AnyView(FocusLeading(activity: self).minimalSlot()) }
    func expanded() -> AnyView { AnyView(FocusExpanded(activity: self).expandedSlot(height: expandedHeight)) }

    // MARK: Control

    func start(_ preset: FocusPreset) { start(work: preset.work, rest: preset.rest) }

    func start(customMinutes m: Int) { start(work: m, rest: max(1, Int((Double(m) / 5).rounded()))) }

    func start(work: Int, rest: Int) {
        guard work > 0, phase == .idle else { return }
        workMinutes = work
        restMinutes = rest
        sessionStart = Date()
        begin(.work, duration: TimeInterval(work * 60))
        FocusShortcuts.setFocus(true)
        dndOn = true
    }

    func togglePause() {
        if paused {
            endDate = Date().addingTimeInterval(pausedRemaining)
            paused = false
            startTicker()
        } else if let end = endDate {
            pausedRemaining = max(0, end.timeIntervalSinceNow)
            endDate = nil
            stopTicker()
            paused = true
        }
    }

    /// Ends the session early. A cancelled work phase is logged as not completed.
    func cancel() {
        if phase == .work { logSession(completed: false) }
        finishSession()
    }

    func skipRest() { if phase == .rest { finishSession() } }

    /// For `--demo`: show a session part-way through without touching Shortcuts or the log.
    func startDemo() {
        sessionStart = Date()
        phase = .work
        total = 25 * 60
        seconds = 17 * 60 + 42
        progress = 1 - Double(seconds) / total
    }

    private func begin(_ p: Phase, duration: TimeInterval) {
        phase = p
        paused = false
        total = duration
        endDate = Date().addingTimeInterval(duration)
        seconds = Int(duration.rounded(.up))
        progress = 0
        startTicker()
    }

    private func finishSession() {
        stopTicker()
        endDate = nil
        paused = false
        phase = .idle
        seconds = 0
        progress = 0
        if dndOn { FocusShortcuts.setFocus(false); dndOn = false }
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
        guard !paused, let end = endDate else { return }
        let remaining = end.timeIntervalSinceNow
        if remaining <= 0 { phaseEnded(); return }
        let whole = Int(remaining.rounded(.up))
        if whole != seconds { seconds = whole }
        progress = total > 0 ? min(1, max(0, 1 - remaining / total)) : 0
    }

    private func phaseEnded() {
        NSSound(named: NSSound.Name("Glass"))?.play()
        switch phase {
        case .work:
            logSession(completed: true)
            if dndOn { FocusShortcuts.setFocus(false); dndOn = false }
            ActivityCenter.shared.bloom(id, for: 4)
            if restMinutes > 0 { begin(.rest, duration: TimeInterval(restMinutes * 60)) } else { finishSession() }
        case .rest:
            ActivityCenter.shared.bloom(id, for: 3)
            finishSession()
        case .idle: break
        }
    }

    private func logSession(completed: Bool) {
        let start = sessionStart ?? Date()
        let elapsed = completed ? TimeInterval(workMinutes * 60) : Date().timeIntervalSince(start)
        guard elapsed >= 30 else { return }
        FocusLog.shared.add(FocusLog.Entry(date: start, seconds: Int(elapsed), completed: completed))
    }
}

// MARK: - Do Not Disturb through Shortcuts

/// Runs the user's "Atoll Focus On" / "Atoll Focus Off" shortcuts. Missing shortcuts are skipped silently.
@MainActor
@Observable
final class FocusShortcuts {
    static let shared = FocusShortcuts()
    /// nil until checked; Settings shows a hint when false.
    private(set) var installed: Bool?

    nonisolated static let onName = "Atoll Focus On"
    nonisolated static let offName = "Atoll Focus Off"
    nonisolated private static let exe = "/usr/bin/shortcuts"

    func refresh() {
        Task.detached(priority: .utility) {
            let names = Self.listNames()
            let ok = names.contains(Self.onName) && names.contains(Self.offName)
            await MainActor.run { FocusShortcuts.shared.installed = ok }
        }
    }

    static func setFocus(_ on: Bool) {
        let name = on ? onName : offName
        Task.detached(priority: .utility) {
            // Skip silently when the shortcut does not exist.
            guard listNames().contains(name) else { return }
            _ = run(["run", name])
        }
    }

    nonisolated private static func listNames() -> Set<String> {
        Set((run(["list"]) ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
    }

    nonisolated private static func run(_ args: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: exe) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Session log

@MainActor
@Observable
final class FocusLog {
    static let shared = FocusLog()

    struct Entry: Codable, Identifiable {
        var id = UUID()
        let date: Date
        let seconds: Int
        let completed: Bool
    }

    private(set) var entries: [Entry] = []

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Atoll", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("focus-log.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            entries = (try? dec.decode([Entry].self, from: data)) ?? []
        }
    }

    func add(_ entry: Entry) {
        entries.append(entry)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(entries) { try? data.write(to: Self.fileURL, options: .atomic) }
    }

    /// Seconds of focus time logged today (completed or not).
    var todaySeconds: Int {
        entries.filter { Calendar.current.isDateInToday($0.date) }.reduce(0) { $0 + $1.seconds }
    }
    var todayCompleted: Int { entries.filter { Calendar.current.isDateInToday($0.date) && $0.completed }.count }
}

// MARK: - Views

private struct FocusLeading: View {
    let activity: FocusActivity
    var body: some View {
        Image(systemName: activity.phase == .rest ? "cup.and.saucer.fill" : "scope")
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(activity.tint)
            .contentTransition(.symbolEffect(.replace))
    }
}

private struct FocusTrailing: View {
    let activity: FocusActivity
    var body: some View {
        Text(TimerActivity.format(activity.seconds))
            .font(.island(15))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(activity.tint)
            .opacity(activity.paused ? 0.55 : 1)
            .contentTransition(.numericText(countsDown: true))
            .animation(.smooth(duration: 0.25), value: activity.seconds)
            .animation(.smooth(duration: 0.2), value: activity.paused)
    }
}

private struct FocusExpanded: View {
    let activity: FocusActivity

    var body: some View {
        Group {
            if activity.phase == .idle { idle } else { running }
        }
        .animation(.smooth(duration: 0.25), value: activity.phase)
    }

    private var idle: some View {
        VStack(spacing: 10) {
            Text("Focus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
            HStack(spacing: 8) {
                ForEach(FocusPreset.all) { p in
                    ActivityChip(title: p.title, tint: FocusPalette.indigo) { activity.start(p) }
                }
            }
            HStack(spacing: 12) {
                Button { activity.customMinutes = max(1, activity.customMinutes - 5) } label: {
                    Image(systemName: "minus.circle.fill").font(.system(size: 22))
                }
                Text("\(activity.customMinutes) min")
                    .font(.island(16))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .frame(minWidth: 70)
                    .animation(.smooth(duration: 0.2), value: activity.customMinutes)
                Button { activity.customMinutes = min(240, activity.customMinutes + 5) } label: {
                    Image(systemName: "plus.circle.fill").font(.system(size: 22))
                }
                Button { activity.start(customMinutes: activity.customMinutes) } label: {
                    Text("Start")
                        .font(.island(14))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 30)
                        .background(Capsule(style: .continuous).fill(FocusPalette.indigo))
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
                    .foregroundStyle(activity.tint)
                    .opacity(activity.paused ? 0.55 : 1)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.smooth(duration: 0.25), value: activity.seconds)
                Text(activity.paused ? "Paused" : (activity.phase == .rest ? "Break" : "Focus"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 0)
            ActivityCircleButton(symbol: "xmark", fill: Color.white.opacity(0.18)) {
                activity.phase == .rest ? activity.skipRest() : activity.cancel()
            }
            ActivityCircleButton(symbol: activity.paused ? "play.fill" : "pause.fill", fill: activity.tint,
                                 glyph: activity.phase == .rest ? .black : .white) { activity.togglePause() }
        }
    }
}
