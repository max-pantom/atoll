// `--demo=<name>` entry points for the focus, meeting and dev-mode activities (CI screenshots).
// Names: focus, meeting, github, ping, vercel. Add `--demo-expand` to bloom the activity after 4 s.
import Foundation

@MainActor
enum FeatureDemo {
    static func run(_ args: [String]) {
        guard let arg = args.first(where: { $0.hasPrefix("--demo=") }) else { return }
        let id: String
        switch String(arg.dropFirst("--demo=".count)) {
        case "focus": FocusActivity.shared.startDemo(); id = FocusActivity.shared.id
        case "meeting": MeetingActivity.shared.startDemo(); id = MeetingActivity.shared.id
        case "github": GitHubActionsActivity.shared.startDemo(); id = GitHubActionsActivity.shared.id
        case "ping": TerminalPingActivity.shared.startDemo(); id = TerminalPingActivity.shared.id
        case "vercel": VercelActivity.shared.startDemo(); id = VercelActivity.shared.id
        default: return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            ActivityCenter.shared.bloom(id, for: 8)
        }
    }
}
