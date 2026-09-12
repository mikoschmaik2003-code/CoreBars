import SwiftUI

/// The "Balkenansicht" — a grid of per-core bars plus GPU/RAM/network,
/// similar in spirit to the multi-graph hardware monitor overlays.
struct DashboardView: View {
    @EnvironmentObject var monitor: SystemMonitor

    private let coreColumns = [GridItem(.adaptive(minimum: 64), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                GroupBox("CPU – Gesamt: \(Int(monitor.totalCPU))%") {
                    SparklineView(values: monitor.cpuHistory, color: .cyan)
                        .frame(height: 60)
                }

                GroupBox("CPU – Kerne (\(monitor.coreLoads.count))") {
                    LazyVGrid(columns: coreColumns, spacing: 10) {
                        ForEach(Array(monitor.coreLoads.enumerated()), id: \.offset) { idx, load in
                            VStack(spacing: 4) {
                                CoreBar(value: load)
                                    .frame(height: 90)
                                Text("Core \(idx)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text("\(Int(load))%")
                                    .font(.caption2).bold()
                            }
                        }
                    }
                    .padding(.top, 4)
                }

                HStack(alignment: .top, spacing: 20) {
                    GroupBox("GPU") {
                        VStack {
                            if let gpu = monitor.gpuUsage {
                                SparklineView(values: monitor.gpuHistory, color: .purple)
                                    .frame(height: 60)
                                Text("\(Int(gpu))%").bold()
                            } else {
                                Text("GPU-Auslastung nicht verfügbar\n(diese Mac-GPU meldet keinen Wert über die IOKit-Statistik)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .frame(height: 60)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }

                    GroupBox("RAM") {
                        VStack(spacing: 8) {
                            ProgressBar(value: monitor.memUsedFraction, color: .blue)
                                .frame(height: 24)
                            Text("\(formatBytes(monitor.memUsed)) / \(formatBytes(monitor.memTotal))")
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }

                GroupBox("Netzwerk") {
                    HStack(spacing: 30) {
                        Label("\(formatRate(monitor.netDown))", systemImage: "arrow.down.circle")
                            .foregroundStyle(.blue)
                        Label("\(formatRate(monitor.netUp))", systemImage: "arrow.up.circle")
                            .foregroundStyle(.orange)
                        Spacer()
                    }
                    .font(.callout)
                }
            }
            .padding()
        }
    }
}
