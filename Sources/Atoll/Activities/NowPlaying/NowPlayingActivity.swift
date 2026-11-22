// Now Playing: compact artwork + live waveform, minimal artwork bubble, expanded player.
import SwiftUI
import AppKit

@MainActor
@Observable
final class NowPlayingActivity: IslandActivity {
    static let shared = NowPlayingActivity()

    let id = "nowPlaying"
    let priority = 50

    private(set) var info: NowPlayingInfo?
    private(set) var artwork: NSImage?
    private(set) var artworkColor: Color = .white
    /// Bumped whenever the artwork changes, so views can cross-fade.
    private(set) var artworkVersion = 0
    private(set) var pausedExpired = false

    @ObservationIgnored private var source: MediaSource?
    @ObservationIgnored private var sourceIndex = -1
    @ObservationIgnored private var started = false
    @ObservationIgnored private var lastArtwork: Data?
    @ObservationIgnored private var pauseTask: Task<Void, Never>?

    private init() {}

    // MARK: IslandActivity

    var isActive: Bool {
        guard let i = info, i.hasContent else { return false }
        return i.playing || !pausedExpired
    }
    var tint: Color { artworkColor }
    var compactSideWidth: CGFloat { 46 }
    var expandedHeight: CGFloat { info == nil ? Activities.idleExpandedHeight : 156 }

    func compactLeading() -> AnyView { AnyView(NowPlayingCompactLeading(activity: self)) }
    func compactTrailing() -> AnyView { AnyView(NowPlayingCompactTrailing(activity: self)) }
    func minimal() -> AnyView { AnyView(NowPlayingMinimal(activity: self)) }
    func expanded() -> AnyView { AnyView(NowPlayingExpanded(activity: self)) }

    // MARK: Sources

    func start() {
        guard !started else { return }
        started = true
        advance()
    }

    /// Stops the media source (and its helper process) on quit.
    func stop() {
        source?.stop()
        source = nil
    }

    private func makeSource(_ index: Int) -> MediaSource? {
        switch index {
        case 0: return AdapterSource()
        case 1: return MediaRemoteSource()
        case 2: return AppleScriptSource()
        default: return nil
        }
    }

    /// Starts the next source in order that is available on this system.
    private func advance() {
        source?.stop()
        source = nil
        while let candidate = makeSource(sourceIndex + 1) {
            sourceIndex += 1
            candidate.onUpdate = { [weak self] info in self?.apply(info) }
            candidate.onFailure = { [weak self] in self?.advance() }
            if candidate.start() { source = candidate; return }
        }
        apply(nil)
    }

    private func apply(_ new: NowPlayingInfo?) {
        let old = info
        let next = (new?.hasContent == true) ? new : nil
        if next != old { info = next }

        if let data = next?.artwork, !data.isEmpty {
            if data != lastArtwork, let image = NSImage(data: data) {
                lastArtwork = data
                artwork = image
                artworkColor = ArtworkColor.vibrant(from: image)
                artworkVersion &+= 1
            }
        } else if next == nil || next?.trackKey != old?.trackKey {
            if artwork != nil { artwork = nil; lastArtwork = nil; artworkColor = .white; artworkVersion &+= 1 }
        }

        if next?.playing == true {
            pauseTask?.cancel(); pauseTask = nil
            if pausedExpired { pausedExpired = false }
        } else if next != nil, pauseTask == nil {
            // iOS keeps a paused activity around for a while, then lets it go.
            pauseTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { return }
                self?.pausedExpired = true
            }
        } else if next == nil {
            pauseTask?.cancel(); pauseTask = nil
            pausedExpired = false
        }
    }

    // MARK: Controls

    func send(_ command: MediaCommand) {
        source?.send(command)
        guard var i = info else { return }
        switch command {
        case .toggle: rebase(&i); i.playing.toggle()
        case .play: rebase(&i); i.playing = true
        case .pause: rebase(&i); i.playing = false
        case .next, .previous: break
        }
        info = i
    }

    func seek(to seconds: Double) {
        source?.seek(to: seconds)
        guard var i = info else { return }
        i.elapsed = seconds
        i.timestamp = Date()
        info = i
    }

    private func rebase(_ i: inout NowPlayingInfo) {
        i.elapsed = i.position()
        i.timestamp = Date()
    }
}

// MARK: - Artwork

private struct ArtworkView: View {
    let image: NSImage?
    let version: Int
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .id(version)
                    .transition(.islandContent)
            } else {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.white.opacity(0.14))
                    .frame(width: size, height: size)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: size * 0.42, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.55))
                    )
            }
        }
        .frame(width: size, height: size)
        .animation(.smooth(duration: 0.3), value: version)
    }
}

// MARK: - Compact / minimal

private struct NowPlayingCompactLeading: View {
    let activity: NowPlayingActivity
    var body: some View {
        let s = ActivityMetrics.scale
        ArtworkView(image: activity.artwork, version: activity.artworkVersion, size: 24 * s, radius: 6 * s)
            .compactSlot(.leading, width: activity.compactSideWidth)
    }
}

private struct NowPlayingCompactTrailing: View {
    let activity: NowPlayingActivity
    var body: some View {
        let s = ActivityMetrics.scale
        WaveformView(playing: activity.info?.playing == true,
                     tint: activity.artworkColor,
                     barCount: 5, barWidth: 3 * s, spacing: 2.5 * s, maxHeight: 18 * s)
            .compactSlot(.trailing, width: activity.compactSideWidth)
    }
}

private struct NowPlayingMinimal: View {
    let activity: NowPlayingActivity
    var body: some View {
        let s = ActivityMetrics.scale
        ArtworkView(image: activity.artwork, version: activity.artworkVersion, size: 26 * s, radius: 13 * s)
            .minimalSlot()
    }
}

// MARK: - Expanded

private struct NowPlayingExpanded: View {
    let activity: NowPlayingActivity

    var body: some View {
        let info = activity.info
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                ArtworkView(image: activity.artwork, version: activity.artworkVersion, size: 60, radius: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(info?.title ?? "")
                        .font(.island(16))
                        .lineLimit(1)
                        .contentTransition(.interpolate)
                    Text(info?.artist ?? "")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                        .contentTransition(.interpolate)
                }
                .animation(.smooth(duration: 0.3), value: info?.trackKey)
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 10) {
                    AppBadge(bundleID: info?.bundleID)
                    WaveformView(playing: info?.playing == true, tint: activity.artworkColor,
                                 barCount: 5, barWidth: 3, spacing: 2.5, maxHeight: 16)
                }
            }
            NowPlayingScrubber(activity: activity)
            HStack {
                Color.clear.frame(width: 28, height: 1)
                Spacer()
                HStack(spacing: 36) {
                    controlButton("backward.fill", size: 20) { activity.send(.previous) }
                    controlButton(info?.playing == true ? "pause.fill" : "play.fill", size: 26) { activity.send(.toggle) }
                    controlButton("forward.fill", size: 20) { activity.send(.next) }
                }
                Spacer()
                // Decorative output glyph, like iOS.
                Image(systemName: "airplayaudio")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 28, height: 28)
            }
        }
        .expandedSlot(height: activity.expandedHeight)
    }

    private func controlButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 40, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(ActivityPressStyle())
    }
}

private struct AppBadge: View {
    let bundleID: String?
    var body: some View {
        if let bundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 20, height: 20)
        } else {
            Image(systemName: "music.note")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 20, height: 20)
        }
    }
}

private struct NowPlayingScrubber: View {
    let activity: NowPlayingActivity
    @State private var dragFraction: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let info = activity.info
            let duration = info?.duration ?? 0
            let position = info?.position(at: context.date) ?? 0
            let fraction = duration > 0 ? min(1, max(0, dragFraction ?? position / duration)) : 0
            let shown = fraction * duration
            let dragging = dragFraction != nil

            VStack(spacing: 3) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule(style: .continuous).fill(Color.white.opacity(0.22))
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(dragging ? 1 : 0.85))
                            .frame(width: max(0, geo.size.width * fraction))
                    }
                    .frame(height: dragging ? 8 : 5)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard duration > 0 else { return }
                                dragFraction = min(1, max(0, value.location.x / max(1, geo.size.width)))
                            }
                            .onEnded { value in
                                guard duration > 0 else { dragFraction = nil; return }
                                let f = min(1, max(0, value.location.x / max(1, geo.size.width)))
                                activity.seek(to: f * duration)
                                dragFraction = nil
                            }
                    )
                    .animation(.spring(response: 0.25, dampingFraction: 0.8), value: dragging)
                }
                .frame(height: 12)

                HStack {
                    Text(Self.format(shown))
                    Spacer()
                    Text(duration > 0 ? "-" + Self.format(duration - shown) : "")
                }
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private static func format(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
