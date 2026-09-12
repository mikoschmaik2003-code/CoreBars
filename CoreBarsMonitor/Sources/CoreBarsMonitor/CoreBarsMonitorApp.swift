import SwiftUI

@main
struct CoreBarsMonitorApp: App {
    @StateObject private var monitor = SystemMonitor()

    var body: some Scene {
        WindowGroup("CoreBars Monitor") {
            ContentView()
                .environmentObject(monitor)
                .frame(minWidth: 760, minHeight: 560)
        }
        .windowResizability(.contentSize)
    }
}
