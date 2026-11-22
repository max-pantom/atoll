// Live waveform: a few rounded bars driven by smooth noise while playing, flat while paused.
// A real audio tap (ScreenCaptureKit / process tap) is out of scope for v1, so the motion is
// synthetic but never loops visibly: each bar mixes two incommensurate sine waves.
import SwiftUI

struct WaveformView: View {
    var playing: Bool
    var tint: Color
    var barCount = 5
    var barWidth: CGFloat = 3
    var spacing: CGFloat = 2.5
    var maxHeight: CGFloat = 18

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !playing)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { i in
                    Capsule(style: .continuous)
                        .fill(tint)
                        .frame(width: barWidth, height: barHeight(index: i, time: t))
                }
            }
            .frame(height: maxHeight)
        }
        // Eases between moving and flat when playback toggles; per-frame ticks are not animated.
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: playing)
    }

    private func barHeight(index i: Int, time t: Double) -> CGFloat {
        guard playing else { return barWidth }
        let fi = Double(i)
        let a = sin(t * (2.3 + 0.71 * fi) + fi * 1.7)
        let b = 0.6 + 0.4 * sin(t * (0.9 + 0.33 * fi) + fi * 0.9)
        let amp = min(1, max(0.18, 0.5 + 0.5 * a * b))
        return max(barWidth, maxHeight * CGFloat(amp))
    }
}
