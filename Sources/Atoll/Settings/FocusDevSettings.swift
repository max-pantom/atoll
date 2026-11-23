// Settings tabs for Focus and Developer mode (separate file to keep SettingsWindow.swift edits small).
import SwiftUI
import AppKit

@MainActor
struct FocusSettings: View {
    private var shortcuts = FocusShortcuts.shared
    private var log = FocusLog.shared

    private var todayText: String {
        let m = log.todaySeconds / 60
        return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Focus today") { Text(todayText).monospacedDigit() }
                LabeledContent("Sessions completed") { Text("\(log.todayCompleted)").monospacedDigit() }
            } header: {
                Text("Today")
            } footer: {
                Text("Presets are 25/5, 50/10 and 90/15, or a custom length from the expanded island. Sessions are logged in ~/Library/Application Support/Atoll.")
            }

            Section {
                if shortcuts.installed == true {
                    Label("Do Not Disturb shortcuts found.", systemImage: "checkmark.circle.fill").foregroundStyle(AtollPalette.green)
                } else {
                    Label("Optional: create two Shortcuts to turn Do Not Disturb on and off during focus.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                    Text("In the Shortcuts app, make \"\(FocusShortcuts.onName)\" (Set Focus: Do Not Disturb, turn on) and \"\(FocusShortcuts.offName)\" (turn off). Atoll runs them with `shortcuts run`; if they are missing it does nothing.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button("Check again") { shortcuts.refresh() }
            } header: {
                Text("Do Not Disturb")
            }
        }
        .formStyle(.grouped)
        .onAppear { shortcuts.refresh() }
    }
}

@MainActor
struct DevSettings: View {
    @Bindable private var config = DevConfig.shared
    @State private var githubToken = ""
    @State private var vercelToken = ""
    @State private var newRepo = ""
    @State private var newProject = ""

    var body: some View {
        Form {
            Section {
                tokenRow("GitHub token", text: $githubToken, saved: config.hasGitHubToken) {
                    config.setGitHubToken(githubToken); githubToken = ""
                } clear: { config.setGitHubToken(nil) }
                ForEach(config.repos, id: \.self) { repo in
                    HStack {
                        Text(repo)
                        Spacer()
                        Button { config.repos.removeAll { $0 == repo } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("owner/repo", text: $newRepo).onSubmit(addRepo)
                    Button("Add", action: addRepo).disabled(!newRepo.contains("/"))
                }
            } header: {
                Text("GitHub Actions")
            } footer: {
                Text("Needs a token with read access to Actions. Stored in the Keychain. Polls every 30 s, every 10 s while a run is in progress.")
            }

            Section {
                tokenRow("Vercel token", text: $vercelToken, saved: config.hasVercelToken) {
                    config.setVercelToken(vercelToken); vercelToken = ""
                } clear: { config.setVercelToken(nil) }
                TextField("Team ID (optional)", text: $config.vercelTeam)
                ForEach(config.vercelProjects, id: \.self) { p in
                    HStack {
                        Text(p)
                        Spacer()
                        Button { config.vercelProjects.removeAll { $0 == p } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Project name", text: $newProject).onSubmit(addProject)
                    Button("Add", action: addProject).disabled(newProject.isEmpty)
                }
            } header: {
                Text("Vercel (optional)")
            } footer: {
                Text("Only active when a token is set. Shows the latest deployment state for each project.")
            }

            Section {
                Text("atoll notify \"Build done\" \"42 tests passed\" ok")
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            } header: {
                Text("Terminal pings")
            } footer: {
                Text("The atoll command ships in Atoll.app/Contents/Resources. See docs/focus-and-dev.md for the zsh snippet that pings after long commands.")
            }
        }
        .formStyle(.grouped)
    }

    private func addRepo() {
        let r = newRepo.trimmingCharacters(in: .whitespaces)
        guard r.contains("/"), !config.repos.contains(r) else { return }
        config.repos.append(r); newRepo = ""
    }

    private func addProject() {
        let p = newProject.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty, !config.vercelProjects.contains(p) else { return }
        config.vercelProjects.append(p); newProject = ""
    }

    @ViewBuilder
    private func tokenRow(_ label: String, text: Binding<String>, saved: Bool, save: @escaping () -> Void, clear: @escaping () -> Void) -> some View {
        HStack {
            SecureField(saved ? "\(label) saved in Keychain" : label, text: text)
            Button("Save", action: save).disabled(text.wrappedValue.isEmpty)
            if saved { Button("Remove", role: .destructive, action: clear) }
        }
    }
}
