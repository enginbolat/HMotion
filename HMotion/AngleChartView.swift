import SwiftUI

/// Rolling line chart of angular deviation, drawn with plain `Path` — no charting
/// dependency, and cheap enough to redraw at the motion sample rate.
struct AngleChartView: View {
    let samples: [HeadTrackingController.Sample]
    let thresholdDegrees: Double
    let window: TimeInterval
    /// Draw the threshold guide only when it actually governs behaviour.
    let showsThreshold: Bool

    /// Keep the threshold comfortably inside the plot, but never squash small
    /// deviations into a flat line at the bottom.
    private var yMax: Double { max(60, thresholdDegrees * 1.4) }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size

            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary.opacity(0.4))

                if showsThreshold {
                    Path { path in
                        let y = yPosition(for: thresholdDegrees, in: size)
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    .stroke(.orange, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }

                Path { path in
                    guard let latest = samples.last else { return }
                    let start = latest.timestamp - window
                    var hasOrigin = false

                    for sample in samples where sample.timestamp >= start {
                        let x = size.width * CGFloat((sample.timestamp - start) / window)
                        let point = CGPoint(x: x, y: yPosition(for: sample.angleDegrees, in: size))
                        if hasOrigin {
                            path.addLine(to: point)
                        } else {
                            path.move(to: point)
                            hasOrigin = true
                        }
                    }
                }
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
        }
        .overlay(alignment: .topLeading) {
            Text("\(Int(yMax))°")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .padding(3)
        }
        .overlay(alignment: .bottomTrailing) {
            Text("last \(Int(window))s")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .padding(3)
        }
    }

    private func yPosition(for degrees: Double, in size: CGSize) -> CGFloat {
        size.height * CGFloat(1 - min(degrees / yMax, 1))
    }
}
