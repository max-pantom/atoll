// Shared contract between the Island shell (builder A) and Activities/Settings (builder B).
// Change only with care: both sides compile against this file.
import SwiftUI
import Observation

/// How the island is currently drawn. Mirrors Apple's Live Activity presentations.
enum IslandPresentation: Equatable {
    case idle                 // resting pill, nothing to show
    case compact              // one activity: leading + trailing around the pill
    case minimal              // several: one attached, others detached bubbles
    case expanded             // long-press / hover / alert bloom
}

/// A Live-Activity-like thing that can live in the island.
/// Implementations are @Observable classes so SwiftUI updates when they change.
@MainActor
protocol IslandActivity: AnyObject {
    /// Stable id, e.g. "nowPlaying", "timer", "battery", "hud.volume".
    var id: String { get }
    /// Higher wins the compact slot. Transient HUDs ~100, now playing 50, timer 40, calendar 10.
    var priority: Int { get }
    /// When false the island ignores this activity.
    var isActive: Bool { get }
    /// Accent colour (waveform tint, ring colour...).
    var tint: Color { get }
    /// Width of the leading/trailing compact content (each side), in points. Typical 28...60.
    var compactSideWidth: CGFloat { get }
    /// Height of the expanded view content (Apple: 84...160 on iPhone; Mac can go to ~200).
    var expandedHeight: CGFloat { get }
    /// Expanded width override; nil = settings default.
    var expandedWidth: CGFloat? { get }

    func compactLeading() -> AnyView
    func compactTrailing() -> AnyView
    func minimal() -> AnyView
    func expanded() -> AnyView
}

extension IslandActivity {
    var expandedWidth: CGFloat? { nil }
    var compactSideWidth: CGFloat { 34 }
}

/// Registry the shell observes. Activities register once at launch.
@MainActor
@Observable
final class ActivityCenter {
    static let shared = ActivityCenter()

    private(set) var activities: [any IslandActivity] = []
    /// Set by `bloom` — the island expands this activity without user input, then collapses.
    private(set) var bloomingID: String? = nil
    /// Bumped on every bloom so the shell can restart its timer.
    private(set) var bloomToken: Int = 0
    private var bloomTask: Task<Void, Never>?

    func register(_ activity: any IslandActivity) {
        guard !activities.contains(where: { $0.id == activity.id }) else { return }
        activities.append(activity)
    }

    /// Active activities, highest priority first. Ties keep registration order.
    var active: [any IslandActivity] {
        activities.enumerated()
            .filter { $0.element.isActive && AtollSettings.shared.isEnabled($0.element.id) }
            .sorted { $0.element.priority != $1.element.priority ? $0.element.priority > $1.element.priority : $0.offset < $1.offset }
            .map(\.element)
    }

    /// Ask the island to auto-expand an activity (alert), e.g. timer finished, charger plugged in.
    func bloom(_ id: String, for seconds: TimeInterval = 2.5) {
        bloomingID = id
        bloomToken &+= 1
        bloomTask?.cancel()
        bloomTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.bloomingID = nil
        }
    }

    func endBloom() { bloomTask?.cancel(); bloomingID = nil }
}

enum IslandStyle: String, CaseIterable, Identifiable {
    case modern = "modern"     // iPhone 14–17 pill (≈126×37 pt)
    case small = "small"       // iPhone 18 Pro smaller pill (≈82×37 pt, estimate)
    var id: String { rawValue }
    var label: String { self == .modern ? "Classic" : "Small (iPhone 18 Pro)" }
}

enum ExpandTrigger: String, CaseIterable, Identifiable {
    case hover, click
    var id: String { rawValue }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case pureBlack = "black"   // true Apple look
    case glass = "glass"       // subtle material for bright desktops
    var id: String { rawValue }
}

/// User settings, persisted in UserDefaults. Shell reads; Settings UI writes.
@MainActor
@Observable
final class AtollSettings {
    static let shared = AtollSettings()
    private let d = UserDefaults.standard

    /// CGDirectDisplayID of the chosen screen; 0 = main screen.
    var displayID: UInt32 { didSet { d.set(Int(displayID), forKey: "displayID") } }
    var style: IslandStyle { didSet { d.set(style.rawValue, forKey: "style") } }
    /// Scale multiplier for the whole island, 0.8...1.6.
    var scale: Double { didSet { d.set(scale, forKey: "scale") } }
    /// Horizontal offset from centre, points.
    var offsetX: Double { didSet { d.set(offsetX, forKey: "offsetX") } }
    /// Gap from the top of the screen, points (0 = flush under menu bar top edge).
    var offsetY: Double { didSet { d.set(offsetY, forKey: "offsetY") } }
    var trigger: ExpandTrigger { didSet { d.set(trigger.rawValue, forKey: "trigger") } }
    /// Hover delay before expanding, seconds.
    var hoverDelay: Double { didSet { d.set(hoverDelay, forKey: "hoverDelay") } }
    var appearance: AppearanceMode { didSet { d.set(appearance.rawValue, forKey: "appearance") } }
    var haptics: Bool { didSet { d.set(haptics, forKey: "haptics") } }
    var hideIdlePill: Bool { didSet { d.set(hideIdlePill, forKey: "hideIdlePill") } }
    var replaceSystemHUD: Bool { didSet { d.set(replaceSystemHUD, forKey: "replaceSystemHUD") } }
    var reduceMotion: Bool { didSet { d.set(reduceMotion, forKey: "reduceMotion") } }
    /// Activity ids switched off by the user.
    var disabledActivities: Set<String> { didSet { d.set(Array(disabledActivities), forKey: "disabledActivities") } }

    /// Activities forced on for this run by `--demo=<name>`. Never persisted.
    var demoEnabled: Set<String> = []

    func isEnabled(_ id: String) -> Bool {
        // "hud.volume" is governed by "hud", etc.
        let root = id.split(separator: ".").first.map(String.init) ?? id
        if demoEnabled.contains(id) || demoEnabled.contains(root) { return true }
        return !disabledActivities.contains(id) && !disabledActivities.contains(root)
    }

    private init() {
        displayID = UInt32(d.integer(forKey: "displayID"))
        style = IslandStyle(rawValue: d.string(forKey: "style") ?? "") ?? .modern
        scale = d.object(forKey: "scale") as? Double ?? 1.0
        offsetX = d.object(forKey: "offsetX") as? Double ?? 0
        offsetY = d.object(forKey: "offsetY") as? Double ?? 6
        trigger = ExpandTrigger(rawValue: d.string(forKey: "trigger") ?? "") ?? .hover
        hoverDelay = d.object(forKey: "hoverDelay") as? Double ?? 0.15
        appearance = AppearanceMode(rawValue: d.string(forKey: "appearance") ?? "") ?? .pureBlack
        haptics = d.object(forKey: "haptics") as? Bool ?? true
        hideIdlePill = d.object(forKey: "hideIdlePill") as? Bool ?? false
        replaceSystemHUD = d.object(forKey: "replaceSystemHUD") as? Bool ?? false
        reduceMotion = d.object(forKey: "reduceMotion") as? Bool ?? false
        disabledActivities = Set(d.stringArray(forKey: "disabledActivities") ?? [])
    }
}

/// Island motion constants. Sources and estimates: plans/RESEARCH.md §3.
enum IslandMotion {
    static let expand = Animation.spring(response: 0.42, dampingFraction: 0.78)
    static let collapse = Animation.spring(response: 0.32, dampingFraction: 0.92)
    static let resize = Animation.spring(response: 0.38, dampingFraction: 0.82)
    static let contentIn = Animation.easeOut(duration: 0.22).delay(0.06)
    static let contentOut = Animation.easeIn(duration: 0.15)
    static let pressScale: CGFloat = 1.04
    static let longPress: TimeInterval = 0.4
}
