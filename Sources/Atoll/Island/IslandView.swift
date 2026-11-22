import SwiftUI

/// Content transition: blur + scale + fade. In goes after the shape starts moving, out happens first.
private struct BlurScale: ViewModifier {
    let amount: CGFloat   // 1 = fully hidden, 0 = fully shown

    func body(content: Content) -> some View {
        content
            .blur(radius: 8 * amount)
            .scaleEffect(1 - 0.15 * amount)
            .opacity(1 - amount)
    }
}

private extension AnyTransition {
    static func islandSwap(reduceMotion: Bool) -> AnyTransition {
        if reduceMotion { return AnyTransition.opacity.animation(.easeInOut(duration: 0.15)) }
        let hidden = BlurScale(amount: 1)
        let shown = BlurScale(amount: 0)
        return .asymmetric(
            insertion: AnyTransition.modifier(active: hidden, identity: shown).animation(IslandMotion.contentIn),
            removal: AnyTransition.modifier(active: hidden, identity: shown).animation(IslandMotion.contentOut)
        )
    }
}

/// Root view of the panel: a fixed logical canvas with the island pinned to its top centre.
struct IslandView: View {
    let model: IslandModel

    private typealias M = IslandMetrics

    var body: some View {
        let l = model.layout
        let scale = CGFloat(AtollSettings.shared.scale)
        ZStack(alignment: .top) {
            bubbleLayer(l)
            islandLayer(l)
        }
        .frame(width: M.canvasWidth, height: M.canvasHeight, alignment: .top)
        .scaleEffect(scale, anchor: .top)
        .frame(width: M.canvasWidth * scale, height: M.canvasHeight * scale, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    private var glass: Bool { AtollSettings.shared.appearance == .glass }

    // MARK: Island

    private func islandLayer(_ l: IslandModel.Layout) -> some View {
        let shape = IslandShape(width: l.width, height: l.height, radius: l.radius)
        let expanded = l.presentation == .expanded
        let squish = model.isPressed && !expanded
        let press = DragGesture(minimumDistance: 0)
            .onChanged { _ in model.pressBegan() }
            .onEnded { value in
                model.pressEnded(distance: hypot(value.translation.width, value.translation.height))
            }

        return ZStack(alignment: .top) {
            IslandFill(shape: shape, glass: glass)
                .opacity(l.hidden ? 0 : 1)
                .shadow(color: Color.black.opacity(expanded && !glass ? 0.3 : 0), radius: 20, x: 0, y: 8)
            ZStack(alignment: .top) {
                if model.contentVisible {
                    content(l)
                        .frame(width: l.width, height: l.height)
                        .id(l.contentKey)
                        .transition(.islandSwap(reduceMotion: model.reduceMotion))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipShape(shape)
        }
        // Explicit room for the tallest expanded island and its shadow; nothing here may clip the bottom corners.
        .frame(width: M.canvasWidth, height: M.canvasHeight - M.topInset, alignment: .top)
        .scaleEffect(squish ? IslandMotion.pressScale : 1, anchor: .top)
        .animation(IslandMotion.resize, value: squish)
        .contentShape(shape)
        .gesture(press, including: expanded ? .subviews : .all)
        .padding(.top, M.topInset)
    }

    @ViewBuilder
    private func content(_ l: IslandModel.Layout) -> some View {
        switch l.presentation {
        case .expanded:
            if let id = l.primaryID, let act = model.activity(id) {
                act.expanded()
                    .padding(EdgeInsets(top: M.expandedInsetV, leading: M.expandedInsetH,
                                        bottom: M.expandedInsetV, trailing: M.expandedInsetH))
                    .frame(width: l.width, height: l.height)
            } else {
                Activities.idleCard()
                    .padding(EdgeInsets(top: M.expandedInsetV, leading: M.expandedInsetH,
                                        bottom: M.expandedInsetV, trailing: M.expandedInsetH))
                    .frame(width: l.width, height: l.height)
            }
        case .compact, .minimal:
            if let id = l.primaryID, let act = model.activity(id) {
                HStack(spacing: 0) {
                    act.compactLeading()
                        .frame(width: act.compactSideWidth, height: l.height)
                        .padding(.leading, M.compactInset)
                    Spacer(minLength: 0)
                    act.compactTrailing()
                        .frame(width: act.compactSideWidth, height: l.height)
                        .padding(.trailing, M.compactInset)
                }
                .frame(width: l.width, height: l.height)
            }
        case .idle:
            EmptyView()
        }
    }

    // MARK: Detached bubbles

    private func bubbleLayer(_ l: IslandModel.Layout) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<2, id: \.self) { slot in
                let id: String? = slot < l.bubbleIDs.count ? l.bubbleIDs[slot] : nil
                DetachedBubble(
                    reveal: (id != nil && l.presentation == .minimal) ? 1 : 0,
                    islandWidth: l.width,
                    slot: slot,
                    glass: glass,
                    content: bubbleContent(id),
                    onTap: { if let id { model.tapBubble(id) } }
                )
                .offset(y: M.topInset - DetachedBubble.pad)
            }
        }
        .frame(width: M.canvasWidth, height: M.canvasHeight, alignment: .topLeading)
    }

    private func bubbleContent(_ id: String?) -> AnyView {
        if let id, let act = model.activity(id) { return act.minimal() }
        return AnyView(EmptyView())
    }
}

/// A minimal bubble beside the island. `reveal` 0 = tucked inside the island, 1 = resting detached.
/// Animatable so the position, size and gooey neck follow the island's spring frame by frame.
private struct DetachedBubble: View, Animatable {
    static let pad: CGFloat = 20

    var reveal: CGFloat
    var islandWidth: CGFloat
    let slot: Int
    let glass: Bool
    let content: AnyView
    let onTap: () -> Void

    private typealias M = IslandMetrics

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(reveal, islandWidth) }
        set {
            reveal = newValue.first
            islandWidth = newValue.second
        }
    }

    var body: some View {
        let r = max(reveal, 0)
        let size = M.bubbleSize
        let d = size * (0.4 + 0.6 * min(r, 1.15))
        let cy = Self.pad + M.height / 2
        let islandRight = M.canvasWidth / 2 + islandWidth / 2
        let rest = islandRight + M.bubbleGap + size / 2 + CGFloat(slot) * (size + M.bubbleGap)
        let tucked = islandRight - size / 2 - 2
        let cx = tucked + (rest - tucked) * r
        let visible = min(1, r * 20)
        // Gooey neck while the bubble is between the island and its resting place.
        let neck = glass ? 0 : max(0, min(1, (0.97 - r) / 0.25)) * visible
        let endRadius = M.height / 2

        return ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                context.addFilter(.alphaThreshold(min: 0.5, color: .black))
                context.addFilter(.blur(radius: 7))
                context.drawLayer { layer in
                    layer.fill(
                        Path(ellipseIn: CGRect(x: islandRight - endRadius * 2, y: cy - endRadius,
                                               width: endRadius * 2, height: endRadius * 2)),
                        with: .color(.black))
                    layer.fill(
                        Path(ellipseIn: CGRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d)),
                        with: .color(.black))
                }
            }
            .frame(width: M.canvasWidth, height: M.height + 2 * Self.pad)
            .opacity(neck)
            .allowsHitTesting(false)

            ZStack {
                IslandFill(shape: Circle(), glass: glass)
                content
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .opacity(max(0, min(1, (r - 0.4) / 0.5)))
            }
            .frame(width: size, height: size)
            .scaleEffect(d / size)
            .opacity(visible)
            .offset(x: cx - size / 2, y: cy - size / 2)
            .onTapGesture(perform: onTap)
            .allowsHitTesting(r > 0.9)
        }
        .frame(width: M.canvasWidth, height: M.height + 2 * Self.pad, alignment: .topLeading)
    }
}
