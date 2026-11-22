// Calendar: the next event starting within 60 minutes (EventKit, macOS 14 full-access API).
import SwiftUI
import AppKit
import EventKit

@MainActor
@Observable
final class CalendarActivity: IslandActivity {
    struct Entry: Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let location: String?
        let color: Color
        let joinURL: URL?
    }

    static let shared = CalendarActivity()

    let id = "calendar"
    let priority = 10

    private(set) var next: Entry?
    /// Refreshed every 15 s so "in 12m" stays current.
    private(set) var now = Date()

    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var requested = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var changeObserver: NSObjectProtocol?

    private init() {}

    // MARK: IslandActivity

    var isActive: Bool { next != nil }
    var tint: Color { next?.color ?? .white }
    var compactSideWidth: CGFloat { 54 }
    var expandedHeight: CGFloat { 104 }

    func compactLeading() -> AnyView { AnyView(CalendarLeading(activity: self).compactSlot(.leading, width: compactSideWidth)) }
    func compactTrailing() -> AnyView { AnyView(CalendarTrailing(activity: self).compactSlot(.trailing, width: compactSideWidth)) }
    func minimal() -> AnyView { AnyView(CalendarLeading(activity: self).minimalSlot()) }
    func expanded() -> AnyView { AnyView(CalendarExpanded(activity: self).expandedSlot(height: expandedHeight)) }

    // MARK: Loading

    func start() {
        guard !started else { return }
        started = true
        changeObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
    }

    func refresh() async {
        now = Date()
        guard AtollSettings.shared.isEnabled(id) else { next = nil; return }

        var status = EKEventStore.authorizationStatus(for: .event)
        if status == .notDetermined, !requested {
            requested = true
            _ = try? await store.requestFullAccessToEvents()
            status = EKEventStore.authorizationStatus(for: .event)
        }
        guard status == .fullAccess else { next = nil; return }   // denied: stay quiet

        let n = Date()
        let predicate = store.predicateForEvents(withStart: n, end: n.addingTimeInterval(3600), calendars: nil)
        let events = store.events(matching: predicate)
            .filter { e in
                guard !e.isAllDay, e.status != .canceled, e.endDate > n else { return false }
                guard e.startDate > n.addingTimeInterval(-600) else { return false }   // ongoing, but only just started
                let me = e.attendees?.first(where: { $0.isCurrentUser })
                return me?.participantStatus != .declined
            }
            .sorted { $0.startDate < $1.startDate }

        guard let e = events.first else { next = nil; return }
        let entry = Entry(
            id: e.eventIdentifier ?? UUID().uuidString,
            title: (e.title?.isEmpty == false ? e.title : nil) ?? "Event",
            start: e.startDate,
            end: e.endDate,
            location: (e.location?.isEmpty == false) ? e.location : nil,
            color: Color(nsColor: e.calendar?.color ?? NSColor.systemBlue),
            joinURL: Self.joinURL(in: [e.url?.absoluteString, e.location, e.notes])
        )
        if entry != next { next = entry }
    }

    // MARK: Helpers

    private static let meetingHosts = ["zoom.us", "zoomgov.com", "meet.google.com", "teams.microsoft.com", "teams.live.com",
                                       "webex.com", "whereby.com", "gotomeeting.com", "facetime.apple.com"]

    static func joinURL(in texts: [String?]) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for text in texts.compactMap({ $0 }) {
            let range = NSRange(text.startIndex..., in: text)
            for match in detector.matches(in: text, options: [], range: range) {
                if let url = match.url, let host = url.host?.lowercased(),
                   meetingHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
                    return url
                }
            }
        }
        return nil
    }

    var minutesUntilStart: Int? {
        guard let e = next else { return nil }
        return Int(ceil(e.start.timeIntervalSince(now) / 60))
    }

    var relativeLabel: String {
        guard let m = minutesUntilStart else { return "" }
        if m <= 0 { return "now" }
        if m >= 60 { return "in \(m / 60)h" }
        return "in \(m)m"
    }
}

// MARK: - Views

private struct CalendarLeading: View {
    let activity: CalendarActivity
    var body: some View {
        Circle()
            .fill(activity.tint)
            .frame(width: 12 * ActivityMetrics.scale, height: 12 * ActivityMetrics.scale)
            .animation(.smooth(duration: 0.3), value: activity.next?.id)
    }
}

private struct CalendarTrailing: View {
    let activity: CalendarActivity
    var body: some View {
        Text(activity.relativeLabel)
            .font(.island(13))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .contentTransition(.numericText(countsDown: true))
            .animation(.smooth(duration: 0.25), value: activity.relativeLabel)
    }
}

private struct CalendarExpanded: View {
    let activity: CalendarActivity

    var body: some View {
        if let e = activity.next {
            HStack(spacing: 14) {
                Capsule(style: .continuous)
                    .fill(e.color)
                    .frame(width: 5, height: 58)
                VStack(alignment: .leading, spacing: 3) {
                    Text(e.title)
                        .font(.island(18))
                        .lineLimit(2)
                    Text("\(e.start.formatted(date: .omitted, time: .shortened)) – \(e.end.formatted(date: .omitted, time: .shortened))  ·  \(activity.relativeLabel)")
                        .font(.system(size: 13, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.6))
                    if let loc = e.location, e.joinURL == nil {
                        Label(loc, systemImage: "mappin.and.ellipse")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if let url = e.joinURL {
                    Button { NSWorkspace.shared.open(url) } label: {
                        Label("Join", systemImage: "video.fill")
                            .font(.island(14))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .background(Capsule(style: .continuous).fill(AtollPalette.green))
                    }
                    .buttonStyle(ActivityPressStyle())
                }
            }
        } else {
            Text("No upcoming events")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
        }
    }
}
