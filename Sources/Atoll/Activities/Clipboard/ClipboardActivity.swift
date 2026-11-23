// Clipboard history: last 20 copies (text, images, files), pin to keep, click to copy back, option-click to paste.
import SwiftUI
import AppKit
import ApplicationServices
import ImageIO
import Carbon.HIToolbox

struct ClipItem: Identifiable, Codable {
    enum Kind: String, Codable { case text, image, files }

    var id = UUID()
    var kind: Kind
    var text: String?
    var imageData: Data?
    /// Cheap fingerprint of `imageData`, so repeat copies are compared without diffing full blobs.
    var imageHash: Int?
    var fileURLs: [URL] = []
    var date = Date()
    var source: String?
    var pinned = false

    var symbol: String {
        switch kind {
        case .text: return "text.alignleft"
        case .image: return "photo"
        case .files: return "doc"
        }
    }

    /// Same payload (used to move a repeated copy to the top instead of duplicating it).
    func sameContent(as other: ClipItem) -> Bool {
        kind == other.kind && text == other.text && imageHash == other.imageHash && fileURLs == other.fileURLs
    }
}

@MainActor
@Observable
final class ClipboardActivity: IslandActivity {
    static let shared = ClipboardActivity()
    static let limit = 20

    let id = "clipboard"
    let priority = 5
    let hotKeyPref = HotKeyPref(key: "clipboard.hotkey",
                                default: KeyCombo(keyCode: UInt32(kVK_ANSI_V), mods: UInt32(controlKey | optionKey), label: "V"))

    private(set) var items: [ClipItem] = []
    private(set) var flashing = false
    private(set) var copiedID: UUID?

    /// Briefly show a compact glyph in the island after each copy.
    var flashOnCopy: Bool { didSet { UserDefaults.standard.set(flashOnCopy, forKey: "clipboard.flash") } }
    /// Option-click pastes into the frontmost app. Enabling asks for Accessibility.
    var pasteEnabled: Bool { didSet { UserDefaults.standard.set(pasteEnabled, forKey: "clipboard.paste") } }

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastCount = NSPasteboard.general.changeCount
    @ObservationIgnored private var ownCount = -1
    @ObservationIgnored private var hotKey: GlobalHotKey?
    @ObservationIgnored private var flashTask: Task<Void, Never>?
    @ObservationIgnored private var copiedTask: Task<Void, Never>?
    @ObservationIgnored private var thumbs: [UUID: NSImage] = [:]
    @ObservationIgnored private var started = false

    private init() {
        flashOnCopy = UserDefaults.standard.object(forKey: "clipboard.flash") as? Bool ?? true
        pasteEnabled = UserDefaults.standard.object(forKey: "clipboard.paste") as? Bool ?? false
    }

    // MARK: IslandActivity

    var isActive: Bool { flashing && !items.isEmpty }
    var tint: Color { AtollPalette.blue }
    var compactSideWidth: CGFloat { 34 }
    var expandedHeight: CGFloat { 132 }
    var expandedWidth: CGFloat? { 440 }

    func compactLeading() -> AnyView { AnyView(ClipGlyph(symbol: "doc.on.clipboard").compactSlot(.leading, width: compactSideWidth)) }
    func compactTrailing() -> AnyView { AnyView(ClipGlyph(symbol: items.first?.symbol ?? "doc").compactSlot(.trailing, width: compactSideWidth)) }
    func minimal() -> AnyView { AnyView(ClipGlyph(symbol: "doc.on.clipboard").minimalSlot()) }
    func expanded() -> AnyView { AnyView(ClipboardExpanded(activity: self).expandedSlot(height: expandedHeight)) }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        loadPinned()
        hotKey = GlobalHotKey { [weak self] in self?.summon() }
        hotKeyPref.onChange = { [weak self] in self?.applyEnabled(AtollSettings.shared.isEnabled("clipboard")) }
        trackEnabled(id) { [weak self] on in self?.applyEnabled(on) }
    }

    private func applyEnabled(_ on: Bool) {
        if on {
            hotKey?.register(hotKeyPref.combo)
            guard timer == nil else { return }
            lastCount = NSPasteboard.general.changeCount
            let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
            t.tolerance = 0.15
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else {
            hotKey?.unregister()
            timer?.invalidate()
            timer = nil
            items.removeAll { !$0.pinned }
            flashing = false
        }
    }

    func summon() {
        guard AtollSettings.shared.isEnabled(id), !IslandModel.shared.isPaused else { return }
        IslandModel.shared.expand(id: id)
    }

    // MARK: Polling

    private func poll() {
        let pb = NSPasteboard.general
        let count = pb.changeCount
        guard count != lastCount else { return }
        lastCount = count
        guard count != ownCount else { return }
        let names = Set((pb.types ?? []).map(\.rawValue))
        if names.contains("org.nspasteboard.ConcealedType") || names.contains("org.nspasteboard.TransientType")
            || names.contains("org.nspasteboard.AutoGeneratedType") { return }
        let source = sourceName(pb)
        if var item = readQuick(pb) {
            item.source = source
            ingest(item)
            return
        }
        // Images can be large: read and hash them off the main thread, then ingest if the pasteboard has not moved on.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let pb = NSPasteboard.general
            guard pb.changeCount == count,
                  let data = pb.data(forType: .png) ?? pb.data(forType: .tiff), data.count < 8_000_000 else { return }
            var item = ClipItem(kind: .image, imageData: data, imageHash: data.hashValue)
            item.source = source
            Task { @MainActor in
                guard let self, NSPasteboard.general.changeCount == count else { return }
                self.ingest(item)
            }
        }
    }

    private func readQuick(_ pb: NSPasteboard) -> ClipItem? {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: opts) as? [URL], !urls.isEmpty {
            return ClipItem(kind: .files, fileURLs: urls)
        }
        if let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ClipItem(kind: .text, text: String(s.prefix(100_000)))
        }
        return nil
    }

    private func sourceName(_ pb: NSPasteboard) -> String? {
        if let bundleID = pb.string(forType: NSPasteboard.PasteboardType("org.nspasteboard.source")),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return NSWorkspace.shared.frontmostApplication?.localizedName
    }

    func ingest(_ new: ClipItem) {
        var item = new
        if let i = items.firstIndex(where: { $0.sameContent(as: item) }) {
            item.id = items[i].id
            item.pinned = items[i].pinned
            items.remove(at: i)
        }
        items.insert(item, at: 0)
        prune()
        if item.pinned { savePinned() }
        if flashOnCopy { flash() }
    }

    private func prune() {
        var unpinned = 0
        items = items.filter { item in
            if item.pinned { return true }
            unpinned += 1
            return unpinned <= Self.limit
        }
        let live = Set(items.map(\.id))
        thumbs = thumbs.filter { live.contains($0.key) }
    }

    private func flash() {
        flashing = true
        flashTask?.cancel()
        flashTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            self?.flashing = false
        }
    }

    // MARK: Actions

    /// Copies the item back. With `paste` (option-click) and Accessibility enabled it also presses ⌘V in the frontmost app.
    func activate(_ item: ClipItem, paste: Bool) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .text:
            pb.setString(item.text ?? "", forType: .string)
        case .image:
            if let data = item.imageData {
                pb.setData(data, forType: data.starts(with: [0x89, 0x50]) ? .png : .tiff)
            }
        case .files:
            pb.writeObjects(item.fileURLs.map { $0 as NSURL })
        }
        ownCount = pb.changeCount
        lastCount = ownCount
        copiedID = item.id
        copiedTask?.cancel()
        copiedTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            self?.copiedID = nil
        }
        if paste, pasteEnabled, AXIsProcessTrusted() {
            IslandModel.shared.collapse()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { Self.pressCommandV() }
        }
    }

    private static func pressCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    func togglePin(_ item: ClipItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].pinned.toggle()
        savePinned()
    }

    func clearAll() {
        items.removeAll()
        thumbs.removeAll()
        savePinned()
    }

    /// Asks macOS for Accessibility. Called only when the user turns option-click paste on.
    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    var accessibilityGranted: Bool { AXIsProcessTrusted() }

    // MARK: Thumbnails

    func thumbnail(for item: ClipItem) -> NSImage? {
        if let t = thumbs[item.id] { return t }
        guard let data = item.imageData,
              let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 260,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
        thumbs[item.id] = image
        return image
    }

    // MARK: Persistence (pinned items only)

    private static var storeURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Atoll", isDirectory: true).appendingPathComponent("clipboard-pinned.json")
    }

    private func loadPinned() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let saved = try? JSONDecoder().decode([ClipItem].self, from: data) else { return }
        items = saved.map { var i = $0; i.pinned = true; return i } + items.filter { !$0.pinned }
    }

    private func savePinned() {
        let pinned = items.filter(\.pinned)
        let url = Self.storeURL
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if pinned.isEmpty {
                try? FileManager.default.removeItem(at: url)
            } else if let data = try? JSONEncoder().encode(pinned) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}

// MARK: - Views

private struct ClipGlyph: View {
    let symbol: String
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(AtollPalette.blue)
            .contentTransition(.symbolEffect(.replace))
    }
}

private struct ClipboardExpanded: View {
    let activity: ClipboardActivity

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Label("Clipboard", systemImage: "doc.on.clipboard")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                if !activity.items.isEmpty {
                    Button { withAnimation(.smooth(duration: 0.25)) { activity.clearAll() } } label: {
                        Text("Clear all")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(AtollPalette.blue)
                    }
                    .buttonStyle(ActivityPressStyle())
                }
            }
            if activity.items.isEmpty {
                Text("Nothing copied yet")
                    .font(.island(15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(activity.items.sorted { $0.pinned && !$1.pinned }) { item in
                            ClipCard(item: item, activity: activity)
                                .transition(.islandContent)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
        }
    }
}

private struct ClipCard: View {
    let item: ClipItem
    let activity: ClipboardActivity

    var body: some View {
        let copied = activity.copiedID == item.id
        VStack(alignment: .leading, spacing: 4) {
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack(spacing: 4) {
                TimelineView(.periodic(from: .now, by: 20)) { _ in
                    Text(footer)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if copied {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(AtollPalette.green)
                        .transition(.islandContent)
                }
            }
        }
        .padding(8)
        .frame(width: 118, height: 86)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(copied ? 0.2 : 0.11)))
        .overlay(alignment: .topTrailing) {
            Button { withAnimation(.smooth(duration: 0.25)) { activity.togglePin(item) } } label: {
                Image(systemName: item.pinned ? "pin.fill" : "pin")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(item.pinned ? AtollPalette.orange : .white.opacity(0.4))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(ActivityPressStyle())
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture {
            withAnimation(.smooth(duration: 0.2)) {
                activity.activate(item, paste: NSEvent.modifierFlags.contains(.option))
            }
        }
    }

    @ViewBuilder
    private var preview: some View {
        switch item.kind {
        case .text:
            Text((item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(4)
                .padding(.trailing, 14)
        case .image:
            if let image = activity.thumbnail(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 102, height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Image(systemName: "photo").foregroundStyle(.white.opacity(0.5))
            }
        case .files:
            HStack(alignment: .top, spacing: 6) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.fileURLs.first?.path ?? ""))
                    .resizable()
                    .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.fileURLs.first?.lastPathComponent ?? "File")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .lineLimit(2)
                    if item.fileURLs.count > 1 {
                        Text("+\(item.fileURLs.count - 1) more")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .padding(.trailing, 12)
            }
        }
    }

    private var footer: String {
        let age = Self.age(item.date)
        if let s = item.source, !s.isEmpty { return "\(s) · \(age)" }
        return age
    }

    static func age(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}
