// Dev mode shared pieces: Keychain token storage, the saved repo/project lists, and the CI status views.
import SwiftUI
import AppKit
import Security

/// Tokens live only in the Keychain (generic password items), never in files or UserDefaults.
enum Keychain {
    private static let service = "cc.primitive8.atoll"

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String?, for account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Saved dev-mode configuration. Repo and project names are not secret, so they live in UserDefaults.
@MainActor
@Observable
final class DevConfig {
    static let shared = DevConfig()
    private let d = UserDefaults.standard

    static let githubAccount = "github-token"
    static let vercelAccount = "vercel-token"

    /// "owner/repo" pairs.
    var repos: [String] { didSet { d.set(repos, forKey: "dev.repos") } }
    /// Vercel project names or ids.
    var vercelProjects: [String] { didSet { d.set(vercelProjects, forKey: "dev.vercelProjects") } }
    var vercelTeam: String { didSet { d.set(vercelTeam, forKey: "dev.vercelTeam") } }
    /// Bumped when a token changes so pollers restart.
    private(set) var tokenVersion = 0

    var hasGitHubToken: Bool { _ = tokenVersion; return !(Keychain.get(Self.githubAccount) ?? "").isEmpty }
    var hasVercelToken: Bool { _ = tokenVersion; return !(Keychain.get(Self.vercelAccount) ?? "").isEmpty }

    func setGitHubToken(_ t: String?) { Keychain.set(t, for: Self.githubAccount); tokenVersion += 1 }
    func setVercelToken(_ t: String?) { Keychain.set(t, for: Self.vercelAccount); tokenVersion += 1 }

    private init() {
        repos = d.stringArray(forKey: "dev.repos") ?? []
        vercelProjects = d.stringArray(forKey: "dev.vercelProjects") ?? []
        vercelTeam = d.string(forKey: "dev.vercelTeam") ?? ""
    }
}

// MARK: - CI status model shared by GitHub Actions and Vercel

enum CIStatus: Equatable { case running, success, failure }

struct CIItem: Equatable {
    let title: String       // workflow name / project
    let subtitle: String    // repo · branch
    let status: CIStatus
    let url: URL?
}

/// Observable box for one source's current item. Items linger a while after finishing, then clear.
@MainActor
@Observable
final class CIState {
    private(set) var item: CIItem?
    @ObservationIgnored private var clearTask: Task<Void, Never>?

    func set(_ new: CIItem?, lingerFor seconds: TimeInterval = 15) {
        clearTask?.cancel()
        item = new
        if let new, new.status != .running {
            clearTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.item = nil
            }
        }
    }
}

/// Shared IslandActivity behaviour for CI-style sources.
@MainActor
protocol CIActivity: IslandActivity {
    var state: CIState { get }
}

extension CIActivity {
    var isActive: Bool { state.item != nil }
    var priority: Int { state.item?.status == .running ? 35 : 75 }
    var tint: Color { color(for: state.item?.status ?? .running) }
    var compactSideWidth: CGFloat { 78 }
    var expandedHeight: CGFloat { 96 }

    func color(for s: CIStatus) -> Color { s == .running ? AtollPalette.blue : (s == .success ? AtollPalette.green : AtollPalette.red) }

    func compactLeading() -> AnyView { AnyView(CIGlyph(state: state).compactSlot(.leading, width: compactSideWidth)) }
    func compactTrailing() -> AnyView { AnyView(CILabel(state: state).compactSlot(.trailing, width: compactSideWidth)) }
    func minimal() -> AnyView { AnyView(CIGlyph(state: state).minimalSlot()) }
    func expanded() -> AnyView { AnyView(CIExpanded(state: state).expandedSlot(height: expandedHeight)) }
}

struct CISpinner: View {
    var color: Color
    var size: CGFloat = 16
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees((t * 360).truncatingRemainder(dividingBy: 360)))
                .frame(width: size, height: size)
        }
    }
}

private struct CIGlyph: View {
    let state: CIState
    var body: some View {
        let s = state.item?.status ?? .running
        ZStack {
            switch s {
            case .running: CISpinner(color: AtollPalette.blue)
            case .success:
                Image(systemName: "checkmark.circle.fill").font(.system(size: 17, weight: .bold)).foregroundStyle(AtollPalette.green)
            case .failure:
                Image(systemName: "xmark.circle.fill").font(.system(size: 17, weight: .bold)).foregroundStyle(AtollPalette.red)
            }
        }
        .animation(.smooth(duration: 0.25), value: s)
    }
}

private struct CILabel: View {
    let state: CIState
    var body: some View {
        Text(state.item?.title ?? "")
            .font(.island(12))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: 78, alignment: .trailing)
            .fixedSize(horizontal: true, vertical: false)
    }
}

private struct CIExpanded: View {
    let state: CIState
    var body: some View {
        if let item = state.item {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.island(18)).lineLimit(2)
                    Text(item.subtitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                    Text(item.status == .running ? "Running" : (item.status == .success ? "Succeeded" : "Failed"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(item.status == .running ? AtollPalette.blue : (item.status == .success ? AtollPalette.green : AtollPalette.red))
                }
                Spacer(minLength: 0)
                if let url = item.url {
                    ActivityCircleButton(symbol: "arrow.up.right", fill: Color.white.opacity(0.18), size: 40) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { if let url = item.url { NSWorkspace.shared.open(url) } }
        }
    }
}
