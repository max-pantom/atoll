// Live meeting bar: mic/camera dots, current meeting with time left and a mute toggle, and a 2-minute heads-up
// before the next calendar event. Calendar data is read only if Calendar access was already granted (the Calendar
// activity owns the permission prompt), so this feature never prompts by itself.
import SwiftUI
import AppKit
import EventKit

@MainActor
@Observable
final class MeetingActivity: IslandActivity {
    struct Entry: Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let joinURL: URL?
    }

    static let shared = MeetingActivity()

    let id = "meeting"
    /// Heads-up pops above most things; the live bar itself stays below now playing (the dot overlay covers that case).
    var priority: Int { headsUp != nil ? 70 : 30 }

    private(set) var micOn = false
    private(set) var cameraOn = false
    private(set) var muted = false
    /// Ongoing event, if any.
    private(set) var current: Entry?
    /// Event starting within 2 minutes that the user has not been told about yet.
    private(set) var headsUp: Entry?
    private(set) var now = Date()

    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var cached: [Entry] = []
    @ObservationIgnored private var lastFetch = Date.distantPast
    @ObservationIgnored private var alerted = Set<String>()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var demo = false
    @ObservationIgnored private let queue = DispatchQueue(label: "cc.primitive8.atoll.meeting", qos: .utility)

    private init() {}

    // MARK: IslandActivity

    var isActive: Bool { micOn || cameraOn || headsUp != nil }
    var tint: Color { cameraOn ? AtollPalette.green : (micOn ? AtollPalette.orange : AtollPalette.green) }
    var compactSideWidth: CGFloat { 62 }
    var expandedHeight: CGFloat { 100 }

    func compactLeading() -> AnyView { AnyView(MeetingLeading(activity: self).compactSlot(.leading, width: compactSideWidth)) }
    func compactTrailing() -> AnyView { AnyView(MeetingTrailing(activity: self).compactSlot(.trailing, width: compactSideWidth)) }
    func minimal() -> AnyView { AnyView(MeetingLeading(activity: self).minimalSlot()) }
    func expanded() -> AnyView { AnyView(MeetingExpanded(activity: self).expandedSlot(height: expandedHeight)) }

    /// Which dot to draw on the compact island (camera wins, like macOS).
    var indicatorColor: Color? { cameraOn ? AtollPalette.green : (micOn ? AtollPalette.orange : nil) }

    // MARK: Monitoring

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        poll()
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func poll() {
        guard !demo else { return }
        now = Date()
        guard AtollSettings.shared.isEnabled(id) else {
            micOn = false; cameraOn = false; current = nil; headsUp = nil
            return
        }
        // Device checks are cheap but go through CoreAudio/CoreMediaIO; keep them off the main thread.
        queue.async { [weak self] in
            let mic = DeviceMonitor.micInUse()
            let cam = DeviceMonitor.cameraInUse()
            let muted = mic ? DeviceMonitor.isInputMuted() : false
            Task { @MainActor in
                guard let self, !self.demo else { return }
                if self.micOn != mic { self.micOn = mic }
                if self.cameraOn != cam { self.cameraOn = cam }
                if self.muted != muted { self.muted = muted }
            }
        }
        if now.timeIntervalSince(lastFetch) > 15 { lastFetch = now; refreshEvents() }
        derive()
    }

    private func refreshEvents() {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { cached = []; return }
        let n = Date()
        let predicate = store.predicateForEvents(withStart: n.addingTimeInterval(-6 * 3600), end: n.addingTimeInterval(600), calendars: nil)
        cached = store.events(matching: predicate)
            .filter { e in
                guard !e.isAllDay, e.status != .canceled, e.endDate > n else { return false }
                return e.attendees?.first(where: { $0.isCurrentUser })?.participantStatus != .declined
            }
            .sorted { $0.startDate < $1.startDate }
            .map { e in
                Entry(id: e.eventIdentifier ?? UUID().uuidString,
                      title: (e.title?.isEmpty == false ? e.title : nil) ?? "Meeting",
                      start: e.startDate, end: e.endDate,
                      joinURL: CalendarActivity.joinURL(in: [e.url?.absoluteString, e.location, e.notes]))
            }
    }

    private func derive() {
        let n = now
        let cur = cached.first { $0.start <= n && $0.end > n }
        if cur != current { current = cur }

        // Heads-up: next event starting in (0, 120] s, announced once.
        if let next = cached.first(where: { $0.start > n && $0.start.timeIntervalSince(n) <= 120 }), !alerted.contains(next.id) {
            alerted.insert(next.id)
            headsUp = next
            ActivityCenter.shared.bloom(id, for: 8)
        }
        if let h = headsUp, n > h.start.addingTimeInterval(60) { headsUp = nil }
    }

    // MARK: Actions

    func toggleMute() {
        let target = !muted
        queue.async {
            DeviceMonitor.setInputMuted(target)
            let actual = DeviceMonitor.isInputMuted()
            Task { @MainActor in MeetingActivity.shared.muted = actual }
        }
        muted = target
    }

    func join(_ e: Entry) {
        if let url = e.joinURL { NSWorkspace.shared.open(url) }
        headsUp = nil
    }

    func dismissHeadsUp() { headsUp = nil }

    // MARK: Demo

    /// `--demo`: fake a call in progress so CI can screenshot the bar without hardware or calendar access.
    func startDemo() {
        demo = true
        let n = Date()
        micOn = true
        cameraOn = true
        muted = false
        now = n
        current = Entry(id: "demo", title: "Design Review", start: n.addingTimeInterval(-6 * 60), end: n.addingTimeInterval(24 * 60), joinURL: nil)
    }

    var timeLeftLabel: String {
        guard let e = current else { return "" }
        let m = max(0, Int(ceil(e.end.timeIntervalSince(now) / 60)))
        return m >= 60 ? "\(m / 60)h \(m % 60)m left" : "\(m)m left"
    }

    var headsUpLabel: String {
        guard let h = headsUp else { return "" }
        let m = max(1, Int(ceil(h.start.timeIntervalSince(now) / 60)))
        return "in \(m)m"
    }
}

// MARK: - Views

private struct MeetingLeading: View {
    let activity: MeetingActivity
    var body: some View {
        if activity.headsUp != nil && !(activity.micOn || activity.cameraOn) {
            Image(systemName: "video.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(AtollPalette.green)
        } else {
            HStack(spacing: 5) {
                if activity.micOn { Circle().fill(AtollPalette.orange).frame(width: 10, height: 10) }
                if activity.cameraOn { Circle().fill(AtollPalette.green).frame(width: 10, height: 10) }
            }
            .animation(.smooth(duration: 0.25), value: activity.micOn)
            .animation(.smooth(duration: 0.25), value: activity.cameraOn)
        }
    }
}

private struct MeetingTrailing: View {
    let activity: MeetingActivity
    var body: some View {
        Group {
            if activity.headsUp != nil && !(activity.micOn || activity.cameraOn) {
                Text(activity.headsUpLabel)
            } else if activity.current != nil {
                Text(activity.timeLeftLabel.replacingOccurrences(of: " left", with: ""))
            } else {
                Image(systemName: activity.muted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 14, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .font(.island(13))
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
        .contentTransition(.numericText(countsDown: true))
        .animation(.smooth(duration: 0.25), value: activity.timeLeftLabel)
    }
}

private struct MeetingExpanded: View {
    let activity: MeetingActivity

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                if let h = activity.headsUp, !(activity.micOn || activity.cameraOn) {
                    Text(h.title).font(.island(18)).lineLimit(2)
                    Text("Starts \(activity.headsUpLabel)")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                } else {
                    Text(activity.current?.title ?? "In a call").font(.island(18)).lineLimit(2)
                    HStack(spacing: 6) {
                        if activity.micOn { Circle().fill(AtollPalette.orange).frame(width: 7, height: 7) }
                        if activity.cameraOn { Circle().fill(AtollPalette.green).frame(width: 7, height: 7) }
                        Text(activity.current != nil ? activity.timeLeftLabel : (activity.cameraOn ? "Camera in use" : "Microphone in use"))
                            .font(.system(size: 13, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.6))
                            .contentTransition(.numericText(countsDown: true))
                            .animation(.smooth(duration: 0.25), value: activity.timeLeftLabel)
                    }
                }
            }
            Spacer(minLength: 0)
            if let h = activity.headsUp, !(activity.micOn || activity.cameraOn) {
                if h.joinURL != nil {
                    Button { activity.join(h) } label: {
                        Label("Join", systemImage: "video.fill")
                            .font(.island(14))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .background(Capsule(style: .continuous).fill(AtollPalette.green))
                    }
                    .buttonStyle(ActivityPressStyle())
                }
            } else if activity.micOn {
                ActivityCircleButton(symbol: activity.muted ? "mic.slash.fill" : "mic.fill",
                                     fill: activity.muted ? AtollPalette.red : Color.white.opacity(0.18)) { activity.toggleMute() }
            }
        }
    }
}
