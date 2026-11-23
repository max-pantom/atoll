// Quick capture: global hotkey opens the island with a text field. Return saves an Apple Note, ⌘Return a Reminder.
import SwiftUI
import AppKit
import EventKit
import Carbon.HIToolbox

@MainActor
@Observable
final class QuickCaptureActivity: IslandActivity {
    enum Phase: Equatable { case idle, capturing, saving, done(String), failed(String) }

    static let shared = QuickCaptureActivity()

    let id = "quickCapture"
    let priority = 90
    let hotKeyPref = HotKeyPref(key: "quickCapture.hotkey",
                                default: KeyCombo(keyCode: UInt32(kVK_ANSI_N), mods: UInt32(cmdKey | optionKey), label: "N"))

    private(set) var phase: Phase = .idle
    var draft = ""

    @ObservationIgnored private var hotKey: GlobalHotKey?
    @ObservationIgnored private var previousApp: NSRunningApplication?
    @ObservationIgnored private var started = false

    private init() {}

    // MARK: IslandActivity

    var isActive: Bool { phase != .idle }
    var tint: Color { AtollPalette.orange }
    var compactSideWidth: CGFloat { 34 }
    var expandedHeight: CGFloat { 84 }

    func compactLeading() -> AnyView { AnyView(CaptureGlyph(activity: self).compactSlot(.leading, width: compactSideWidth)) }
    func compactTrailing() -> AnyView { AnyView(EmptyView().compactSlot(.trailing, width: compactSideWidth)) }
    func minimal() -> AnyView { AnyView(CaptureGlyph(activity: self).minimalSlot()) }
    func expanded() -> AnyView { AnyView(CaptureExpanded(activity: self).expandedSlot(height: expandedHeight)) }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        hotKey = GlobalHotKey { [weak self] in self?.summon() }
        hotKeyPref.onChange = { [weak self] in self?.applyEnabled(AtollSettings.shared.isEnabled("quickCapture")) }
        trackEnabled(id) { [weak self] on in self?.applyEnabled(on) }
    }

    private func applyEnabled(_ on: Bool) {
        if on {
            hotKey?.register(hotKeyPref.combo)
        } else {
            hotKey?.unregister()
            if phase != .idle { reset() }
        }
    }

    /// Opens the island with a focused text field.
    func summon(prefill: String = "") {
        guard AtollSettings.shared.isEnabled(id), !IslandModel.shared.isPaused else { return }
        if phase == .saving { return }
        if previousApp == nil {
            let front = NSWorkspace.shared.frontmostApplication
            previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        }
        draft = prefill
        phase = .capturing
        IslandModel.shared.expand(id: id)
    }

    /// Called by the expanded view when it appears: take keyboard focus.
    func takeKeyboard() {
        NSApp.activate()
        NSApp.windows.first(where: { $0 is IslandPanel })?.makeKey()
    }

    func cancel(restoreFocus: Bool) {
        let app = previousApp
        reset()
        if restoreFocus { app?.activate() }
        IslandModel.shared.collapse()
    }

    /// The expanded view went away (outside click, hover-out): drop the capture without stealing focus back.
    func viewDisappeared() {
        switch phase {
        case .capturing, .failed: reset()
        default: break
        }
    }

    private func reset() {
        phase = .idle
        draft = ""
        previousApp = nil
    }

    // MARK: Saving

    func save(asReminder: Bool) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, phase != .saving else { return }
        phase = .saving
        Task { @MainActor in
            let result: Result<String, CaptureError>
            if asReminder {
                result = await Self.saveReminder(text)
            } else {
                result = await Self.saveNote(text)
            }
            switch result {
            case .success(let message): finish(message)
            case .failure(let error): phase = .failed(error.message)
            }
        }
    }

    private func finish(_ message: String) {
        phase = .done(message)
        Haptics.tap(.levelChange)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            guard let self, case .done = self.phase else { return }
            self.cancel(restoreFocus: true)
        }
    }

    struct CaptureError: Error { let message: String }

    private static var isDemo: Bool { CommandLine.arguments.contains { $0.hasPrefix("--demo") } }

    // MARK: Notes (AppleScript, off the main thread)

    private static func saveNote(_ text: String) async -> Result<String, CaptureError> {
        if isDemo { return .success("Saved to Notes") }
        let html = noteHTML(text)
        let source = "tell application \"Notes\" to make new note with properties {body:\"\(appleScriptEscaped(html))\"}"
        return await Task.detached(priority: .userInitiated) { () -> Result<String, CaptureError> in
            var error: NSDictionary?
            guard let script = NSAppleScript(source: source) else {
                return .failure(CaptureError(message: "Could not talk to Notes"))
            }
            script.executeAndReturnError(&error)
            guard let error else { return .success("Saved to Notes") }
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            if code == -1743 {
                return .failure(CaptureError(message: "Allow Atoll to control Notes in System Settings › Privacy › Automation"))
            }
            return .failure(CaptureError(message: "Notes error \(code)"))
        }.value
    }

    private static func noteHTML(_ text: String) -> String {
        func esc(_ s: Substring) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first else { return "" }
        return "<div><h1>\(esc(first))</h1></div>" + lines.dropFirst().map { "<div>\(esc($0))</div>" }.joined()
    }

    private static func appleScriptEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: Reminders (EventKit)

    private static func saveReminder(_ text: String) async -> Result<String, CaptureError> {
        if isDemo { return .success("Reminder added") }
        let store = EKEventStore()
        let granted = (try? await store.requestFullAccessToReminders()) ?? false
        guard granted else {
            return .failure(CaptureError(message: "Allow Reminders access in System Settings › Privacy"))
        }
        guard let list = store.defaultCalendarForNewReminders() else {
            return .failure(CaptureError(message: "No default Reminders list"))
        }
        let parsed = parseDate(in: text)
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = list
        reminder.title = parsed.title
        if let date = parsed.date {
            let units: Set<Calendar.Component> = parsed.hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
            reminder.dueDateComponents = Calendar.current.dateComponents(units, from: date)
            if parsed.hasTime { reminder.addAlarm(EKAlarm(absoluteDate: date)) }
        }
        do {
            try store.save(reminder, commit: true)
            return .success(parsed.date != nil ? "Reminder set" : "Reminder added")
        } catch {
            return .failure(CaptureError(message: "Could not save the reminder"))
        }
    }

    /// Natural-language date through NSDataDetector ("tomorrow 5pm", "friday"). Removes the matched phrase from the title.
    static func parseDate(in text: String) -> (title: String, date: Date?, hasTime: Bool) {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let match = detector.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)),
              let date = match.date, let range = Range(match.range, in: text) else {
            return (text, nil, false)
        }
        let phrase = text[range].lowercased()
        let timeWords = [":", "am", "pm", "noon", "midnight", "morning", "evening", "night", "hour", "min"]
        let hasTime = timeWords.contains { phrase.contains($0) }
        var title = text
        title.removeSubrange(range)
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for word in ["at", "on", "by", "for", "due", "in"] where title.lowercased().hasSuffix(" " + word) {
            title = String(title.dropLast(word.count)).trimmingCharacters(in: .whitespaces)
        }
        return (title.isEmpty ? text : title, date, hasTime)
    }
}

// MARK: - Views

private struct CaptureGlyph: View {
    let activity: QuickCaptureActivity
    var body: some View {
        let done: Bool = { if case .done = activity.phase { return true } else { return false } }()
        Image(systemName: done ? "checkmark.circle.fill" : "square.and.pencil")
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(done ? AtollPalette.green : AtollPalette.orange)
            .contentTransition(.symbolEffect(.replace))
    }
}

private struct CaptureExpanded: View {
    let activity: QuickCaptureActivity
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var activity = activity
        Group {
            if case .done(let message) = activity.phase {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(AtollPalette.green)
                        .symbolEffect(.bounce, value: message)
                    Text(message).font(.island(20))
                    Spacer(minLength: 0)
                }
                .transition(.opacity)
            } else {
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(AtollPalette.orange)
                        TextField("Jot something down…", text: $activity.draft)
                            .textFieldStyle(.plain)
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .focused($focused)
                            .disabled(activity.phase == .saving)
                            .onSubmit { activity.save(asReminder: false) }
                            .onExitCommand { activity.cancel(restoreFocus: true) }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    .background(Capsule(style: .continuous).fill(Color.white.opacity(0.12)))

                    hint
                }
                .background(
                    // ⌘Return saves a reminder instead of a note.
                    Button("") { activity.save(asReminder: true) }
                        .keyboardShortcut(.return, modifiers: .command)
                        .opacity(0)
                        .frame(width: 0, height: 0)
                )
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.25), value: activity.phase)
        .task {
            activity.takeKeyboard()
            try? await Task.sleep(nanoseconds: 120_000_000)
            focused = true
        }
        .onDisappear { activity.viewDisappeared() }
    }

    @ViewBuilder
    private var hint: some View {
        if case .failed(let message) = activity.phase {
            Text(message)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AtollPalette.red)
                .lineLimit(2)
        } else {
            HStack(spacing: 16) {
                Text("↩  Note")
                Text("⌘↩  Reminder")
                Text("esc  Cancel")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.5))
        }
    }
}
