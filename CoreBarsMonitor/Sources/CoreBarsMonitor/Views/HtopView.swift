import SwiftUI

/// A dark, monospaced view inspired by htop: bracketed load meters per core
/// at the top, then a live process table sorted by CPU usage.
struct HtopView: View {
    @EnvironmentObject var monitor: SystemMonitor

    private let meterColumns = [GridItem(.adaptive(minimum: 220), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: meterColumns, spacing: 6) {
                ForEach(Array(monitor.coreLoads.enumerated()), id: \.offset) { idx, load in
                    HtopMeterRow(label: String(format: "%-3d", idx), value: load, color: .cyan)
                }
                HtopMeterRow(label: "Mem", value: monitor.memUsedFraction * 100, color: .green)
                if let gpu = monitor.gpuUsage {
                    HtopMeterRow(label: "GPU", value: gpu, color: .purple)
                }
            }

            HStack(spacing: 20) {
                Text("Tasks: \(monitor.processes.count)")
                Text("CPU: \(Int(monitor.totalCPU))%")
                Text("↓ \(formatRate(monitor.netDown))  ↑ \(formatRate(monitor.netUp))")
            }
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.white.opacity(0.8))

            HStack {
                Text("PID").frame(width: 60, alignment: .leading)
                Text("CPU%").frame(width: 60, alignment: .trailing)
                Text("MEM%").frame(width: 60, alignment: .trailing)
                Text("COMMAND").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(.caption, design: .monospaced).bold())
            .foregroundStyle(.black)
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(Color.green)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(monitor.processes) { proc in
                        HStack {
                            Text("\(proc.pid)").frame(width: 60, alignment: .leading)
                            Text(String(format: "%.1f", proc.cpu)).frame(width: 60, alignment: .trailing)
                            Text(String(format: "%.1f", proc.mem)).frame(width: 60, alignment: .trailing)
                            Text(proc.name).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.green)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 6)
                    }
                }
            }
        }
        .padding()
        .background(Color.black)
    }
}

/// One htop-style bracketed meter: `label [######      ] 42%`
struct HtopMeterRow: View {
    let label: String
    let value: Double // 0-100
    var color: Color = .cyan

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 32, alignment: .leading)
                .foregroundStyle(.white)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.white.opacity(0.08))
                    Rectangle()
                        .fill(color)
                        .frame(width: geo.size.width * CGFloat(min(max(value, 0), 100)) / 100)
                    Text("\(Int(value))%")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.trailing, 4)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(height: 16)
            .cornerRadius(2)
        }
    }
}
