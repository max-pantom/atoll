// Downloads: watches ~/Downloads for in-progress browser files, shows a growing size or ring, then a done pop.
// Also announces AirDrop arrivals. The directory is only touched while the activity is enabled.
import SwiftUI
import AppKit

@MainActor
@Observable
final class DownloadsActivity: IslandActivity {
    struct Progress: Identifiable, Equatable {
        let id: String          // partial file name
        let name: String
        let bytes: Int64
        let fraction: Double?   // nil when the total is unknown
    }

    struct Done: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let airdrop: Bool
    }

    static let shared = DownloadsActivity()
    nonisolated static let partialExtensions: Set<String> = ["crdownload", "download", "part", "partial"]

    let id = "downloads"
    let priority = 35

    private(set) var running: [Progress] = []
    private(set) var finished: [Done] = []

    @ObservationIgnored private let watcher = DownloadsWatcher()
    @ObservationIgnored private var expireTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var started = false
    @ObservationIgnored private(set) var demoMode = false

    private init() {}

    // MARK: IslandActivity

    var isActive: Bool { !running.isEmpty || !finished.isEmpty }
    var tint: Color { AtollPalette.blue }
    var compactSideWidth: CGFloat { finished.isEmpty ? 62 : 34 }
    var expandedHeight: CGFloat {
        if !finished.isEmpty { return 64 }
        return CGFloat(min(running.count, 3)) * 34 + CGFloat(max(0, min(running.count, 3) - 1)) * 6 + 22
    }
    var expandedWidth: CGFloat? { 400 }

    func compactLeading() -> AnyView { AnyView(DownloadsLeading(activity: self).compactSlot(.leading, width: compactSideWidth)) }
    func compactTrailing() -> AnyView { AnyView(DownloadsTrailing(activity: self).compactSlot(.trailing, width: compactSideWidth)) }
    func minimal() -> AnyView { AnyView(DownloadsLeading(activity: self).minimalSlot()) }
    func expanded() -> AnyView { AnyView(DownloadsExpanded(activity: self).expandedSlot(height: expandedHeight)) }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        watcher.onUpdate = { [weak self] update in self?.apply(update) }
        trackEnabled(id) { [weak self] on in
            guard let self, !self.demoMode else { return }
            if on { self.watcher.start() } else { self.watcher.stop(); self.running = []; self.finished = [] }
        }
    }

    private func apply(_ update: DownloadsWatcher.Update) {
        if update.running != running { running = update.running }
        for done in update.completed {
            addFinished(Done(url: done.url, airdrop: done.airdrop))
        }
    }

    func addFinished(_ done: Done) {
        NSSound(named: NSSound.Name("Pop"))?.play()
        finished.insert(done, at: 0)
        if finished.count > 3 { finished.removeLast() }
        ActivityCenter.shared.bloom(id, for: 7)
        expireTasks[done.id] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled else { return }
            self?.dismiss(done)
        }
    }

    func dismiss(_ done: Done) {
        expireTasks[done.id]?.cancel()
        expireTasks[done.id] = nil
        finished.removeAll { $0.id == done.id }
    }

    func reveal(_ done: Done) {
        NSWorkspace.shared.activateFileViewerSelecting([done.url])
        dismiss(done)
        IslandModel.shared.collapse()
    }

    func open(_ done: Done) {
        NSWorkspace.shared.open(done.url)
        dismiss(done)
        IslandModel.shared.collapse()
    }

    // MARK: Demo (no filesystem access, no permission prompt)

    func runDemo() {
        demoMode = true
        watcher.stop()
        var step = 0
        let files: [(String, Int64, Int64)] = [("Design-Assets.zip", 482_000_000, 41_000_000), ("Keynote-Export.pdf", 96_000_000, 9_000_000)]
        running = files.map { Progress(id: $0.0, name: $0.0, bytes: $0.2, fraction: Double($0.2) / Double($0.1)) }
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                step += 1
                if step >= 8 {
                    timer.invalidate()
                    self.running = []
                    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/Design-Assets.zip")
                    self.addFinished(Done(url: url, airdrop: false))
                    return
                }
                self.running = files.map { f in
                    let b = min(f.1, f.2 + Int64(step) * f.1 / 9)
                    return Progress(id: f.0, name: f.0, bytes: b, fraction: Double(b) / Double(f.1))
                }
            }
        }
    }
}

// MARK: - Watcher

/// Watches the Downloads directory with a DispatchSource and rescans on a utility queue.
/// While partial files exist it also rescans once a second, because growth of a file does not change its directory.
final class DownloadsWatcher: @unchecked Sendable {
    struct Completed { let url: URL; let airdrop: Bool }
    struct Update { let running: [DownloadsActivity.Progress]; let completed: [Completed] }

    @MainActor var onUpdate: (@MainActor (Update) -> Void)?

    private let queue = DispatchQueue(label: "cc.primitive8.atoll.downloads", qos: .utility)
    private var source: DispatchSourceFileSystemObject?
    private var sizeTimer: DispatchSourceTimer?
    private var known: Set<String> = []
    private var partials: Set<String> = []
    private var recent: [String: Date] = [:]
    private var primed = false
    private let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]

    func start() {
        queue.async { [self] in
            guard source == nil else { return }
            let fd = open(dir.path, O_EVTONLY)
            guard fd >= 0 else { return }
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: queue)
            src.setEventHandler { [weak self] in self?.scan() }
            src.setCancelHandler { close(fd) }
            source = src
            primed = false
            src.resume()
            scan()
        }
    }

    func stop() {
        queue.async { [self] in
            source?.cancel()
            source = nil
            sizeTimer?.cancel()
            sizeTimer = nil
            known = []
            partials = []
            recent = [:]
            primed = false
        }
    }

    // MARK: Scanning (queue)

    private func scan() {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                                                      options: [.skipsHiddenFiles]) else { return }
        var current: [String: URL] = [:]
        var partialNow: [String: URL] = [:]
        for u in urls {
            if DownloadsActivity.partialExtensions.contains(u.pathExtension.lowercased()) {
                partialNow[u.lastPathComponent] = u
            } else {
                current[u.lastPathComponent] = u
            }
        }

        var completed: [Completed] = []
        if primed {
            let now = Date()
            for name in current.keys where !known.contains(name) { recent[name] = now }
            recent = recent.filter { now.timeIntervalSince($0.value) < 6 && current[$0.key] != nil }

            let vanished = partials.subtracting(partialNow.keys)
            for gone in vanished.sorted() {
                let stem = (gone as NSString).deletingPathExtension
                // Fall back to the lone new file only; with several candidates a cancelled download could match the wrong one.
                let match = recent.keys.first(where: { $0 == stem }) ?? (recent.count == 1 ? recent.keys.first : nil)
                if let match, let url = current[match] {
                    completed.append(Completed(url: url, airdrop: false))
                    recent[match] = nil
                }
            }
            // New files that no browser download explains: AirDrop if the quarantine record says so.
            for name in recent.keys.sorted() {
                guard let url = current[name], recent[name] != nil else { continue }
                if Self.isAirDrop(url) {
                    completed.append(Completed(url: url, airdrop: true))
                    recent[name] = nil
                }
            }
        }
        known = Set(current.keys)
        partials = Set(partialNow.keys)
        primed = true

        let progress = partialNow.values.sorted { $0.lastPathComponent < $1.lastPathComponent }.map(Self.progress(for:))
        updateTimer(active: !partialNow.isEmpty || !recent.isEmpty)
        let update = Update(running: progress, completed: completed)
        Task { @MainActor [weak self] in self?.onUpdate?(update) }
    }

    private func updateTimer(active: Bool) {
        if active, sizeTimer == nil {
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
            t.setEventHandler { [weak self] in self?.scan() }
            t.resume()
            sizeTimer = t
        } else if !active, let t = sizeTimer {
            t.cancel()
            sizeTimer = nil
        }
    }

    private static func progress(for url: URL) -> DownloadsActivity.Progress {
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        var bytes: Int64 = 0
        var fraction: Double?
        if isDir {
            // Safari: Name.download/ bundle with Info.plist progress keys.
            if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let f as URL in e { bytes += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
            }
            if let info = NSDictionary(contentsOf: url.appendingPathComponent("Info.plist")),
               let total = (info["DownloadEntryProgressTotalToLoad"] as? NSNumber)?.int64Value, total > 0 {
                if let sofar = (info["DownloadEntryProgressBytesSoFar"] as? NSNumber)?.int64Value { bytes = max(bytes, sofar) }
                fraction = min(1, Double(bytes) / Double(total))
            }
        } else {
            bytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        if fraction == nil, let s = xattrString(url, "com.apple.progress.fractionCompleted"), let d = Double(s), d > 0, d <= 1 {
            fraction = d
        }
        var name = (url.lastPathComponent as NSString).deletingPathExtension
        if name.isEmpty { name = url.lastPathComponent }
        return .init(id: url.lastPathComponent, name: name, bytes: bytes, fraction: fraction)
    }

    private static func xattrString(_ url: URL, _ name: String) -> String? {
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard getxattr(url.path, name, &buf, size, 0, 0) == size else { return nil }
        return String(bytes: buf, encoding: .utf8)
    }

    /// AirDrop (sharingd) stamps received files with a quarantine record naming the sender app.
    private static func isAirDrop(_ url: URL) -> Bool {
        if let q = xattrString(url, "com.apple.quarantine")?.lowercased(), q.contains("sharingd") || q.contains("airdrop") { return true }
        return false
    }
}

// MARK: - Views

private let sizeFormatter: ByteCountFormatter = {
    let f = ByteCountFormatter()
    f.countStyle = .file
    return f
}()

private func sizeText(_ bytes: Int64) -> String { sizeFormatter.string(fromByteCount: bytes) }

private struct Ring: View {
    let fraction: Double?
    var size: CGFloat = 22
    var line: CGFloat = 3
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle().stroke(AtollPalette.blue.opacity(0.25), lineWidth: line)
            if let fraction {
                Circle()
                    .trim(from: 0, to: max(0.02, fraction))
                    .stroke(AtollPalette.blue, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.smooth(duration: 0.4), value: fraction)
            } else {
                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(AtollPalette.blue, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .onAppear { withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { spin = true } }
            }
        }
        .frame(width: size, height: size)
    }
}

private struct DownloadsLeading: View {
    let activity: DownloadsActivity
    var body: some View {
        if let done = activity.finished.first {
            Image(systemName: done.airdrop ? "airdrop" : "checkmark.circle.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(AtollPalette.green)
                .contentTransition(.symbolEffect(.replace))
        } else {
            Ring(fraction: activity.running.first?.fraction)
                .overlay(
                    Image(systemName: "arrow.down")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(AtollPalette.blue)
                )
        }
    }
}

private struct DownloadsTrailing: View {
    let activity: DownloadsActivity
    var body: some View {
        if activity.finished.isEmpty, let first = activity.running.first {
            Text(first.fraction.map { "\(Int($0 * 100))%" } ?? sizeText(first.bytes))
                .font(.island(14))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(AtollPalette.blue)
                .contentTransition(.numericText())
                .animation(.smooth(duration: 0.25), value: first.bytes)
        } else {
            EmptyView()
        }
    }
}

private struct DownloadsExpanded: View {
    let activity: DownloadsActivity

    var body: some View {
        Group {
            if let done = activity.finished.first {
                doneRow(done)
            } else {
                VStack(spacing: 6) {
                    ForEach(activity.running.prefix(3)) { item in
                        HStack(spacing: 10) {
                            Ring(fraction: item.fraction, size: 26, line: 3.5)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(item.name)
                                    .font(.island(14, weight: .semibold))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(item.fraction.map { "\(sizeText(item.bytes))  ·  \(Int($0 * 100))%" } ?? sizeText(item.bytes))
                                    .font(.system(size: 12, weight: .semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(.white.opacity(0.55))
                                    .contentTransition(.numericText())
                                    .animation(.smooth(duration: 0.25), value: item.bytes)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(height: 34)
                    }
                }
            }
        }
        .animation(.smooth(duration: 0.25), value: activity.finished.isEmpty)
    }

    private func doneRow(_ done: DownloadsActivity.Done) -> some View {
        HStack(spacing: 12) {
            Image(systemName: done.airdrop ? "airdrop" : "checkmark.circle.fill")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(AtollPalette.green)
                .symbolEffect(.bounce, value: done.id)
            VStack(alignment: .leading, spacing: 0) {
                Text(done.url.lastPathComponent)
                    .font(.island(15, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(done.airdrop ? "Received via AirDrop" : "Download complete")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 0)
            pill("Reveal", fill: Color.white.opacity(0.18), text: .white) { activity.reveal(done) }
            pill("Open", fill: AtollPalette.blue, text: .white) { activity.open(done) }
        }
    }

    private func pill(_ title: String, fill: Color, text: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.island(13))
                .foregroundStyle(text)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Capsule(style: .continuous).fill(fill))
        }
        .buttonStyle(ActivityPressStyle())
    }
}
