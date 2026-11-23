// Dev mode (b): terminal pings through `atoll://notify?title=…&body=…&status=ok|fail`.
// The `atoll` CLI in the bundle's Resources opens that URL; see docs/focus-and-dev.md.
import SwiftUI
import AppKit

@MainActor
@Observable
final class TerminalPingActivity: IslandActivity {
    enum Status { case ok, fail, info }
    struct Ping: Equatable { let title: String; let body: String; let status: Status }

    static let shared = TerminalPingActivity()

    let id = "dev.ping"
    var priority: Int { 80 }

    private(set) var ping: Ping?
    @ObservationIgnored private var clearTask: Task<Void, Never>?

    private init() {}

    var isActive: Bool { ping != nil }
    var tint: Color { color(ping?.status ?? .info) }
    var compactSideWidth: CGFloat { 78 }
    var expandedHeight: CGFloat { 84 }

    private func color(_ s: Status) -> Color { s == .ok ? AtollPalette.green : (s == .fail ? AtollPalette.red : AtollPalette.blue) }

    func compactLeading() -> AnyView { AnyView(PingGlyph(activity: self).compactSlot(.leading, width: compactSideWidth)) }
    func compactTrailing() -> AnyView { AnyView(PingLabel(activity: self).compactSlot(.trailing, width: compactSideWidth)) }
    func minimal() -> AnyView { AnyView(PingGlyph(activity: self).minimalSlot()) }
    func expanded() -> AnyView { AnyView(PingExpanded(activity: self).expandedSlot(height: expandedHeight)) }

    /// Handles `atoll://notify?...`. Returns true if the URL was ours.
    @discardableResult
    static func handle(_ url: URL) -> Bool {
        guard url.scheme == "atoll", url.host == "notify" else { return false }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func v(_ k: String) -> String { items.first(where: { $0.name == k })?.value ?? "" }
        let status: Status = v("status") == "ok" ? .ok : (v("status") == "fail" ? .fail : .info)
        let title = v("title").isEmpty ? "Terminal" : v("title")
        shared.show(Ping(title: String(title.prefix(80)), body: String(v("body").prefix(200)), status: status))
        return true
    }

    func show(_ p: Ping) {
        guard AtollSettings.shared.isEnabled(id) else { return }
        clearTask?.cancel()
        ping = p
        ActivityCenter.shared.bloom(id, for: 3)
        clearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            self?.ping = nil
        }
    }

    func startDemo() {
        ping = Ping(title: "make test", body: "42 tests passed in 18s", status: .ok)
    }
}

private struct PingGlyph: View {
    let activity: TerminalPingActivity
    var body: some View {
        Image(systemName: activity.ping?.status == .fail ? "xmark.circle.fill" : (activity.ping?.status == .ok ? "checkmark.circle.fill" : "terminal.fill"))
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(activity.tint)
            .contentTransition(.symbolEffect(.replace))
    }
}

private struct PingLabel: View {
    let activity: TerminalPingActivity
    var body: some View {
        Text(activity.ping?.title ?? "")
            .font(.island(12))
            .lineLimit(1)
            .frame(maxWidth: 78, alignment: .trailing)
            .fixedSize(horizontal: true, vertical: false)
    }
}

private struct PingExpanded: View {
    let activity: TerminalPingActivity
    var body: some View {
        if let p = activity.ping {
            HStack(spacing: 14) {
                Image(systemName: p.status == .fail ? "xmark.circle.fill" : (p.status == .ok ? "checkmark.circle.fill" : "terminal.fill"))
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(activity.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(p.title).font(.island(18)).lineLimit(1)
                    if !p.body.isEmpty {
                        Text(p.body).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.6)).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}
