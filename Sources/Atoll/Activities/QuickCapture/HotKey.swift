// Global hotkeys through Carbon's RegisterEventHotKey: needs no Accessibility or Input Monitoring permission.
import SwiftUI
import AppKit
import Carbon.HIToolbox

struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var mods: UInt32     // Carbon modifier mask (cmdKey, optionKey, ...)
    var label: String

    var display: String {
        var s = ""
        if mods & UInt32(controlKey) != 0 { s += "⌃" }
        if mods & UInt32(optionKey) != 0 { s += "⌥" }
        if mods & UInt32(shiftKey) != 0 { s += "⇧" }
        if mods & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + label
    }

    static func carbonMods(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    static func label(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default: return (event.charactersIgnoringModifiers ?? "?").uppercased()
        }
    }
}

/// A user-changeable shortcut persisted in UserDefaults.
@MainActor
@Observable
final class HotKeyPref {
    private let key: String
    var combo: KeyCombo {
        didSet {
            if let data = try? JSONEncoder().encode(combo) { UserDefaults.standard.set(data, forKey: key) }
            onChange?()
        }
    }
    @ObservationIgnored var onChange: (() -> Void)?

    init(key: String, default fallback: KeyCombo) {
        self.key = key
        if let data = UserDefaults.standard.data(forKey: key), let c = try? JSONDecoder().decode(KeyCombo.self, from: data) {
            combo = c
        } else {
            combo = fallback
        }
    }
}

@MainActor
final class GlobalHotKey {
    private static var handlerInstalled = false
    private static var table: [UInt32: GlobalHotKey] = [:]
    private static var nextID: UInt32 = 1

    private let id: UInt32
    private var ref: EventHotKeyRef?
    private let handler: () -> Void

    init(handler: @escaping () -> Void) {
        id = Self.nextID
        Self.nextID += 1
        self.handler = handler
        Self.table[id] = self
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
    }

    func register(_ combo: KeyCombo) {
        unregister()
        Self.installHandlerOnce()
        let hkID = EventHotKeyID(signature: OSType(0x41544C4C), id: id)
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, combo.mods, hkID, GetApplicationEventTarget(), 0, &newRef)
        if status == noErr { ref = newRef }
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    private static func installHandlerOnce() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            Task { @MainActor in GlobalHotKey.table[id]?.handler() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// Click, then press the new shortcut. Needs at least one of ⌘ ⌥ ⌃. Esc cancels.
struct HotKeyRecorder: View {
    let pref: HotKeyPref
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(recording ? "Press shortcut…" : pref.combo.display) { recording ? stop() : start() }
            .monospacedDigit()
            .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) { stop(); return nil }
            let mods = KeyCombo.carbonMods(event.modifierFlags)
            guard mods & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }
            pref.combo = KeyCombo(keyCode: UInt32(event.keyCode), mods: mods, label: KeyCombo.label(for: event))
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Re-runs `apply` whenever the user flips the activity's Settings toggle. Also runs it once now.
@MainActor
func trackEnabled(_ id: String, _ apply: @escaping @MainActor (Bool) -> Void) {
    func arm() {
        withObservationTracking {
            _ = AtollSettings.shared.disabledActivities
            _ = AtollSettings.shared.demoEnabled
        } onChange: {
            Task { @MainActor in
                apply(AtollSettings.shared.isEnabled(id))
                arm()
            }
        }
    }
    apply(AtollSettings.shared.isEnabled(id))
    arm()
}
