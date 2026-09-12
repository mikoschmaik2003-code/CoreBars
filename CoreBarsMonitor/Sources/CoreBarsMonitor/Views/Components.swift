import SwiftUI

/// A single vertical core-load bar, colored green/yellow/red by load.
struct CoreBar: View {
    let value: Double // 0-100

    private var color: Color {
        switch value {
        case ..<50: return .green
        case 50..<80: return .yellow
        default: return .red
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.gray.opacity(0.2))
                RoundedRectangle(cornerRadius: 3)
                    .fill(color)
                    .frame(height: geo.size.height * CGFloat(min(max(value, 0), 100)) / 100)
            }
        }
    }
}

/// A horizontal fill bar (used for RAM).
struct ProgressBar: View {
    let value: Double // 0-1
    var color: Color = .blue

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.2))
                RoundedRectangle(cornerRadius: 4)
                    .fill(color)
                    .frame(width: geo.size.width * CGFloat(min(max(value, 0), 1)))
            }
        }
    }
}

/// A rolling line-graph over the last N samples (like the waveform graphs
/// in typical hardware monitors).
struct SparklineView: View {
    let values: [Double] // 0-100
    var color: Color = .cyan

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            var path = Path()
            let stepX = size.width / CGFloat(values.count - 1)
            for (i, v) in values.enumerated() {
                let x = CGFloat(i) * stepX
                let y = size.height - (CGFloat(min(max(v, 0), 100)) / 100 * size.height)
                if i == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            context.stroke(path, with: .color(color), lineWidth: 2)
        }
        .background(Color.gray.opacity(0.1))
        .cornerRadius(4)
    }
}
