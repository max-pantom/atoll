// Dev mode (c): latest Vercel deployment state for chosen projects. Only runs when a token is set (Keychain).
import SwiftUI
import AppKit

@MainActor
@Observable
final class VercelActivity: CIActivity {
    static let shared = VercelActivity()

    let id = "dev.vercel"
    let state = CIState()

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var announced = Set<String>()
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

    private func pollOnce() async -> TimeInterval {
        guard !demo else { return 30 }
        // Read the Keychain once per token change, not on every poll.
        let version = DevConfig.shared.tokenVersion
        if tokenLoadedVersion != version { token = Keychain.get(DevConfig.vercelAccount); tokenLoadedVersion = version }
        guard let token, !token.isEmpty else { return 30 }
        let projects = DevConfig.shared.vercelProjects.filter { !$0.isEmpty }
        guard !projects.isEmpty else { return 30 }
        let team = DevConfig.shared.vercelTeam

        var running: CIItem?
        var finished: CIItem?
        for project in projects {
            guard !Task.isCancelled, let d = await Self.latest(project: project, team: team, token: token) else { continue }
            let building = ["BUILDING", "QUEUED", "INITIALIZING"].contains(d.state)
            let status: CIStatus = building ? .running : (d.state == "READY" ? .success : .failure)
            let item = CIItem(title: project, subtitle: "Vercel · \(d.target)", status: status, url: d.url)
            if building {
                running = running ?? item
                announced.insert("b:" + d.id)
            } else if !announced.contains(d.id), d.state != "CANCELED" {
                let wasBuilding = announced.contains("b:" + d.id)
                let fresh = Date().timeIntervalSince(d.created) < 600
                announced.insert(d.id)
                if wasBuilding || fresh { finished = finished ?? item }
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

    private struct Deployment { let id: String; let state: String; let target: String; let url: URL?; let created: Date }

    private static func latest(project: String, team: String, token: String) async -> Deployment? {
        var comps = URLComponents(string: "https://api.vercel.com/v6/deployments")!
        var items = [URLQueryItem(name: "app", value: project), URLQueryItem(name: "limit", value: "1")]
        if !team.isEmpty { items.append(URLQueryItem(name: "teamId", value: team)) }
        comps.queryItems = items
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["deployments"] as? [[String: Any]], let d = list.first,
              let uid = d["uid"] as? String else { return nil }
        let st = ((d["state"] as? String) ?? (d["readyState"] as? String) ?? "").uppercased()
        let link = (d["inspectorUrl"] as? String).flatMap(URL.init(string:))
            ?? (d["url"] as? String).flatMap { URL(string: "https://\($0)") }
        let created = ((d["created"] as? Double) ?? (d["createdAt"] as? Double) ?? 0) / 1000
        return Deployment(id: uid, state: st, target: (d["target"] as? String) ?? "preview", url: link,
                          created: Date(timeIntervalSince1970: created))
    }

    func startDemo() {
        demo = true
        state.set(CIItem(title: "atoll-site", subtitle: "Vercel · production", status: .success, url: nil), lingerFor: 3600)
    }
}
