import Foundation
import Darwin

/// CPU, memory and disk — sampled only while something on screen shows them.
@MainActor
final class SystemStats: ObservableObject {
    static let shared = SystemStats()

    @Published private(set) var cpu: Double = 0
    @Published private(set) var memory: Double = 0
    @Published private(set) var disk: Double = 0
    @Published private(set) var diskFree: Int64 = 0

    private var previous: (used: UInt64, total: UInt64)?
    private var timer: Timer?
    private var users = 0

    func start() {
        users += 1
        guard timer == nil else { return }
        sample()
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        if let ticks = Self.cpuTicks() {
            if let prev = previous, ticks.total > prev.total {
                let c = min(1, max(0, Double(ticks.used - prev.used) / Double(ticks.total - prev.total)))
                if abs(c - cpu) >= 0.005 { cpu = c }
            }
            previous = ticks
        }
        // Publish only what a gauge would show differently (half a percent), not every sample.
        let mem = Self.memoryUsage()
        if abs(mem - memory) >= 0.005 { memory = mem }
        if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
           let total = v.volumeTotalCapacity, total > 0, let free = v.volumeAvailableCapacityForImportantUsage {
            let used = min(1, max(0, 1 - Double(free) / Double(total)))
            if abs(used - disk) >= 0.001 {
                diskFree = free
                disk = used
            }
        }
    }

    private static func cpuTicks() -> (used: UInt64, total: UInt64)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        return (user + system + nice, user + system + nice + idle)
    }

    private static func memoryUsage() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let page = UInt64(vm_kernel_page_size)
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        let total = ProcessInfo.processInfo.physicalMemory
        return total > 0 ? min(1, Double(used) / Double(total)) : 0
    }
}
