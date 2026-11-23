// Settings window: General / Activities / Appearance / About, bound live to AtollSettings.shared.
import SwiftUI
import AppKit

@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView())
            let w = NSWindow(contentViewController: host)
            w.title = "Atoll Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.setContentSize(NSSize(width: 520, height: 520))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
private struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            ActivitiesSettings()
                .tabItem { Label("Activities", systemImage: "square.grid.2x2") }
            FocusSettings()
                .tabItem { Label("Focus", systemImage: "scope") }
            DevSettings()
                .tabItem { Label("Developer", systemImage: "terminal") }
            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 520)
    }
}

// MARK: - General

@MainActor
private struct GeneralSettings: View {
    @Bindable private var settings = AtollSettings.shared
    @State private var screens = NSScreen.screens
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        Form {
            Section("Display") {
                Picker("Show island on", selection: $settings.displayID) {
                    Text("Main display").tag(UInt32(0))
                    ForEach(screens, id: \.self) { screen in
                        if let id = Self.displayID(of: screen) {
                            Text(screen.localizedName).tag(id)
                        }
                    }
                }
                Picker("Style", selection: $settings.style) {
                    ForEach(IslandStyle.allCases) { Text($0.label).tag($0) }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
                screens = NSScreen.screens
            }

            Section {
                LabeledContent("Size") {
                    HStack {
                        Slider(value: $settings.scale, in: 0.8...1.6, step: 0.05)
                        Text(String(format: "%.2f×", settings.scale)).monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
                LabeledContent("Horizontal offset") {
                    HStack {
                        Slider(value: $settings.offsetX, in: -600...600, step: 1)
                        Text("\(Int(settings.offsetX)) pt").monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
                LabeledContent("Distance from top") {
                    HStack {
                        Slider(value: $settings.offsetY, in: 0...80, step: 1)
                        Text("\(Int(settings.offsetY)) pt").monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
                Button("Reset position and size") {
                    settings.scale = 1; settings.offsetX = 0; settings.offsetY = 6
                }
            } header: {
                Text("Size and position")
            } footer: {
                Text("The island moves while you drag, so you can line it up with your menu bar.")
            }

            Section("Expanding") {
                Picker("Expand on", selection: $settings.trigger) {
                    Text("Hover").tag(ExpandTrigger.hover)
                    Text("Click").tag(ExpandTrigger.click)
                }
                .pickerStyle(.segmented)
                if settings.trigger == .hover {
                    LabeledContent("Hover delay") {
                        HStack {
                            Slider(value: $settings.hoverDelay, in: 0...1, step: 0.05)
                            Text(String(format: "%.2f s", settings.hoverDelay)).monospacedDigit().frame(width: 52, alignment: .trailing)
                        }
                    }
                }
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { launchAtLogin = LaunchAtLogin.set($0) }
                ))
                if LaunchAtLogin.needsApproval {
                    Text("Approve Atoll in System Settings › General › Login Items.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private static func displayID(of screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

// MARK: - Activities

@MainActor
private struct ActivitiesSettings: View {
    @Bindable private var settings = AtollSettings.shared

    private struct Row: Identifiable {
        let id: String
        let title: String
        let detail: String
        let symbol: String
        let color: Color
    }

    private let rows: [Row] = [
        Row(id: "nowPlaying", title: "Now Playing", detail: "Artwork, waveform and controls for any app.", symbol: "music.note", color: .pink),
        Row(id: "timer", title: "Timer", detail: "Countdown with presets.", symbol: "timer", color: AtollPalette.orange),
        Row(id: "battery", title: "Battery", detail: "Plug-in and low battery alerts.", symbol: "battery.100percent.bolt", color: AtollPalette.green),
        Row(id: "calendar", title: "Calendar", detail: "Your next event, with a Join button for video calls.", symbol: "calendar", color: AtollPalette.red),
        Row(id: "shelf", title: "Shelf", detail: "Drop files on the island, drag them out, AirDrop them.", symbol: "tray.full.fill", color: AtollPalette.blue),
        Row(id: "clipboard", title: "Clipboard history", detail: "Last 20 copies; click to copy back, pin to keep.", symbol: "doc.on.clipboard", color: AtollPalette.blue),
        Row(id: "quickCapture", title: "Quick capture", detail: "Global hotkey: jot a note or reminder from anywhere.", symbol: "square.and.pencil", color: AtollPalette.orange),
        Row(id: "downloads", title: "Downloads", detail: "Progress for browser downloads and AirDrop arrivals.", symbol: "arrow.down.circle.fill", color: AtollPalette.blue),
        Row(id: "focus", title: "Focus timer", detail: "25/5, 50/10, 90/15 sessions with a progress ring.", symbol: "scope", color: FocusPalette.indigo),
        Row(id: "meeting", title: "Meeting bar", detail: "Mic and camera dots, time left, mute, and a heads-up before the next event.", symbol: "video.fill", color: AtollPalette.green),
        Row(id: "dev.github", title: "GitHub Actions", detail: "Run status for your repos. Needs a token in the Developer tab.", symbol: "checkmark.circle", color: AtollPalette.blue),
        Row(id: "dev.ping", title: "Terminal pings", detail: "Command-line alerts through the atoll:// URL scheme.", symbol: "terminal.fill", color: .gray),
        Row(id: "dev.vercel", title: "Vercel", detail: "Latest deployment state. Needs a token in the Developer tab.", symbol: "triangle.fill", color: .white),
        Row(id: "hud", title: "Volume & brightness", detail: "Level bar when you press the volume or brightness keys.", symbol: "speaker.wave.2.fill", color: .gray),
    ]

    var body: some View {
        Form {
            Section {
                ForEach(rows) { row in
                    Toggle(isOn: binding(for: row.id)) {
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.title)
                                Text(row.detail).font(.footnote).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: row.symbol).foregroundStyle(row.color).frame(width: 22)
                        }
                    }
                }
            } header: {
                Text("Show in the island")
            }

            Section {
                Toggle("Show Atoll's HUD for volume and brightness", isOn: $settings.replaceSystemHUD)
            } footer: {
                Text("macOS keeps drawing its own on-screen display; Atoll shows its HUD alongside it.")
            }

            CaptureClipboardSettings()
        }
        .formStyle(.grouped)
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { !settings.disabledActivities.contains(id) },
            set: { on in
                if on { settings.disabledActivities.remove(id) } else { settings.disabledActivities.insert(id) }
            }
        )
    }
}

// MARK: - Appearance

@MainActor
private struct AppearanceSettings: View {
    @Bindable private var settings = AtollSettings.shared

    var body: some View {
        Form {
            Section {
                Picker("Material", selection: $settings.appearance) {
                    Text("Pure black").tag(AppearanceMode.pureBlack)
                    Text("Glass").tag(AppearanceMode.glass)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Island")
            } footer: {
                Text("Pure black matches the iPhone. Glass adds a subtle material that reads better on bright wallpapers.")
            }

            Section("Behaviour") {
                Toggle("Reduce motion", isOn: $settings.reduceMotion)
                Toggle("Hide idle pill", isOn: $settings.hideIdlePill)
                Toggle("Haptic feedback", isOn: $settings.haptics)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - About

@MainActor
private struct AboutSettings: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 12)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
            Text("Atoll")
                .font(.system(size: 28, weight: .heavy, design: .rounded))
            Text(version)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("A software Dynamic Island for any Mac display.")
                .multilineTextAlignment(.center)
            Link("github.com/max-pantom/atoll", destination: URL(string: "https://github.com/max-pantom/atoll")!)

            Divider().padding(.horizontal, 60).padding(.top, 6)

            VStack(spacing: 4) {
                Text("Credits").font(.headline)
                Text("Now Playing on macOS 15.4 and later uses ungive/mediaremote-adapter, BSD 3-Clause licence.")
                Text("Glyphs are SF Symbols.")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
