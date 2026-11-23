// Dev mode (a): GitHub Actions status for chosen owner/repo pairs. Token from the Keychain only.
// Polls every 30 s, every 10 s while a run is in progress. Does nothing until a token and a repo are set.
import SwiftUI
import AppKit

@MainActor
@Observable
final class GitHubActionsActivity: CIActivity {
    static let shared = GitHubActionsActivity()

    let id = "dev.github"
    let state = CIState()

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var announced = Set<Int>()
    @ObservationIgnored private var demo = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var token: String?
    @ObservationIgnored private var tokenLoadedVersion = -1

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        trackEnabled(id) { [weak self] on in
            guard let self, !self.demo else { return }
            on ? self.startLoop() : self.stop()
        }
    }

    private func startLoop() {
        guard loop == nil else { return }
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = await self.pollOnce()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    /// Stops polling and clears the shown item so a stale run does not reappear when re-enabled.
    func stop() {
        loop?.cancel()
        loop = nil
        token = nil
        tokenLoadedVersion = -1
        state.set(nil)
    }

    /// Returns the delay before the next poll.
    private func pollOnce() async -> TimeInterval {
        guard !demo else { return 30 }
        // Read the Keychain once per token change, not on every poll.
        let version = DevConfig.shared.tokenVersion
        if tokenLoadedVersion != version { token = Keychain.get(DevConfig.githubAccount); tokenLoadedVersion = version }
        guard let token, !token.isEmpty else { return 30 }
        let repos = DevConfig.shared.repos.filter { $0.contains("/") }
        guard !repos.isEmpty else { return 30 }

        var running: CIItem?
        var finished: CIItem?
        for repo in repos {
            guard !Task.isCancelled, let run = await Self.latestRun(repo: repo, token: token) else { continue }
            let item = CIItem(title: run.name, subtitle: "\(repo) · \(run.branch)",
                              status: run.status != "completed" ? .running
                                  : (run.conclusion == "success" ? .success : .failure),
                              url: run.url)
            if item.status == .running {
                running = running ?? item
                announced.insert(-run.id)   // remember it was seen running
            } else if !announced.contains(run.id) {
                let wasRunning = announced.contains(-run.id)
                let fresh = Date().timeIntervalSince(run.updatedAt) < 120
                announced.insert(run.id)
                // Announce completions we watched happen, or ones that finished in the last two minutes.
                if wasRunning || fresh { finished = finished ?? item }
            }
        }

        if let finished {
            state.set(finished)
            ActivityCenter.shared.bloom(id, for: finished.status == .failure ? 4 : 2.5)
        } else if let running {
            if state.item == nil || state.item?.status == .running { state.set(running) }
        } else if state.item?.status == .running {
            state.set(nil)
        }
        return running != nil ? 10 : 30
    }

    private struct Run { let id: Int; let name: String; let branch: String; let status: String; let conclusion: String?; let url: URL?; let updatedAt: Date }

    private static func latestRun(repo: String, token: String) async -> Run? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/actions/runs?per_page=1") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runs = json["workflow_runs"] as? [[String: Any]], let r = runs.first,
              let id = r["id"] as? Int else { return nil }
        let iso = ISO8601DateFormatter()
        return Run(id: id,
                   name: (r["name"] as? String) ?? (r["display_title"] as? String) ?? "Workflow",
                   branch: (r["head_branch"] as? String) ?? "",
                   status: (r["status"] as? String) ?? "",
                   conclusion: r["conclusion"] as? String,
                   url: (r["html_url"] as? String).flatMap(URL.init(string:)),
                   updatedAt: (r["updated_at"] as? String).flatMap { iso.date(from: $0) } ?? .distantPast)
    }

    /// `--demo`: show a run in progress.
    func startDemo() {
        demo = true
        state.set(CIItem(title: "build", subtitle: "max-pantom/atoll · main", status: .running, url: nil))
    }
}
