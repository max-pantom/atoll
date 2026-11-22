// Volume and brightness HUDs. The system OSD cannot be hidden without private hacks, so Atoll shows
// alongside it (only when AtollSettings.replaceSystemHUD is on).
import SwiftUI
import AppKit
import CoreAudio
import CoreGraphics

@MainActor
@Observable
final class HUDActivity: IslandActivity {
    enum Kind { case volume, brightness }

    static let volume = HUDActivity(kind: .volume)
    static let brightness = HUDActivity(kind: .brightness)

    /// Starts the system listeners. Safe to call more than once.
    static func startMonitoring() {
        volume.startVolume()
        brightness.startBrightness()
    }

    let kind: Kind
    private(set) var level: Double = 0.5
    private(set) var muted = false
    private(set) var isShowing = false

    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var volumeMonitor: VolumeMonitor?
    @ObservationIgnored private var brightnessTimer: Timer?
    @ObservationIgnored private var brightnessDisplay: CGDirectDisplayID = 0
    @ObservationIgnored private var lastBrightness: Float?

    private init(kind: Kind) { self.kind = kind }

    // MARK: IslandActivity

    var id: String { kind == .volume ? "hud.volume" : "hud.brightness" }
    let priority = 100
    var isActive: Bool { isShowing && AtollSettings.shared.replaceSystemHUD }
    var tint: Color { .white }
    var compactSideWidth: CGFloat { 62 }
    var expandedHeight: CGFloat { 64 }

    func compactLeading() -> AnyView { AnyView(HUDGlyphView(hud: self).compactSlot(.leading, width: compactSideWidth)) }
    func compactTrailing() -> AnyView {
        AnyView(HUDLevelBar(hud: self, width: 36).compactSlot(.trailing, width: compactSideWidth))
    }
    func minimal() -> AnyView { AnyView(HUDGlyphView(hud: self, size: 14).minimalSlot()) }
    func expanded() -> AnyView {
        AnyView(
            HStack(spacing: 14) {
                HUDGlyphView(hud: self, size: 22)
                HUDLevelBar(hud: self, width: nil)
            }
            .expandedSlot(height: expandedHeight)
        )
    }

    var symbolName: String {
        switch kind {
        case .volume:
            if muted || level <= 0.001 { return "speaker.slash.fill" }
            return "speaker.wave.3.fill"
        case .brightness:
            return level < 0.2 ? "sun.min.fill" : "sun.max.fill"
        }
    }

    // MARK: Showing

    fileprivate func present(level newLevel: Double, muted newMuted: Bool = false) {
        level = min(1, max(0, newLevel))
        muted = newMuted
        isShowing = true
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            self?.isShowing = false
        }
    }

    // MARK: Volume (CoreAudio listeners)

    private func startVolume() {
        guard volumeMonitor == nil else { return }
        let monitor = VolumeMonitor()
        monitor.onChange = { [weak self] level, muted in self?.present(level: level, muted: muted) }
        monitor.start()
        volumeMonitor = monitor
    }

    // MARK: Brightness (DisplayServices, private; optional)

    private typealias GetBrightnessFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32

    private func startBrightness() {
        guard brightnessTimer == nil,
              let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let sym = dlsym(handle, "DisplayServicesGetBrightness") else { return }
        let get = unsafeBitCast(sym, to: GetBrightnessFn.self)

        // Find a display that reports brightness (built-in panels). Mac mini + external monitor: none, no polling.
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        CGGetActiveDisplayList(16, &ids, &count)
        var found: CGDirectDisplayID?
        for d in ids.prefix(Int(count)) {
            var value: Float = 0
            if get(d, &value) == 0 { found = d; lastBrightness = value; break }
        }
        guard let display = found else { return }
        brightnessDisplay = display

        brightnessTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AtollSettings.shared.replaceSystemHUD else { return }
                var value: Float = 0
                guard get(self.brightnessDisplay, &value) == 0 else { return }
                if let last = self.lastBrightness, abs(last - value) < 0.002 { return }
                self.lastBrightness = value
                self.present(level: Double(value))
            }
        }
    }
}

// MARK: - Volume monitor

@MainActor
private final class VolumeMonitor {
    var onChange: ((Double, Bool) -> Void)?

    private var deviceID = AudioObjectID(0)
    private var deviceListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var systemBlock: AudioObjectPropertyListenerBlock?
    private var last: (level: Double, muted: Bool)?

    /// 'vmvc' = kAudioHardwareServiceDeviceProperty_VirtualMainVolume (the value the volume keys change).
    private static let virtualMainVolume: AudioObjectPropertySelector = 0x766D_7663

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    func start() {
        bindDevice()
        var addr = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.bindDevice() }
        }
        systemBlock = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
    }

    private func defaultOutputDevice() -> AudioObjectID {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return status == noErr ? id : 0
    }

    /// (Re)attaches listeners to the current default output device. Switching device is silent.
    private func bindDevice() {
        for (var addr, block) in deviceListeners where deviceID != 0 {
            AudioObjectRemovePropertyListenerBlock(deviceID, &addr, DispatchQueue.main, block)
        }
        deviceListeners = []
        deviceID = defaultOutputDevice()
        guard deviceID != 0 else { last = nil; return }

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.deviceChanged() }
        }
        let out = kAudioDevicePropertyScopeOutput
        let addresses = [
            Self.address(Self.virtualMainVolume, scope: out),
            Self.address(kAudioDevicePropertyVolumeScalar, scope: out, element: 1),
            Self.address(kAudioDevicePropertyMute, scope: out),
        ]
        for var a in addresses {
            guard AudioObjectHasProperty(deviceID, &a) else { continue }
            if AudioObjectAddPropertyListenerBlock(deviceID, &a, DispatchQueue.main, block) == noErr {
                deviceListeners.append((a, block))
            }
        }
        last = read()
    }

    private func deviceChanged() {
        guard let now = read() else { return }
        if let last, abs(last.level - now.level) < 0.001, last.muted == now.muted { return }
        last = now
        onChange?(now.level, now.muted)
    }

    private func read() -> (level: Double, muted: Bool)? {
        guard deviceID != 0 else { return nil }
        let out = kAudioDevicePropertyScopeOutput
        var level: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var vol = Self.address(Self.virtualMainVolume, scope: out)
        var ok = AudioObjectHasProperty(deviceID, &vol)
            && AudioObjectGetPropertyData(deviceID, &vol, 0, nil, &size, &level) == noErr
        if !ok {
            var ch = Self.address(kAudioDevicePropertyVolumeScalar, scope: out, element: 1)
            size = UInt32(MemoryLayout<Float32>.size)
            ok = AudioObjectHasProperty(deviceID, &ch)
                && AudioObjectGetPropertyData(deviceID, &ch, 0, nil, &size, &level) == noErr
        }
        guard ok else { return nil }

        var muteValue: UInt32 = 0
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        var mute = Self.address(kAudioDevicePropertyMute, scope: out)
        if AudioObjectHasProperty(deviceID, &mute) {
            _ = AudioObjectGetPropertyData(deviceID, &mute, 0, nil, &muteSize, &muteValue)
        }
        return (Double(level), muteValue != 0)
    }
}

// MARK: - Views

private struct HUDGlyphView: View {
    let hud: HUDActivity
    var size: CGFloat = 16

    var body: some View {
        Group {
            if hud.kind == .volume && !hud.muted && hud.level > 0.001 {
                Image(systemName: "speaker.wave.3.fill", variableValue: hud.level)
            } else {
                Image(systemName: hud.symbolName)
            }
        }
        .font(.system(size: size, weight: .semibold))
        .foregroundStyle(.white)
        .contentTransition(.symbolEffect(.replace))
        .animation(.smooth(duration: 0.2), value: hud.symbolName)
    }
}

private struct HUDLevelBar: View {
    let hud: HUDActivity
    /// nil = fill the available width.
    let width: CGFloat?

    var body: some View {
        let s = ActivityMetrics.scale
        let shown = hud.muted ? 0 : hud.level
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous).fill(Color.white.opacity(0.25))
                Capsule(style: .continuous)
                    .fill(Color.white)
                    .frame(width: max(0, geo.size.width * shown))
            }
        }
        .frame(width: width.map { $0 * s }, height: 5 * s)
        .animation(.smooth(duration: 0.15), value: shown)
    }
}
