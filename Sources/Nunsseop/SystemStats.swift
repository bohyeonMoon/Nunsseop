import Darwin
import SwiftUI

/// CPU, memory, network and disk figures, sampled only while the System tab is visible. The figures are settable so that a render can put its own in.
@MainActor
final class SystemStats: ObservableObject {
    @Published var cpu: Double = 0
    @Published var memoryUsed: UInt64 = 0
    let memoryTotal = ProcessInfo.processInfo.physicalMemory
    @Published var downloadRate: Double = 0
    @Published var uploadRate: Double = 0
    @Published var diskFree: Int64 = 0
    @Published var diskTotal: Int64 = 0

    private var timer: Timer?
    private var lastTicks: (busy: UInt64, total: UInt64)?
    private var lastBytes: (received: UInt64, sent: UInt64, at: Date)?

    func start() {
        guard timer == nil else { return }
        lastTicks = nil
        lastBytes = nil
        sample()
        // CPU and network are rates, so take a second reading right away rather than showing zero until the next tick.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.timer != nil else { return }
            self.sample()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer?.tolerance = 0.15
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        if let ticks = Self.cpuTicks() {
            if let last = lastTicks, ticks.total > last.total {
                cpu = Double(ticks.busy - last.busy) / Double(ticks.total - last.total)
            }
            lastTicks = ticks
        }
        memoryUsed = Self.memoryInUse()
        let bytes = Self.networkBytes()
        let now = Date()
        if let last = lastBytes {
            let seconds = max(0.5, now.timeIntervalSince(last.at))
            downloadRate = Self.rate(previous: last.received, current: bytes.received, seconds: seconds)
            uploadRate = Self.rate(previous: last.sent, current: bytes.sent, seconds: seconds)
        }
        lastBytes = (bytes.received, bytes.sent, now)
        if let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            diskFree = values.volumeAvailableCapacityForImportantUsage ?? 0
            diskTotal = Int64(values.volumeTotalCapacity ?? 0)
        }
    }

    nonisolated static func rate(previous: UInt64, current: UInt64, seconds: Double) -> Double {
        // The counters are 32-bit sums over all interfaces, so one that wraps or disappears makes the total drop.
        current >= previous ? Double(current - previous) / seconds : 0
    }

    private static func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        return (user + system + nice, user + system + nice + idle)
    }

    private static func memoryInUse() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let page = UInt64(vm_kernel_page_size)
        return (UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
    }

    private static func networkBytes() -> (received: UInt64, sent: UInt64) {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return (0, 0) }
        defer { freeifaddrs(pointer) }
        var received: UInt64 = 0, sent: UInt64 = 0
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = entry.pointee
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  let data = interface.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            let name = String(cString: interface.ifa_name)
            guard !name.hasPrefix("lo") else { continue }
            received += UInt64(data.pointee.ifi_ibytes)
            sent += UInt64(data.pointee.ifi_obytes)
        }
        return (received, sent)
    }
}

struct SystemTab: View {
    @ObservedObject var stats: SystemStats
    let peripherals: PeripheralMonitor?
    /// The battery of this Mac; nil on a Mac without one, or when the Battery panel is turned off.
    var power: PowerState?

    private struct Figure {
        let label: String
        let fraction: Double
        let caption: String
        var symbol: String?
        var tint: Color = .white.opacity(0.75)
        var tick: Double?
    }

    private var figures: [Figure] {
        var all = [
            Figure(label: "CPU", fraction: stats.cpu, caption: String(localized: "\(ProcessInfo.processInfo.activeProcessorCount) cores")),
            Figure(label: String(localized: "Memory"), fraction: stats.memoryTotal > 0 ? Double(stats.memoryUsed) / Double(stats.memoryTotal) : 0,
                   caption: "\(Self.bytes(Int64(stats.memoryUsed))) / \(Self.bytes(Int64(stats.memoryTotal)))"),
            Figure(label: String(localized: "Disk"), fraction: stats.diskTotal > 0 ? 1 - Double(stats.diskFree) / Double(stats.diskTotal) : 0,
                   caption: String(localized: "\(Self.bytes(stats.diskFree)) free")),
        ]
        if let power {
            all.append(Figure(label: String(localized: "Battery"), fraction: Double(power.percent) / 100, caption: power.caption,
                              symbol: power.isCharging ? "bolt.fill" : nil, tint: power.isLow ? PanelInk.waiting : .white.opacity(0.75),
                              tick: power.isLow ? PowerState.lowPercent / 100 : nil))
        }
        return all
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelColumns(figures) { figure in
                let percent = Int((min(1, max(0, figure.fraction)) * 100).rounded())
                PanelMetric(label: figure.label, value: "\(percent)", unit: "%", caption: figure.caption, fraction: figure.fraction,
                            captionSymbol: figure.symbol, tint: figure.tint, tick: figure.tick)
            }
            .padding(.top, 6)
            .frame(height: 84, alignment: .top)
            PanelHLine()
            PanelColumns(peripherals == nil ? [0] : [0, 1]) { column in
                if column == 0 { network } else if let peripherals { DeviceList(monitor: peripherals) }
            }
            .padding(.top, 2)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .foregroundStyle(.white)
        .onAppear { stats.start() }
        .onDisappear { stats.stop() }
    }

    private var network: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelCaption(String(localized: "Network")).frame(height: 22)
            HStack(spacing: 22) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down").font(.system(size: 11, weight: .semibold)).accessibilityLabel(Text("Download"))
                    Text.panel(Self.bytes(Int64(stats.downloadRate)) + "/s", size: 15, weight: .semibold, mono: true).lineLimit(1)
                }
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up").font(.system(size: 11, weight: .semibold)).accessibilityLabel(Text("Upload"))
                    Text.panel(Self.bytes(Int64(stats.uploadRate)) + "/s", size: 15, weight: .semibold, opacity: 0.8, mono: true).lineLimit(1)
                }
            }
            .frame(height: 26, alignment: .leading)
        }
    }

    static func bytes(_ value: Int64) -> String {
        // The formatter spells out "bytes" in the user's language; keep "B" like KB and MB.
        if value < 1024 { return "\(max(0, value)) B" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .memory)
    }
}

/// Batteries of the mouse, keyboard and trackpad: a bar each, orange with the word "Low" when one runs out.
private struct DeviceList: View {
    @ObservedObject var monitor: PeripheralMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelCaption(String(localized: "Devices")).frame(height: 22)
            if monitor.devices.isEmpty {
                Text("No battery devices connected").font(.system(size: 11)).foregroundStyle(PanelInk.secondary).frame(height: 20)
            }
            // Three or more devices scroll instead of running past the bottom of the notch.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(monitor.devices) { device in
                        let low = device.isLow
                        HStack(spacing: 8) {
                            Image(systemName: device.symbol).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7)).frame(width: 16)
                                .accessibilityHidden(true)
                            Text(verbatim: device.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Spacer(minLength: 4)
                            PanelMeter(fraction: Double(device.percent) / 100, tint: low ? PanelInk.waiting : .white.opacity(0.75)).frame(width: 64)
                            Text.panel("\(device.percent)%", size: 11, weight: .semibold, opacity: low ? 1 : 0.8, mono: true)
                                .foregroundStyle(low ? PanelInk.waiting : .white.opacity(0.8))
                                .frame(width: 34, alignment: .trailing)
                            Text("Low").font(.system(size: 11, weight: .medium)).foregroundStyle(PanelInk.waiting)
                                .opacity(low ? 1 : 0).frame(width: 26, alignment: .leading)
                        }
                        .frame(height: 20)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(verbatim: device.name))
                        .accessibilityValue(Text(verbatim: "\(device.percent)%" + (low ? " " + String(localized: "Low") : "")))
                    }
                }
            }
        }
        .onAppear { monitor.refresh() }
    }
}
