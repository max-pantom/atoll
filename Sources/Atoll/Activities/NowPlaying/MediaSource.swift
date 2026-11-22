// Now Playing sources, tried in order by NowPlayingActivity:
//   1. AdapterSource      – ungive/mediaremote-adapter through /usr/bin/perl (works on macOS 15.4+)
//   2. MediaRemoteSource  – private MediaRemote.framework via dlopen (macOS ≤ 15.3)
//   3. AppleScriptSource  – Music / Spotify polling fallback
import Foundation
import AppKit

struct NowPlayingInfo: Equatable {
    var title = ""
    var artist = ""
    var album = ""
    var duration: Double = 0
    /// Elapsed seconds as of `timestamp`.
    var elapsed: Double = 0
    var rate: Double = 1
    var playing = false
    var artwork: Data?
    var bundleID: String?
    var timestamp = Date()

    var hasContent: Bool { !title.isEmpty || !artist.isEmpty }
    var trackKey: String { "\(title)|\(artist)|\(album)" }

    /// Extrapolated playback position.
    func position(at date: Date = Date()) -> Double {
        var p = elapsed
        if playing { p += max(0, date.timeIntervalSince(timestamp)) * rate }
        if duration > 0 { p = min(p, duration) }
        return max(0, p)
    }
}

/// Values match both the adapter's `send` ids and MRMediaRemoteCommand.
enum MediaCommand: Int {
    case play = 0, pause = 1, toggle = 2, next = 4, previous = 5
}

@MainActor
protocol MediaSource: AnyObject {
    var name: String { get }
    var onUpdate: ((NowPlayingInfo?) -> Void)? { get set }
    /// Called when the source cannot work at all, so the next one should be tried.
    var onFailure: (() -> Void)? { get set }
    /// Returns false when the source is unavailable on this system.
    func start() -> Bool
    func stop()
    func send(_ command: MediaCommand)
    func seek(to seconds: Double)
}

// MARK: - 1. mediaremote-adapter

/// Splits a byte stream into lines; used off the main thread.
private final class LineReader: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()
    private let handler: @Sendable (String) -> Void

    init(handler: @escaping @Sendable (String) -> Void) { self.handler = handler }

    func feed(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [String] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            if let s = String(data: lineData, encoding: .utf8), !s.isEmpty { lines.append(s) }
        }
        lock.unlock()
        for l in lines { handler(l) }
    }
}

@MainActor
final class AdapterSource: MediaSource {
    let name = "adapter"
    var onUpdate: ((NowPlayingInfo?) -> Void)?
    var onFailure: (() -> Void)?

    private var process: Process?
    private var startedAt = Date()
    private var stopped = false
    private var state: [String: Any] = [:]
    private var artworkData: Data?
    private var gotData = false
    private var outHandle: FileHandle?

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    /// Script + framework inside the app bundle (scripts/bundle.sh puts them in Resources/MediaRemoteAdapter).
    static func locate() -> (script: String, framework: String)? {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("MediaRemoteAdapter") else { return nil }
        let script = dir.appendingPathComponent("mediaremote-adapter.pl").path
        let framework = dir.appendingPathComponent("MediaRemoteAdapter.framework").path
        let fm = FileManager.default
        guard fm.fileExists(atPath: script), fm.fileExists(atPath: framework),
              fm.isExecutableFile(atPath: "/usr/bin/perl") else { return nil }
        return (script, framework)
    }

    func start() -> Bool {
        stopped = false
        gotData = false
        guard process == nil, let paths = Self.locate() else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [paths.script, paths.framework, "stream"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice

        let reader = LineReader { [weak self] line in
            Task { @MainActor in self?.handle(line: line) }
        }
        outHandle = out.fileHandleForReading
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            reader.feed(data)
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { @MainActor in self?.terminated(status: status) }
        }
        do { try p.run() } catch { return false }
        process = p
        startedAt = Date()
        // If the helper stays alive but never reports, let the AppleScript fallback take over
        // (only when a scriptable player is running, otherwise silence is normal).
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, !self.stopped, self.process === p, !self.gotData else { return }
            let players = ["com.apple.Music", "com.spotify.client"]
            if NSWorkspace.shared.runningApplications.contains(where: { players.contains($0.bundleIdentifier ?? "") }) {
                self.onFailure?()
            }
        }
        return true
    }

    func stop() {
        stopped = true
        outHandle?.readabilityHandler = nil
        outHandle = nil
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        state = [:]
        artworkData = nil
    }

    private func terminated(status: Int32) {
        process = nil
        guard !stopped else { return }
        if Date().timeIntervalSince(startedAt) < 5 {
            onFailure?()                       // died right away: helper unusable
        } else {
            onUpdate?(nil)
            Task { @MainActor [weak self] in   // crashed later: restart
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, !self.stopped else { return }
                if !self.start() { self.onFailure?() }
            }
        }
    }

    private func handle(line: String) {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if let type = obj["type"] as? String, type != "data" { return }
        gotData = true
        let payload = (obj["payload"] as? [String: Any]) ?? obj
        let diff = (obj["diff"] as? Bool) ?? false

        if !diff { state = [:]; artworkData = nil }
        for (key, value) in payload {
            if key == "artworkData" {
                if let s = value as? String { artworkData = Data(base64Encoded: s, options: .ignoreUnknownCharacters) }
                else { artworkData = nil }
                continue
            }
            if value is NSNull { state.removeValue(forKey: key) } else { state[key] = value }
        }
        onUpdate?(makeInfo())
    }

    private func makeInfo() -> NowPlayingInfo? {
        let title = state["title"] as? String ?? ""
        let artist = state["artist"] as? String ?? ""
        if title.isEmpty && artist.isEmpty { return nil }
        var info = NowPlayingInfo()
        info.title = title
        info.artist = artist
        info.album = state["album"] as? String ?? ""
        info.duration = (state["duration"] as? NSNumber)?.doubleValue ?? 0
        info.elapsed = (state["elapsedTime"] as? NSNumber)?.doubleValue ?? 0
        info.playing = (state["playing"] as? Bool) ?? ((state["playing"] as? NSNumber)?.boolValue ?? false)
        info.bundleID = state["bundleIdentifier"] as? String
        info.artwork = artworkData
        if let ts = state["timestamp"] as? String {
            info.timestamp = Self.isoFractional.date(from: ts) ?? Self.iso.date(from: ts) ?? Date()
        } else if let ts = (state["timestamp"] as? NSNumber)?.doubleValue {
            info.timestamp = Date(timeIntervalSince1970: ts)
        }
        return info
    }

    func send(_ command: MediaCommand) { run(["send", String(command.rawValue)]) }
    func seek(to seconds: Double) { run(["seek", String(Int(max(0, seconds) * 1_000_000))]) }

    private func run(_ args: [String]) {
        guard let paths = Self.locate() else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [paths.script, paths.framework] + args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}

// MARK: - 2. MediaRemote (private framework)

@MainActor
final class MediaRemoteSource: MediaSource {
    let name = "mediaremote"
    var onUpdate: ((NowPlayingInfo?) -> Void)?
    var onFailure: (() -> Void)?

    private typealias GetInfoFn = @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
    private typealias RegisterFn = @convention(c) (DispatchQueue) -> Void
    private typealias SendFn = @convention(c) (UInt32, CFDictionary?) -> Bool
    private typealias SetElapsedFn = @convention(c) (Double) -> Void

    private var getInfo: GetInfoFn?
    private var sendCommand: SendFn?
    private var setElapsed: SetElapsedFn?
    private var observers: [NSObjectProtocol] = []
    private var poll: Timer?

    func start() -> Bool {
        // From macOS 15.4 mediaremoted only answers Apple-signed clients: reads return nothing.
        if ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 15, minorVersion: 4, patchVersion: 0)) {
            return false
        }
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY),
              let g = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo"),
              let r = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications"),
              let s = dlsym(handle, "MRMediaRemoteSendCommand") else { return false }
        getInfo = unsafeBitCast(g, to: GetInfoFn.self)
        sendCommand = unsafeBitCast(s, to: SendFn.self)
        if let e = dlsym(handle, "MRMediaRemoteSetElapsedTime") { setElapsed = unsafeBitCast(e, to: SetElapsedFn.self) }
        unsafeBitCast(r, to: RegisterFn.self)(DispatchQueue.main)

        for n in ["kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                  "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"] {
            let token = NotificationCenter.default.addObserver(forName: Notification.Name(n), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            observers.append(token)
        }
        poll = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
        return true
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        poll?.invalidate(); poll = nil
    }

    private func refresh() {
        getInfo?(DispatchQueue.main) { [weak self] dict in
            let snapshot = dict as? [String: Any]
            Task { @MainActor in self?.apply(snapshot) }
        }
    }

    private func apply(_ d: [String: Any]?) {
        guard let d, let title = d["kMRMediaRemoteNowPlayingInfoTitle"] as? String, !title.isEmpty else {
            onUpdate?(nil); return
        }
        var info = NowPlayingInfo()
        info.title = title
        info.artist = d["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
        info.album = d["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? ""
        info.duration = (d["kMRMediaRemoteNowPlayingInfoDuration"] as? NSNumber)?.doubleValue ?? 0
        info.elapsed = (d["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? NSNumber)?.doubleValue ?? 0
        let rate = (d["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? 0
        info.rate = rate > 0 ? rate : 1
        info.playing = rate > 0
        info.artwork = d["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data
        info.timestamp = d["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date ?? Date()
        onUpdate?(info)
    }

    func send(_ command: MediaCommand) {
        _ = sendCommand?(UInt32(command.rawValue), nil)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            self?.refresh()
        }
    }

    func seek(to seconds: Double) { setElapsed?(seconds) }
}

// MARK: - 3. AppleScript (Music, Spotify)

private struct ScriptResult: @unchecked Sendable {
    var desc: NSAppleEventDescriptor?
    var errorNumber: Int?
}

private let appleScriptQueue = DispatchQueue(label: "atoll.applescript", qos: .utility)

private func runAppleScript(_ source: String) -> ScriptResult {
    var err: NSDictionary?
    guard let script = NSAppleScript(source: source) else { return ScriptResult() }
    let result = script.executeAndReturnError(&err)
    if let err { return ScriptResult(desc: nil, errorNumber: (err[NSAppleScript.errorNumber] as? NSNumber)?.intValue) }
    return ScriptResult(desc: result, errorNumber: nil)
}

@MainActor
final class AppleScriptSource: MediaSource {
    let name = "applescript"
    var onUpdate: ((NowPlayingInfo?) -> Void)?
    var onFailure: (() -> Void)?

    private enum Player: CaseIterable {
        case music, spotify
        var appName: String { self == .music ? "Music" : "Spotify" }
        var bundleID: String { self == .music ? "com.apple.Music" : "com.spotify.client" }
    }

    private var timer: Timer?
    private var current: Player?
    private var denied: Set<String> = []
    private var artKey = ""
    private var artData: Data?
    private var artTask: Task<Void, Never>?
    private var polling = false
    private var published: NowPlayingInfo?

    func start() -> Bool {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
        return true
    }

    func stop() {
        timer?.invalidate(); timer = nil
        artTask?.cancel()
    }

    private func isRunning(_ p: Player) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == p.bundleID }
    }

    private func tick() {
        guard !polling else { return }
        polling = true
        Task { @MainActor [weak self] in
            await self?.poll()
            self?.polling = false
        }
    }

    private func poll() async {
        var chosen: (Player, NowPlayingInfo)?
        for p in Player.allCases where isRunning(p) && !denied.contains(p.bundleID) {
            guard let info = await query(p) else { continue }
            if chosen == nil || (info.playing && chosen?.1.playing == false) { chosen = (p, info) }
        }
        guard timer != nil else { return }   // stopped while waiting
        guard var (player, info) = chosen else {
            current = nil
            if published != nil { published = nil; onUpdate?(nil) }
            return
        }
        current = player
        if info.trackKey != artKey {
            artKey = info.trackKey
            artData = nil
            await loadArtwork(for: player, key: artKey)
        }
        info.artwork = artData
        publish(info)
    }

    /// Only publish when something observable changed, so views do not re-render every second.
    private func publish(_ info: NowPlayingInfo) {
        if let old = published,
           old.trackKey == info.trackKey, old.playing == info.playing, old.duration == info.duration,
           old.artwork?.count == info.artwork?.count,
           abs(old.position(at: info.timestamp) - info.elapsed) <= 1.5 {
            return
        }
        published = info
        onUpdate?(info)
    }

    private func script(for p: Player) -> String {
        switch p {
        case .music:
            return """
            tell application "Music"
              if player state is stopped then return {}
              set t to current track
              return {name of t, artist of t, album of t, (duration of t * 1000) as integer, (player position * 1000) as integer, (player state as text)}
            end tell
            """
        case .spotify:
            return """
            tell application "Spotify"
              if player state is stopped then return {}
              set t to current track
              return {name of t, artist of t, album of t, duration of t, (player position * 1000) as integer, (player state as text), artwork url of t}
            end tell
            """
        }
    }

    /// NSAppleScript is confined to one serial queue so a slow player never blocks the main thread.
    private func execute(_ source: String) async -> ScriptResult {
        await withCheckedContinuation { cont in
            appleScriptQueue.async { cont.resume(returning: runAppleScript(source)) }
        }
    }

    private func query(_ p: Player) async -> NowPlayingInfo? {
        let result = await execute(script(for: p))
        let (desc, errorNumber) = (result.desc, result.errorNumber)
        if errorNumber == -1743 { denied.insert(p.bundleID); return nil }   // Automation permission refused
        guard let desc, desc.numberOfItems >= 6 else { return nil }
        var info = NowPlayingInfo()
        info.title = desc.atIndex(1)?.stringValue ?? ""
        info.artist = desc.atIndex(2)?.stringValue ?? ""
        info.album = desc.atIndex(3)?.stringValue ?? ""
        info.duration = Double(desc.atIndex(4)?.int32Value ?? 0) / 1000
        info.elapsed = Double(desc.atIndex(5)?.int32Value ?? 0) / 1000
        info.playing = (desc.atIndex(6)?.stringValue ?? "").lowercased().contains("playing")
        info.bundleID = p.bundleID
        info.timestamp = Date()
        if p == .spotify, desc.numberOfItems >= 7, let url = desc.atIndex(7)?.stringValue { spotifyArtURL = url }
        return info.hasContent ? info : nil
    }

    private var spotifyArtURL: String?

    private func loadArtwork(for p: Player, key: String) async {
        artTask?.cancel()
        switch p {
        case .music:
            let desc = await execute("""
            tell application "Music"
              try
                return data of artwork 1 of current track
              on error
                return missing value
              end try
            end tell
            """).desc
            if let data = desc?.data, data.count > 16 { artData = data }
        case .spotify:
            guard let s = spotifyArtURL, let url = URL(string: s) else { return }
            artTask = Task { @MainActor [weak self] in
                guard let (data, _) = try? await URLSession.shared.data(from: url), !Task.isCancelled else { return }
                guard let self, self.artKey == key else { return }
                self.artData = data
                self.tick()
            }
        }
    }

    func send(_ command: MediaCommand) {
        guard let p = current else { return }
        let verb: String
        switch command {
        case .play: verb = "play"
        case .pause: verb = "pause"
        case .toggle: verb = "playpause"
        case .next: verb = "next track"
        case .previous: verb = "previous track"
        }
        let src = "tell application \"\(p.appName)\" to \(verb)"
        Task { @MainActor [weak self] in
            _ = await self?.execute(src)
            self?.tick()
        }
    }

    func seek(to seconds: Double) {
        guard let p = current else { return }
        let src = "tell application \"\(p.appName)\" to set player position to \(Int(seconds))"
        Task { @MainActor [weak self] in _ = await self?.execute(src) }
    }
}
