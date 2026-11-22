// Shelf: files dropped on the island are kept as references (never copied) in a horizontal tray.
// Shell side: set `ShelfActivity.shared.isDragTarget` while files hover over the island and call
// `accept(urls:)` on drop. The expanded view also accepts drops itself.
import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ShelfItem: Identifiable {
    let id = UUID()
    let url: URL
    let icon: NSImage
    var name: String { url.lastPathComponent }
}

@MainActor
@Observable
final class ShelfActivity: IslandActivity {
    static let shared = ShelfActivity()

    let id = "shelf"
    let priority = 5

    private(set) var items: [ShelfItem] = []
    /// Set by the shell while a drag hovers the island.
    var isDragTarget = false

    private init() {}

    // MARK: IslandActivity

    var isActive: Bool { isDragTarget || !items.isEmpty }
    var tint: Color { .white }
    var compactSideWidth: CGFloat { 44 }
    var expandedHeight: CGFloat { 112 }

    func compactLeading() -> AnyView { AnyView(ShelfLeading(activity: self).compactSlot(.leading, width: compactSideWidth)) }
    func compactTrailing() -> AnyView { AnyView(ShelfTrailing(activity: self).compactSlot(.trailing, width: compactSideWidth)) }
    func minimal() -> AnyView { AnyView(ShelfLeading(activity: self).minimalSlot()) }
    func expanded() -> AnyView { AnyView(ShelfExpanded(activity: self).expandedSlot(height: expandedHeight)) }

    // MARK: Model

    func accept(urls: [URL]) {
        let fresh = urls
            .filter { $0.isFileURL }
            .map { $0.standardizedFileURL }
            .filter { url in !items.contains { $0.url == url } }
        guard !fresh.isEmpty else { return }
        let added = fresh.map { ShelfItem(url: $0, icon: NSWorkspace.shared.icon(forFile: $0.path)) }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { items.append(contentsOf: added) }
        ActivityCenter.shared.bloom(id, for: 1.5)
    }

    func remove(_ item: ShelfItem) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) { items.removeAll { $0.id == item.id } }
    }

    func clear() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) { items.removeAll() }
    }

    func airDrop() {
        let urls = items.map { $0.url as NSURL }
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: urls) else { return }
        NSApp.activate()
        service.perform(withItems: urls)
    }

    /// Reads file URLs out of drop providers (used by the expanded view's own drop target).
    nonisolated static func loadURLs(from providers: [NSItemProvider], completion: @escaping @Sendable ([URL]) -> Void) {
        let group = DispatchGroup()
        let box = URLBox()
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else if let u = item as? URL { url = u }
                if let url { box.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(box.urls) }
    }
}

private final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []
    func append(_ url: URL) { lock.lock(); storage.append(url); lock.unlock() }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return storage }
}

// MARK: - Views

private struct ShelfLeading: View {
    let activity: ShelfActivity
    var body: some View {
        Image(systemName: activity.isDragTarget ? "tray.and.arrow.down.fill" : "tray.full.fill")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .contentTransition(.symbolEffect(.replace))
    }
}

private struct ShelfTrailing: View {
    let activity: ShelfActivity
    var body: some View {
        Text(activity.isDragTarget && activity.items.isEmpty ? "Drop" : "\(activity.items.count)")
            .font(.island(14))
            .monospacedDigit()
            .contentTransition(.numericText())
            .animation(.smooth(duration: 0.25), value: activity.items.count)
    }
}

private struct ShelfExpanded: View {
    let activity: ShelfActivity

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Text("Shelf")
                    .font(.island(14))
                Spacer()
                if !activity.items.isEmpty {
                    headerButton("airdrop", label: "AirDrop") { activity.airDrop() }
                    headerButton("xmark.circle.fill", label: "Clear") { activity.clear() }
                }
            }
            ZStack {
                if activity.items.isEmpty {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(activity.isDragTarget ? 0.6 : 0.2),
                                      style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .overlay(
                            Label("Drop files here", systemImage: "arrow.down.to.line")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.55))
                        )
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(activity.items) { item in
                                ShelfTile(item: item, activity: activity)
                                    .transition(.islandContent)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .animation(.smooth(duration: 0.2), value: activity.isDragTarget)
    }

    private func headerButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 26, height: 22)
        }
        .buttonStyle(ActivityPressStyle())
        .help(label)
    }
}

private struct ShelfTile: View {
    let item: ShelfItem
    let activity: ShelfActivity
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 3) {
            Image(nsImage: item.icon)
                .resizable()
                .frame(width: 44, height: 44)
            Text(item.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 60)
        }
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button { activity.remove(item) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.white, Color.white.opacity(0.3))
                }
                .buttonStyle(ActivityPressStyle())
                .offset(x: 6, y: -4)
                .transition(.islandContent)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.15), value: hovering)
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }   // drag out
        .onTapGesture(count: 2) { NSWorkspace.shared.open(item.url) }
    }
}
