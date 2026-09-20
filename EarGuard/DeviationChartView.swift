import SwiftUI

/// One point on the deviation chart.
struct AngleSample: Identifiable, Equatable {
    let timestamp: TimeInterval
    let degrees: Double
    var id: TimeInterval { timestamp }
}

/// Rolling line chart of angular deviation, drawn with plain `Path`.
///
/// Mirrors the macOS `AngleChartView`; kept separate rather than shared because the
/// two targets have no common source group, and the drawing is small enough that
/// cross-target coupling would cost more than the duplication.
struct DeviationChartView: View {
    let samples: [AngleSample]
    let thresholdDegrees: Double
    let window: TimeInterval

    /// Keep the threshold comfortably inside the plot, but never squash small
    /// deviations into a flat line at the bottom.
    private var yMax: Double { max(60, thresholdDegrees * 1.4) }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size

            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.secondarySystemBackground))

                Path { path in
                    let y = yPosition(for: thresholdDegrees, in: size)
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                }
                .stroke(.orange, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

                Path { path in
                    guard let latest = samples.last else { return }
                    let start = latest.timestamp - window
                    var hasOrigin = false

                    for sample in samples where sample.timestamp >= start {
                        let x = size.width * CGFloat((sample.timestamp - start) / window)
                        let point = CGPoint(x: x, y: yPosition(for: sample.degrees, in: size))
                        if hasOrigin {
                            path.addLine(to: point)
                        } else {
                            path.move(to: point)
                            hasOrigin = true
                        }
                    }
                }
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            }
        }
        .overlay(alignment: .topLeading) {
            Text("\(Int(yMax))°")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(4)
        }
        .overlay(alignment: .bottomTrailing) {
            Text("last \(Int(window))s")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(4)
        }
    }

    private func yPosition(for degrees: Double, in size: CGSize) -> CGFloat {
        size.height * CGFloat(1 - min(degrees / yMax, 1))
    }
}
