import Foundation
import Darwin
import IOKit

/// One row in the process table (used by the htop-style view).
struct ProcessEntry: Identifiable {
    let id: Int32
    var pid: Int32 { id }
    let name: String
    let cpu: Double   // percent
    let mem: Double   // percent
}

/// Samples CPU (per core), RAM, GPU (best effort) and network throughput
/// once per second and publishes them for the SwiftUI views.
///
/// All the low-level reads here are the same unprivileged macOS APIs that
/// Activity Monitor and open-source menu-bar monitors (e.g. "Stats" on
/// GitHub) use — no sudo/root required.
final class SystemMonitor: ObservableObject {
    @Published var coreLoads: [Double] = []       // percent per core, 0-100
    @Published var totalCPU: Double = 0           // percent, 0-100
    @Published var cpuHistory: [Double] = []

    @Published var gpuUsage: Double? = nil        // percent, nil if unavailable
    @Published var gpuHistory: [Double] = []

    @Published var memUsed: UInt64 = 0
    @Published var memTotal: UInt64 = 0

    @Published var netUp: Double = 0              // bytes/sec
    @Published var netDown: Double = 0            // bytes/sec

    @Published var processes: [ProcessEntry] = []

    var memUsedFraction: Double {
        memTotal == 0 ? 0 : Double(memUsed) / Double(memTotal)
    }

    private var prevCoreTicks: [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)] = []
    private var prevNet: (received: UInt64, sent: UInt64, time: Date)?
    private var timer: Timer?
    private let historyLimit = 60

    init() {
        memTotal = SystemMonitor.totalMemory()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        timer?.invalidate()
    }

    private func refresh() {
        updateCPU()
        updateMemory()
        updateNetwork()
        updateGPU()
        updateProcesses()
    }

    // MARK: - CPU (per core, via host_processor_info — same API Activity Monitor uses)

    private func updateCPU() {
        guard let ticks = SystemMonitor.hostCPULoadInfo() else { return }

        if prevCoreTicks.count == ticks.count {
            var loads: [Double] = []
            var totalUsed: Double = 0
            var totalAll: Double = 0

            for i in 0..<ticks.count {
                let prev = prevCoreTicks[i]
                let cur = ticks[i]

                let userDelta = Double(cur.user &- prev.user)
                let sysDelta = Double(cur.system &- prev.system)
                let niceDelta = Double(cur.nice &- prev.nice)
                let idleDelta = Double(cur.idle &- prev.idle)
                let total = userDelta + sysDelta + niceDelta + idleDelta
                let used = userDelta + sysDelta + niceDelta

                loads.append(total > 0 ? (used / total) * 100 : 0)
                totalUsed += used
                totalAll += total
            }

            coreLoads = loads
            totalCPU = totalAll > 0 ? (totalUsed / totalAll) * 100 : 0
            appendHistory(&cpuHistory, value: totalCPU)
        }

        prevCoreTicks = ticks
    }

    private static func hostCPULoadInfo() -> [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)]? {
        var numCPUsU: natural_t = 0
        var cpuInfo: processor_info_array_t!
        var numCpuInfo: mach_msg_type_number_t = 0

        let result = host_processor_info(mach_host_self(),
                                          PROCESSOR_CPU_LOAD_INFO,
                                          &numCPUsU,
                                          &cpuInfo,
                                          &numCpuInfo)
        guard result == KERN_SUCCESS, let info = cpuInfo else { return nil }

        var loads: [(UInt32, UInt32, UInt32, UInt32)] = []
        for i in 0..<Int(numCPUsU) {
            let offset = Int(CPU_STATE_MAX) * i
            let user = UInt32(info[offset + Int(CPU_STATE_USER)])
            let system = UInt32(info[offset + Int(CPU_STATE_SYSTEM)])
            let idle = UInt32(info[offset + Int(CPU_STATE_IDLE)])
            let nice = UInt32(info[offset + Int(CPU_STATE_NICE)])
            loads.append((user, system, idle, nice))
        }

        let size = vm_size_t(numCpuInfo) * vm_size_t(MemoryLayout<integer_t>.stride)
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: UInt(bitPattern: info)), size)

        return loads
    }

    // MARK: - Memory (via host_statistics64)

    private func updateMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }

        let pageSize = UInt64(vm_kernel_page_size)
        memUsed = (UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * pageSize
    }

    private static func totalMemory() -> UInt64 {
        var total: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &total, &size, nil, 0)
        return total
    }

    // MARK: - Network (via getifaddrs, physical en* interfaces only)

    private func updateNetwork() {
        guard let (received, sent) = SystemMonitor.networkBytes() else { return }
        let now = Date()
        if let prev = prevNet {
            let elapsed = now.timeIntervalSince(prev.time)
            if elapsed > 0 {
                netDown = Double(received &- prev.received) / elapsed
                netUp = Double(sent &- prev.sent) / elapsed
            }
        }
        prevNet = (received, sent, now)
    }

    private static func networkBytes() -> (received: UInt64, sent: UInt64)? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        var received: UInt64 = 0
        var sent: UInt64 = 0
        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr

        while let current = ptr {
            let interface = current.pointee
            let name = String(cString: interface.ifa_name)
            if name.hasPrefix("en"),
               let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
               let data = interface.ifa_data {
                let networkData = data.assumingMemoryBound(to: if_data.self).pointee
                received += UInt64(networkData.ifi_ibytes)
                sent += UInt64(networkData.ifi_obytes)
            }
            ptr = interface.ifa_next
        }
        return (received, sent)
    }

    // MARK: - GPU (best effort via IOKit "IOAccelerator" performance stats)
    //
    // There is no public, documented API for a single "GPU usage %" on
    // macOS. This reads the same IORegistry "PerformanceStatistics" entry
    // that third-party menu-bar tools use. It can return nil on some Mac
    // models/macOS versions — the UI shows "not available" in that case
    // instead of crashing or guessing.

    private func updateGPU() {
        guard let usage = SystemMonitor.readGPUUtilization() else {
            gpuUsage = nil
            return
        }
        gpuUsage = usage
        appendHistory(&gpuHistory, value: usage)
    }

    private static func readGPUUtilization() -> Double? {
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching("IOAccelerator") else { return nil }
        guard IOServiceGetMatchingServices(kIOMasterPortDefault, matching, &iterator) == kIOReturnSuccess else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }

            var propsUnmanaged: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &propsUnmanaged, kCFAllocatorDefault, 0) == kIOReturnSuccess,
                  let props = propsUnmanaged?.takeRetainedValue() as? [String: Any],
                  let perf = props["PerformanceStatistics"] as? [String: Any] else {
                continue
            }

            if let utilization = perf["Device Utilization %"] as? Int {
                return Double(utilization)
            }
            if let utilization = perf["GPU Activity(%)"] as? Int {
                return Double(utilization)
            }
        }
        return nil
    }

    // MARK: - Processes (via `ps`, sorted by CPU — simplest reliable source)

    private func updateProcesses() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-Ao", "pid,pcpu,pmem,comm", "-r"]

        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = Pipe()

        do {
            try task.run()
        } catch {
            return
        }
        task.waitUntilExit()

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return }

        var entries: [ProcessEntry] = []
        let lines = output.split(separator: "\n").dropFirst() // skip header row
        for line in lines.prefix(80) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count >= 4,
                  let pid = Int32(parts[0]),
                  let cpu = Double(parts[1]),
                  let mem = Double(parts[2]) else { continue }
            entries.append(ProcessEntry(id: pid, name: String(parts[3]), cpu: cpu, mem: mem))
        }

        processes = entries
    }

    // MARK: - Helpers

    private func appendHistory(_ history: inout [Double], value: Double) {
        history.append(value)
        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }
    }
}

func formatBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
}

func formatRate(_ bytesPerSecond: Double) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .binary) + "/s"
}
