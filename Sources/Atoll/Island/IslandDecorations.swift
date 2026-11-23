import SwiftUI

/// Things drawn on the island itself, independent of which activity owns the compact slot:
/// the focus progress ring hugging the edge, and the mic/camera dot (orange mic, green camera, like macOS).
struct IslandDecorations<S: Shape>: View {
    let shape: S
    let width: CGFloat
    let presentation: IslandPresentation

    var body: some View {
        let focus = FocusActivity.shared
        let meeting = MeetingActivity.shared
        let show = presentation != .expanded
        ZStack(alignment: .top) {
            if show && focus.isActive && AtollSettings.shared.isEnabled(focus.id) {
                // Stroke is doubled and clipped to the shape, so the visible ring sits just inside the edge.
                shape
                    .trim(from: 0, to: max(0.002, focus.progress))
                    .stroke(focus.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .clipShape(shape)
                    .opacity(focus.paused ? 0.5 : 1)
                    .animation(.linear(duration: 0.25), value: focus.progress)
                    .transition(.opacity)
            }
            if show, AtollSettings.shared.isEnabled(meeting.id), let dot = meeting.indicatorColor,
               ActivityCenter.shared.active.first?.id != meeting.id {
                HStack {
                    Spacer(minLength: 0)
                    Circle().fill(dot).frame(width: 7, height: 7)
                        .padding(.trailing, max(8, (width - IslandMetrics.idleWidth(AtollSettings.shared.style)) / 2 + 12))
                }
                .frame(width: width, height: IslandMetrics.height)
                .transition(.opacity)
            }
        }
        .frame(width: IslandMetrics.canvasWidth, alignment: .top)
        .allowsHitTesting(false)
    }
}
