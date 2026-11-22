import SwiftUI

/// Continuous rounded rectangle pinned to the top centre of its rect.
/// Width, height and corner radius animate together, so one spring drives all three.
struct IslandShape: Shape {
    var width: CGFloat
    var height: CGFloat
    var radius: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(width, height), radius) }
        set {
            width = newValue.first.first
            height = newValue.first.second
            radius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let w = max(width, 1)
        let h = max(height, 1)
        let r = max(0, min(radius, min(w, h) / 2))
        let box = CGRect(x: rect.midX - w / 2, y: rect.minY, width: w, height: h)
        return RoundedRectangle(cornerRadius: r, style: .continuous).path(in: box)
    }
}

/// Pure black island fill, or a dark material for bright desktops.
struct IslandFill<S: Shape>: View {
    let shape: S
    let glass: Bool

    var body: some View {
        if glass {
            shape.fill(.ultraThinMaterial)
                .overlay(shape.fill(Color.black.opacity(0.55)))
        } else {
            shape.fill(Color.black)
        }
    }
}
