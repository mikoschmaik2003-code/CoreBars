import SwiftUI

enum MonitorMode: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case htop = "htop-Style"
    var id: String { rawValue }
}

struct ContentView: View {
    @State private var mode: MonitorMode = .dashboard

    var body: some View {
        VStack(spacing: 0) {
            Picker("Ansicht", selection: $mode) {
                ForEach(MonitorMode.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            Divider()

            switch mode {
            case .dashboard:
                DashboardView()
            case .htop:
                HtopView()
            }
        }
    }
}
