// Settings sections and demo hooks for Clipboard, Quick capture and Downloads.
import SwiftUI
import AppKit

/// Extra sections appended to the Activities tab.
@MainActor
struct CaptureClipboardSettings: View {
    private let clipboard = ClipboardActivity.shared
    private let capture = QuickCaptureActivity.shared
    @State private var axGranted = ClipboardActivity.shared.accessibilityGranted

    var body: some View {
        @Bindable var clipboard = clipboard
        Section {
            LabeledContent("Shortcut") { HotKeyRecorder(pref: capture.hotKeyPref) }
        } header: {
            Text("Quick capture")
        } footer: {
            Text("Return saves an Apple Note and ⌘Return saves a Reminder. macOS asks for Automation access to Notes or Reminders access the first time you save.")
        }

        Section {
            LabeledContent("Shortcut") { HotKeyRecorder(pref: clipboard.hotKeyPref) }
            Toggle("Flash the island after each copy", isOn: $clipboard.flashOnCopy)
            Toggle("Option-click pastes into the frontmost app", isOn: Binding(
                get: { clipboard.pasteEnabled },
                set: { on in
                    clipboard.pasteEnabled = on
                    if on { clipboard.requestAccessibility() }
                    axGranted = clipboard.accessibilityGranted
                }
            ))
            if clipboard.pasteEnabled && !axGranted {
                Text("Allow Atoll in System Settings › Privacy & Security › Accessibility. Until then, option-click only copies.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button("Clear clipboard history", role: .destructive) { clipboard.clearAll() }
        } header: {
            Text("Clipboard")
        } footer: {
            Text("Keeps the last 20 copies in memory. Only pinned items are saved to disk. Items from password managers are ignored.")
        }

        Section {
            EmptyView()
        } header: {
            Text("Downloads")
        } footer: {
            Text("Watches your Downloads folder for Safari, Chrome, Firefox and AirDrop files. macOS asks for access to Downloads when you turn this on.")
        }
    }
}

/// Launch-time defaults and `--demo=…` support for the three activities.
@MainActor
enum V02ASupport {
    /// Quick capture (Automation / Reminders) and Downloads (folder access) start off; the user opts in.
    static func seedDefaults() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "v02a.seeded") else { return }
        d.set(true, forKey: "v02a.seeded")
        AtollSettings.shared.disabledActivities.formUnion(["quickCapture", "downloads"])
    }

    /// `--demo=clipboard`, `--demo=capture`, `--demo=downloads` for CI screenshots.
    static func runDemo(_ args: [String] = CommandLine.arguments) {
        guard let arg = args.first(where: { $0.hasPrefix("--demo=") }) else { return }
        let which = String(arg.dropFirst("--demo=".count))
        let settings = AtollSettings.shared
        switch which {
        case "clipboard":
            settings.disabledActivities.remove("clipboard")
            let c = ClipboardActivity.shared
            for (text, source) in [("Meeting notes: ship v0.2 on Friday", "Notes"), ("https://primitive8.cc", "Safari"), ("npm run build && npm test", "Terminal")] {
                c.ingest(ClipItem(kind: .text, text: text, date: Date().addingTimeInterval(-Double.random(in: 20...900)), source: source))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { c.summon() }
        case "capture":
            settings.disabledActivities.remove("quickCapture")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                QuickCaptureActivity.shared.summon(prefill: "Call the dentist tomorrow 9am")
            }
        case "downloads":
            settings.disabledActivities.remove("downloads")
            DownloadsActivity.shared.runDemo()
        default:
            break
        }
    }
}
