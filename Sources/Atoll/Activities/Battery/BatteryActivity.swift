// Battery: bloom on plug-in/unplug and a red alert at ≤20 %. Inactive on Macs without a battery (Mac mini).
import SwiftUI
import AppKit
import IOKit
import IOKit.ps

@MainActor
@Observable
final class BatteryActivity: IslandActivity {
    static let shared = BatteryActivity()

    let id = "battery"
    let priority = 70

    private(set) var hasBattery = false
    private(set) var percent = 100
    private(set) var charging = false
    private(set) var pluggedIn = false
    private(set) var minutesRemaining: Int?
    /// True while the transient bloom is on screen.
    private(set) var showing = false

    @ObservationIgnored private var source: CFRunLoopSource?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var hasBaseline = false
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var alertedLevels: Set<Int> = []

    private init() {}

    // MARK: IslandActivity

    var isActive: Bool { hasBattery && showing }
    var isLow: Bool { !pluggedIn && percent <= 20 }
    var tint: Color { isLow ? AtollPalette.red : (charging || pluggedIn ? AtollPalette.green : .white) }
    var compactSideWidth: CGFloat { 76 }   // "100%" + glyph
    var expandedHeight: CGFloat { 92 }

    func compactLeading() -> AnyView { AnyView(BatteryLeading(activity: self).compactSlot(.leading, width: compactSideWidth)) }
    func compactTrailing() -> AnyView { AnyView(BatteryTrailing(activity: self).compactSlot(.trailing, width: compactSideWidth)) }
    func minimal() -> AnyView { AnyView(BatteryLeading(activity: self).minimalSlot()) }
    func expanded() -> AnyView { AnyView(BatteryExpanded(activity: self).expandedSlot(height: expandedHeight)) }

    // MARK: Monitoring

    func start() {
        guard !started else { return }
        started = true
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { ctx in
            guard let ctx else { return }
            let me = Unmanaged<BatteryActivity>.fromOpaque(ctx).takeUnretainedValue()
            Task { @MainActor in me.refresh() }
        }
        if let src = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            source = src
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        }
        refresh()
    }

    private func refresh() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            hasBattery = false
            return
        }
        var chosen: [String: Any]?
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
            let type = d["Type"] as? String
            if type == "InternalBattery" { chosen = d; break }
            if type == "UPS", chosen == nil { chosen = d }
        }
        guard let d = chosen else { hasBattery = false; return }   // Mac mini, Mac Studio…

        let current = (d["Current Capacity"] as? NSNumber)?.intValue ?? 0
        let max = (d["Max Capacity"] as? NSNumber)?.intValue ?? 100
        let newPercent = max > 0 ? Swift.min(100, Int((Double(current) / Double(max) * 100).rounded())) : current
        let newCharging = (d["Is Charging"] as? Bool) ?? false
        let newPlugged = (d["Power Source State"] as? String) == "AC Power"
        var minutes: Int?
        let key = newPlugged ? "Time to Full Charge" : "Time to Empty"
        if let m = (d[key] as? NSNumber)?.intValue, m > 0 { minutes = m }

        let pluggedChanged = hasBaseline && newPlugged != pluggedIn
        hasBattery = true
        percent = newPercent
        charging = newCharging
        minutesRemaining = minutes
        pluggedIn = newPlugged

        if newPlugged { alertedLevels = [] }
        if pluggedChanged {
            present(for: 3)
        } else if hasBaseline, !newPlugged {
            for threshold in [20, 10] where newPercent <= threshold && !alertedLevels.contains(threshold) {
                alertedLevels.insert(threshold)
                present(for: 4)
                break
            }
        }
        hasBaseline = true
    }

    private func present(for seconds: TimeInterval) {
        showing = true
        ActivityCenter.shared.bloom(id, for: seconds)
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((seconds + 0.4) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.showing = false
        }
    }

    var batterySymbol: String {
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

// MARK: - Views

private struct BatteryLeading: View {
    let activity: BatteryActivity
    var body: some View {
        let symbol = activity.isLow ? "battery.25percent" : (activity.pluggedIn ? "bolt.fill" : "bolt.slash.fill")
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(activity.tint)
            .contentTransition(.symbolEffect(.replace))
            .animation(.smooth(duration: 0.25), value: symbol)
    }
}

private struct BatteryTrailing: View {
    let activity: BatteryActivity
    var body: some View {
        HStack(spacing: 4) {
            Text("\(activity.percent)%")
                .font(.island(14))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .contentTransition(.numericText())
            Image(systemName: activity.batterySymbol)
                .font(.system(size: 15, weight: .semibold))
        }
        .foregroundStyle(activity.tint)
        .animation(.smooth(duration: 0.25), value: activity.percent)
    }
}

private struct BatteryExpanded: View {
    let activity: BatteryActivity

    var body: some View {
        HStack(spacing: 18) {
            ZStack {
                Circle().stroke(activity.tint.opacity(0.25), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: CGFloat(activity.percent) / 100)
                    .stroke(activity.tint, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: activity.pluggedIn ? "bolt.fill" : "battery.50percent")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(activity.tint)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 60, height: 60)
            .animation(.smooth(duration: 0.4), value: activity.percent)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(activity.tint)
                Text("\(activity.percent)%")
                    .font(.island(34))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if let detail = detailText {
                    Text(detail)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var statusText: String {
        if activity.isLow { return "Low Battery" }
        if activity.pluggedIn { return activity.charging ? "Charging" : "Plugged In" }
        return "On Battery"
    }

    private var detailText: String? {
        guard let m = activity.minutesRemaining else {
            return activity.pluggedIn && !activity.charging && activity.percent >= 100 ? "Fully charged" : nil
        }
        let text = m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min"
        return activity.pluggedIn ? "\(text) until full" : "\(text) remaining"
    }
}
