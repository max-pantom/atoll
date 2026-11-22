// Shared palette, metrics and small views used by every activity.
import SwiftUI
import AppKit

/// Apple system colours used on the island (dark appearance values).
enum AtollPalette {
    static let green = Color(red: 0x34 / 255.0, green: 0xC7 / 255.0, blue: 0x59 / 255.0)   // #34C759 charging
    static let orange = Color(red: 1.0, green: 0x9F / 255.0, blue: 0x0A / 255.0)           // #FF9F0A timer
    static let red = Color(red: 1.0, green: 0x45 / 255.0, blue: 0x3A / 255.0)              // #FF453A low battery
    static let blue = Color(red: 0.04, green: 0.52, blue: 1.0)                             // #0A84FF
}

@MainActor
enum ActivityMetrics {
    /// The shell scales the whole canvas, so activities work in logical points.
    static var scale: CGFloat { 1 }
    /// Island height in compact presentation (RESEARCH.md §2).
    static var compactHeight: CGFloat { 37.33 * scale }
    /// Horizontal inset of expanded content; concentric with the 44 pt island corner.
    /// The shell already insets expanded content (20 pt), so none is added here.
    static let expandedPadding: CGFloat = 0
}

enum CompactSide { case leading, trailing }

extension Font {
    /// SF Pro Rounded, heavy: numerals and short labels on the island.
    static func island(_ size: CGFloat, weight: Font.Weight = .heavy) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

/// Blur + scale content transition (RESEARCH.md §3).
struct BlurScaleEffect: ViewModifier {
    let radius: CGFloat
    let scale: CGFloat
    let opacity: Double
    func body(content: Content) -> some View {
        content.blur(radius: radius).scaleEffect(scale).opacity(opacity)
    }
}

extension AnyTransition {
    static var islandContent: AnyTransition {
        .modifier(active: BlurScaleEffect(radius: 8, scale: 0.85, opacity: 0),
                  identity: BlurScaleEffect(radius: 0, scale: 1, opacity: 1))
    }
}

extension View {
    /// Fills the compact slot the shell frames (`compactSideWidth` × island height); hugs the outer edge with a concentric inset.
    /// `width` is kept for call-site clarity.
    @MainActor
    func compactSlot(_ side: CompactSide, width: CGFloat) -> some View {
        // The shell already insets compact sides (`IslandMetrics.compactInset`).
        return self
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: side == .leading ? .leading : .trailing)
    }

    /// Frames expanded content: full width, fixed height, concentric inset.
    @MainActor
    func expandedSlot(height: CGFloat) -> some View {
        self
            .foregroundStyle(.white)
            .padding(.horizontal, ActivityMetrics.expandedPadding)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
    }

    /// Minimal bubble content.
    @MainActor
    func minimalSlot() -> some View {
        self
            .foregroundStyle(.white)
            .frame(width: 36.67 * ActivityMetrics.scale, height: 36.67 * ActivityMetrics.scale)
    }
}

/// iOS-style press feedback for island buttons.
struct ActivityPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Filled circle button (timer, HUD): glyph on a coloured disc.
struct ActivityCircleButton: View {
    let symbol: String
    let fill: Color
    var glyph: Color = .white
    var size: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(glyph)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size, height: size)
                .background(Circle().fill(fill))
        }
        .buttonStyle(ActivityPressStyle())
    }
}

/// Short capsule used for presets.
struct ActivityChip: View {
    let title: String
    var tint: Color = AtollPalette.orange
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.island(14))
                .foregroundStyle(tint)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(Capsule(style: .continuous).fill(tint.opacity(0.2)))
        }
        .buttonStyle(ActivityPressStyle())
    }
}
