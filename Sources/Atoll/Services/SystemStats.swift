import Foundation
import Darwin

/// CPU, memory, pressure, disk, network and heat — sampled only while something on screen shows them, every two
/// seconds, from the kernel's own counters. Nothing here is estimated: what macOS doesn't expose (GPU load) isn't shown.
@MainActor
final class SystemStats: ObservableObject {
    static let shared = SystemStats()

    enum Pressure: Int { case normal = 1, warning = 2, critical = 4 }

    @Published private(set) var cpu: Double = 0
    @Published private(set) var memory: Double = 0
    @Published private(set) var disk: Double = 0
    @Published private(set) var diskFree: Int64 = 0
    @Published private(set) var diskTotal: Int64 = 0
    /// The kernel's memory pressure level (what Activity Monitor's graph colours).
    @Published private(set) var pressure: Pressure = .normal
    /// Bytes per second across the Mac's network interfaces (Wi-Fi and Ethernet), down and up.
    @Published private(set) var netIn: Double = 0
    @Published private(set) var netOut: Double = 0
    @Published private(set) var thermal: ProcessInfo.ThermalState = .nominal
    /// The last few minutes, oldest first, for sparklines.
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var netHistory: [Double] = []

    static let historyLength = 40
    var memoryTotal: UInt64 { ProcessInfo.processInfo.physicalMemory }
    private var previousNet: (bytesIn: UInt64, bytesOut: UInt64, at: TimeInterval)?

    private var previous: (used: UInt64, total: UInt64)?
    private var timer: Timer?
    private var users = 0

    func start() {
        users += 1
        guard timer == nil else { return }
        sample()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
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
        cpuHistory = Array((cpuHistory + [cpu]).suffix(Self.historyLength))
        // Publish only what a gauge would show differently (half a percent), not every sample.
        let mem = Self.memoryUsage()
        if abs(mem - memory) >= 0.005 { memory = mem }
        if let p = Self.pressureLevel(), p != pressure { pressure = p }
        let heat = ProcessInfo.processInfo.thermalState
        if heat != thermal { thermal = heat }
        if let bytes = Self.networkBytes() {
            let now = ProcessInfo.processInfo.systemUptime
            if let prev = previousNet, now > prev.at {
                // 32-bit interface counters wrap; a wrap reads as a negative step and is skipped.
                let dIn = bytes.bytesIn >= prev.bytesIn ? Double(bytes.bytesIn - prev.bytesIn) : 0
                let dOut = bytes.bytesOut >= prev.bytesOut ? Double(bytes.bytesOut - prev.bytesOut) : 0
                netIn = dIn / (now - prev.at)
                netOut = dOut / (now - prev.at)
                netHistory = Array((netHistory + [netIn + netOut]).suffix(Self.historyLength))
            }
            previousNet = (bytes.bytesIn, bytes.bytesOut, now)
        }
        if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
           let total = v.volumeTotalCapacity, total > 0, let free = v.volumeAvailableCapacityForImportantUsage {
            let used = min(1, max(0, 1 - Double(free) / Double(total)))
            if abs(used - disk) >= 0.001 {
                diskFree = free
                diskTotal = Int64(total)
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

    private static func pressureLevel() -> Pressure? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return nil }
        return Pressure(rawValue: Int(level))
    }

    /// Bytes received and sent on the physical interfaces (en*), from the link-layer counters.
    private static func networkBytes() -> (bytesIn: UInt64, bytesOut: UInt64)? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var bytesIn: UInt64 = 0, bytesOut: UInt64 = 0
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let a = p.pointee
            guard let addr = a.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK), let data = a.ifa_data,
                  String(cString: a.ifa_name).hasPrefix("en") else { continue }
            let d = data.assumingMemoryBound(to: if_data.self).pointee
            bytesIn += UInt64(d.ifi_ibytes)
            bytesOut += UInt64(d.ifi_obytes)
        }
        return (bytesIn, bytesOut)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        let b = max(0, bytesPerSecond)
        if b < 1024 { return "\(Int(b)) B/s" }
        if b < 1024 * 1024 { return String(format: "%.0f KB/s", b / 1024) }
        return String(format: "%.1f MB/s", b / 1024 / 1024)
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
