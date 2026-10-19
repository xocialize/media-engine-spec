import AppKit
import CoreGraphics
import Darwin
import Foundation
import IOKit
import Metal
import Observation
import QuartzCore

// Live hardware metrics for the System page and the menu-bar item. Ported from Nativ's system monitor (MIT, see
// THIRD-PARTY-NOTICES.md): CPU ticks, VM statistics, the GPU's and disks' IORegistry counters, all public interfaces.
// Temperatures, fans and power come from SystemSensors.swift, behind the `SystemSensors` trait.

struct SystemHistorySample: Identifiable, Equatable, Sendable {
    let recordedAt: Date
    let value: Double
    var id: Date { recordedAt }
}

struct SystemCPUMetrics: Equatable, Sendable {
    var totalUsage: Double = 0
    var userUsage: Double = 0
    var systemUsage: Double = 0
    var idleUsage: Double = 1
    var coreUsage: [Double] = []
    var loadAverages: [Double] = [0, 0, 0]
}

struct SystemGPUMetrics: Equatable, Sendable {
    var deviceUsage: Double?
    var aneUsage: Double?
    var framesPerSecond: Double?
    var allocatedMemoryBytes: UInt64?
}

struct SystemMemoryMetrics: Equatable, Sendable {
    var totalBytes: UInt64 = 0
    var usedBytes: UInt64 = 0
    var activeBytes: UInt64 = 0
    var wiredBytes: UInt64 = 0
    var compressedBytes: UInt64 = 0
    var cachedBytes: UInt64 = 0
    var freeBytes: UInt64 = 0
    var swapUsedBytes: UInt64 = 0
    var swapTotalBytes: UInt64 = 0

    var usage: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(usedBytes) / Double(totalBytes), 0), 1)
    }

    var pressureLabel: String {
        switch usage {
        case ..<0.70: "Normal"
        case ..<0.90: "Elevated"
        default: "Critical"
        }
    }
}

struct SystemDiskMetrics: Equatable, Sendable {
    var totalBytes: UInt64?
    var availableBytes: UInt64?
    var readBytesPerSecond: Double = 0
    var writeBytesPerSecond: Double = 0
    var cumulativeReadBytes: UInt64 = 0
    var cumulativeWriteBytes: UInt64 = 0

    var usedBytes: UInt64? {
        guard let totalBytes, let availableBytes, availableBytes <= totalBytes else { return nil }
        return totalBytes - availableBytes
    }

    var usage: Double? {
        guard let totalBytes, totalBytes > 0, let usedBytes else { return nil }
        return Double(usedBytes) / Double(totalBytes)
    }

    /// The capacities macOS's storage UI uses: important-usage capacity counts space the system can reclaim (purgeable
    /// APFS data), with raw available capacity as the fallback. Inconsistent values are rejected, so a failed read never
    /// shows as an empty disk.
    static func resolvedCapacity(total: Int?, availableForImportantUsage: Int64?, available: Int?)
        -> (total: UInt64, available: UInt64)? {
        guard let total = validatedBytes(total), total > 0 else { return nil }
        if let important = validatedBytes(availableForImportantUsage, notExceeding: total) { return (total, important) }
        guard let fallback = validatedBytes(available, notExceeding: total) else { return nil }
        return (total, fallback)
    }

    private static func validatedBytes<Value: BinaryInteger>(_ value: Value?, notExceeding upperBound: UInt64 = .max) -> UInt64? {
        guard let value, let bytes = UInt64(exactly: value), bytes <= upperBound else { return nil }
        return bytes
    }
}

struct SystemDiskIdentity: Equatable, Sendable {
    var volumeName = "Macintosh HD"
    var fileSystem = "APFS"
    var mountPoint = "/"
    var deviceIdentifier = missingValue
    var model = "Internal storage"
    var connection = "Internal"
    var isEncrypted: Bool?
    var isWritable: Bool?
    var smartStatus: String?
    var healthPercent: Int?
    var temperatureCelsius: Int?
    var powerCycles: UInt64?
    var powerOnHours: UInt64?
    var unsafeShutdowns: UInt64?
    var mediaErrors: UInt64?
    var availableSparePercent: Int?
    var lifetimeReadBytes: UInt64?
    var lifetimeWrittenBytes: UInt64?
}

struct SystemMonitorIdentity: Equatable, Sendable {
    var computerName = Host.current().localizedName ?? "This Mac"
    var modelIdentifier = missingValue
    var modelNumber: String?
    var enclosureColorCode: String?
    var serialNumber = missingValue
    var chipName = "Apple silicon"
    var physicalCoreCount = ProcessInfo.processInfo.processorCount
    var logicalCoreCount = ProcessInfo.processInfo.activeProcessorCount
    var efficiencyCoreCount = 0
    var performanceCoreCount = 0
    var gpuName = "Apple GPU"
    var gpuCoreCount: Int?
    var aneCoreCount: Int?
    var operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
    var displayName = "Built-in display"
    var displayResolution = missingValue
    var displayRefreshRate: Double?
    /// The GPU's recommended working set: what Metal (and so MLX) can keep resident at once.
    var gpuWorkingSetBytes: UInt64?
    var disk = SystemDiskIdentity()

    var deviceModelCode: String {
        guard let enclosureColorCode, !enclosureColorCode.isEmpty else { return modelIdentifier }
        return "\(modelIdentifier)@ECOLOR=\(enclosureColorCode)"
    }

    var deviceModelCodeCandidates: [String] {
        deviceModelCode == modelIdentifier ? [modelIdentifier] : [deviceModelCode, modelIdentifier]
    }
}

struct SystemMonitorSnapshot: Equatable, Sendable {
    var recordedAt = Date()
    var identity = SystemMonitorIdentity()
    var cpu = SystemCPUMetrics()
    var gpu = SystemGPUMetrics()
    var memory = SystemMemoryMetrics()
    var disk = SystemDiskMetrics()
    var thermal = SystemThermalMetrics()
    var power = SystemPowerMetrics()
    /// This process's physical footprint: the engine and the models it holds.
    var processFootprintBytes: UInt64?
    var uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
}

/// Samples once a second while anything observes it (the System page, or metrics in the menu bar), and not otherwise.
/// One store serves the window and the menu-bar item, so they agree and the Mac is sampled once.
@MainActor @Observable
public final class SystemMonitorStore {
    private(set) var snapshot = SystemMonitorSnapshot()
    private(set) var cpuHistory: [SystemHistorySample] = []
    private(set) var gpuHistory: [SystemHistorySample] = []
    private(set) var aneHistory: [SystemHistorySample] = []
    private(set) var fpsHistory: [SystemHistorySample] = []
    private(set) var memoryHistory: [SystemHistorySample] = []
    private(set) var swapHistory: [SystemHistorySample] = []
    private(set) var footprintHistory: [SystemHistorySample] = []
    private(set) var diskReadHistory: [SystemHistorySample] = []
    private(set) var diskWriteHistory: [SystemHistorySample] = []
    private(set) var temperatureHistory: [SystemHistorySample] = []
    private(set) var powerHistory: [SystemHistorySample] = []
    private(set) var isSampling = false
    private(set) var isPaused = false

    /// Called on the main actor after every sample (the menu-bar item redraws from it).
    @ObservationIgnored public var onSample: (() -> Void)?

    @ObservationIgnored private let collector = SystemMetricsCollector()
    @ObservationIgnored private let displayFPSSampler = SystemDisplayFPSSampler()
    @ObservationIgnored private let aneSampler = SystemANEUtilizationSampler()
    @ObservationIgnored private var samplingTask: Task<Void, Never>?
    @ObservationIgnored private var observers: Set<UUID> = []
    private let historyLimit = 300

    public init() {}

    isolated deinit { samplingTask?.cancel() }

    /// Starts sampling for `observer` (the first observer starts the clock).
    public func beginObservation(_ observer: UUID) {
        guard observers.insert(observer).inserted, observers.count == 1, !isPaused else { return }
        startSampling()
    }

    /// Stops sampling for `observer` (the last one out stops the clock).
    public func endObservation(_ observer: UUID) {
        guard observers.remove(observer) != nil, observers.isEmpty, !isPaused else { return }
        stopSampling()
    }

    func pause() {
        guard !isPaused else { return }
        isPaused = true
        if !observers.isEmpty { stopSampling() }
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        if !observers.isEmpty { startSampling() }
    }

    func refresh() {
        Task { [weak self] in
            guard let self else { return }
            apply(await collector.collect())
        }
    }

    private func startSampling() {
        guard samplingTask == nil else { return }
        isSampling = true
        displayFPSSampler.start()
        aneSampler.start()
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                var next = await collector.collect()
                next.gpu.framesPerSecond = displayFPSSampler.takeFramesPerSecond()
                next.gpu.aneUsage = aneSampler.takeUtilization()
                apply(next)
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private func stopSampling() {
        samplingTask?.cancel()
        samplingTask = nil
        displayFPSSampler.stop()
        aneSampler.stop()
        isSampling = false
    }

    private func apply(_ next: SystemMonitorSnapshot) {
        snapshot = next
        let at = next.recordedAt
        append(next.cpu.totalUsage, at: at, to: &cpuHistory)
        append(next.memory.usage, at: at, to: &memoryHistory)
        if let value = next.gpu.deviceUsage { append(value, at: at, to: &gpuHistory) }
        if let value = next.gpu.aneUsage { append(value, at: at, to: &aneHistory) }
        if let value = next.gpu.framesPerSecond { append(value, at: at, to: &fpsHistory) }
        let swap = next.memory.swapTotalBytes > 0
            ? Double(next.memory.swapUsedBytes) / Double(next.memory.swapTotalBytes) : 0
        append(swap, at: at, to: &swapHistory)
        if let bytes = next.processFootprintBytes { append(Double(bytes), at: at, to: &footprintHistory) }
        if let value = next.thermal.dieTemperatureCelsius { append(value, at: at, to: &temperatureHistory) }
        if let value = next.power.headlineWatts { append(value, at: at, to: &powerHistory) }
        append(next.disk.readBytesPerSecond, at: at, to: &diskReadHistory)
        append(next.disk.writeBytesPerSecond, at: at, to: &diskWriteHistory)
        onSample?()
    }

    private func append(_ value: Double, at date: Date, to samples: inout [SystemHistorySample]) {
        samples.append(SystemHistorySample(recordedAt: date, value: value))
        if samples.count > historyLimit { samples.removeFirst(samples.count - historyLimit) }
    }
}

private struct SystemCPUTicks: Sendable {
    let user: UInt64
    let system: UInt64
    let idle: UInt64
    var total: UInt64 { user + system + idle }
}

private struct SystemDiskCounters: Sendable {
    let readBytes: UInt64
    let writeBytes: UInt64
}

/// The main display's frame rate, counted from a display link.
@MainActor
private final class SystemDisplayFPSSampler: NSObject {
    private var displayLink: CADisplayLink?
    private var firstTimestamp: TimeInterval?
    private var lastTimestamp: TimeInterval?
    private var frameCount = 0

    func start() {
        guard displayLink == nil, let screen = NSScreen.main else { return }
        let link = screen.displayLink(target: self, selector: #selector(displayLinkDidFire(_:)))
        firstTimestamp = nil
        lastTimestamp = nil
        frameCount = 0
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        firstTimestamp = nil
        lastTimestamp = nil
        frameCount = 0
    }

    @objc private func displayLinkDidFire(_ sender: CADisplayLink) {
        if firstTimestamp == nil { firstTimestamp = sender.timestamp }
        lastTimestamp = sender.timestamp
        frameCount += 1
    }

    func takeFramesPerSecond() -> Double? {
        guard let firstTimestamp, let lastTimestamp, lastTimestamp > firstTimestamp, frameCount > 1 else { return nil }
        let fps = Double(frameCount - 1) / (lastTimestamp - firstTimestamp)
        self.firstTimestamp = lastTimestamp
        frameCount = 1
        return fps
    }
}

/// The Neural Engine's utilisation: the share of 10 ms polls that found an ANE service busy (IORegistry busy state).
private final class SystemANEUtilizationSampler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "mes-engine-ui.system-monitor.ane", qos: .utility)
    private var services: [io_service_t] = []
    private var timer: DispatchSourceTimer?
    private var sampleCount = 0
    private var busySampleCount = 0

    func start() {
        queue.sync {
            guard timer == nil else { return }
            services = ["H1xANELoadBalancer", "H11ANEIn", "AppleT6031ANEHAL"].compactMap { className in
                guard let matching = IOServiceMatching(className) else { return nil }
                let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
                return service == IO_OBJECT_NULL ? nil : service
            }
            guard !services.isEmpty else { return }
            sampleCount = 0
            busySampleCount = 0
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
            source.setEventHandler { [weak self] in self?.sampleBusyState() }
            timer = source
            source.resume()
        }
    }

    func stop() {
        queue.sync {
            timer?.setEventHandler {}
            timer?.cancel()
            timer = nil
            services.forEach { IOObjectRelease($0) }
            services = []
            sampleCount = 0
            busySampleCount = 0
        }
    }

    func takeUtilization() -> Double? {
        queue.sync {
            guard !services.isEmpty, sampleCount > 0 else { return nil }
            let utilization = Double(busySampleCount) / Double(sampleCount)
            sampleCount = 0
            busySampleCount = 0
            return min(max(utilization, 0), 1)
        }
    }

    private func sampleBusyState() {
        sampleCount += 1
        for service in services {
            var busyState: UInt32 = 0
            if IOServiceGetBusyState(service, &busyState) == KERN_SUCCESS, busyState > 0 {
                busySampleCount += 1
                return
            }
        }
    }
}

private actor SystemMetricsCollector {
    private var identity: SystemMonitorIdentity?
    private var lastDiskIdentityRefresh: Date?
    private var previousCPUTicks: [SystemCPUTicks] = []
    private var previousDiskCounters: SystemDiskCounters?
    private var previousDiskSampleDate: Date?
    /// Holds the sensor readers' handles open across samples.
    private let sensors = SystemSensorSampler()

    func collect() -> SystemMonitorSnapshot {
        let now = Date()
        let resolvedIdentity: SystemMonitorIdentity
        if var cached = identity {
            // SMART health and lifetime counters change while the app stays open.
            if lastDiskIdentityRefresh.map({ now.timeIntervalSince($0) >= 60 }) ?? true {
                cached.disk = Self.diskIdentity()
                identity = cached
                lastDiskIdentityRefresh = now
            }
            resolvedIdentity = cached
        } else {
            let captured = Self.captureIdentity()
            identity = captured
            lastDiskIdentityRefresh = now
            resolvedIdentity = captured
        }

        let ticks = Self.cpuTicks()
        let cpu = Self.cpuMetrics(current: ticks, previous: previousCPUTicks)
        previousCPUTicks = ticks

        let counters = Self.diskCounters()
        let disk = Self.diskMetrics(current: counters, previous: previousDiskCounters,
                                    elapsed: previousDiskSampleDate.map { now.timeIntervalSince($0) })
        previousDiskCounters = counters
        previousDiskSampleDate = now

        return SystemMonitorSnapshot(recordedAt: now, identity: resolvedIdentity, cpu: cpu, gpu: Self.gpuMetrics(),
                                     memory: Self.memoryMetrics(), disk: disk, thermal: sensors.thermalMetrics(),
                                     power: sensors.powerMetrics(), processFootprintBytes: Self.processFootprint(),
                                     uptime: ProcessInfo.processInfo.systemUptime)
    }

    private static func captureIdentity() -> SystemMonitorIdentity {
        var identity = SystemMonitorIdentity()
        identity.modelIdentifier = sysctlString("hw.model") ?? identity.modelIdentifier
        identity.chipName = sysctlString("machdep.cpu.brand_string") ?? identity.chipName
        identity.physicalCoreCount = sysctlInteger("hw.physicalcpu") ?? identity.physicalCoreCount
        identity.logicalCoreCount = sysctlInteger("hw.logicalcpu") ?? identity.logicalCoreCount
        identity.performanceCoreCount = sysctlInteger("hw.perflevel0.physicalcpu") ?? 0
        identity.efficiencyCoreCount = sysctlInteger("hw.perflevel1.physicalcpu") ?? 0
        identity.serialNumber = platformSerialNumber() ?? identity.serialNumber
        identity.enclosureColorCode = SystemSensorSampler.enclosureColorCode()
        if let profile = hardwareProfile() {
            identity.computerName = profile["machine_name"] as? String ?? identity.computerName
            identity.modelNumber = profile["model_number"] as? String
            identity.serialNumber = profile["serial_number"] as? String ?? identity.serialNumber
        }
        if let device = MTLCreateSystemDefaultDevice() {
            identity.gpuName = device.name
            identity.gpuWorkingSetBytes = device.recommendedMaxWorkingSetSize
        }
        if let configuration = gpuProperty("GPUConfigurationVariable") as? NSDictionary {
            identity.gpuCoreCount = number(configuration["num_cores"]).map(Int.init)
        }
        if let ane = registryProperty(serviceClass: "H11ANEIn", key: "DeviceProperties") as? NSDictionary {
            identity.aneCoreCount = number(ane["ANEDevicePropertyNumANECores"]).map(Int.init)
        }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        identity.operatingSystem = "macOS " + ["\(version.majorVersion)", "\(version.minorVersion)",
                                               version.patchVersion > 0 ? "\(version.patchVersion)" : nil]
            .compactMap { $0 }.joined(separator: ".")
        if let screen = NSScreen.main {
            identity.displayName = screen.localizedName
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
               let mode = CGDisplayCopyDisplayMode(CGDirectDisplayID(number.uint32Value)) {
                identity.displayResolution = "\(mode.pixelWidth) × \(mode.pixelHeight)"
                if mode.refreshRate > 0 { identity.displayRefreshRate = mode.refreshRate }
            }
        }
        identity.disk = diskIdentity()
        return identity
    }

    private static func cpuTicks() -> [SystemCPUTicks] {
        var processorCount: natural_t = 0
        var processorInfo: processor_info_array_t?
        var processorInfoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &processorCount, &processorInfo,
                                         &processorInfoCount)
        guard result == KERN_SUCCESS, let processorInfo else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: processorInfo)),
                          vm_size_t(processorInfoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        return (0..<Int(processorCount)).map { index in
            let offset = index * Int(CPU_STATE_MAX)
            return SystemCPUTicks(
                user: UInt64(processorInfo[offset + Int(CPU_STATE_USER)] + processorInfo[offset + Int(CPU_STATE_NICE)]),
                system: UInt64(processorInfo[offset + Int(CPU_STATE_SYSTEM)]),
                idle: UInt64(processorInfo[offset + Int(CPU_STATE_IDLE)]))
        }
    }

    private static func cpuMetrics(current: [SystemCPUTicks], previous: [SystemCPUTicks]) -> SystemCPUMetrics {
        let deltas = current.enumerated().map { index, value in
            guard previous.indices.contains(index) else { return value }
            let prior = previous[index]
            return SystemCPUTicks(user: value.user >= prior.user ? value.user - prior.user : 0,
                                  system: value.system >= prior.system ? value.system - prior.system : 0,
                                  idle: value.idle >= prior.idle ? value.idle - prior.idle : 0)
        }
        let aggregate = deltas.reduce(SystemCPUTicks(user: 0, system: 0, idle: 0)) {
            SystemCPUTicks(user: $0.user + $1.user, system: $0.system + $1.system, idle: $0.idle + $1.idle)
        }
        let total = max(Double(aggregate.total), 1)
        func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
        var loads = [Double](repeating: 0, count: 3)
        if getloadavg(&loads, 3) <= 0 { loads = [0, 0, 0] }
        return SystemCPUMetrics(
            totalUsage: clamp(1 - Double(aggregate.idle) / total), userUsage: clamp(Double(aggregate.user) / total),
            systemUsage: clamp(Double(aggregate.system) / total), idleUsage: clamp(Double(aggregate.idle) / total),
            coreUsage: deltas.map { $0.total > 0 ? clamp(1 - Double($0.idle) / Double($0.total)) : 0 },
            loadAverages: loads)
    }

    private static func memoryMetrics() -> SystemMemoryMetrics {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var kernelPageSize: vm_size_t = 0
        guard result == KERN_SUCCESS, host_page_size(mach_host_self(), &kernelPageSize) == KERN_SUCCESS else {
            return SystemMemoryMetrics(totalBytes: ProcessInfo.processInfo.physicalMemory)
        }
        let page = UInt64(kernelPageSize)
        let total = ProcessInfo.processInfo.physicalMemory
        let active = UInt64(statistics.active_count) * page
        let wired = UInt64(statistics.wire_count) * page
        let compressed = UInt64(statistics.compressor_page_count) * page
        let used = min(active + wired + compressed, total)
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride
        let hasSwap = sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0
        return SystemMemoryMetrics(totalBytes: total, usedBytes: used, activeBytes: active, wiredBytes: wired,
                                   compressedBytes: compressed, cachedBytes: UInt64(statistics.inactive_count) * page,
                                   freeBytes: total > used ? total - used : 0,
                                   swapUsedBytes: hasSwap ? swap.xsu_used : 0, swapTotalBytes: hasSwap ? swap.xsu_total : 0)
    }

    /// `phys_footprint`, the number Activity Monitor shows as Memory for a process.
    private static func processFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }

    private static func gpuMetrics() -> SystemGPUMetrics {
        guard let statistics = gpuProperty("PerformanceStatistics") as? NSDictionary else { return SystemGPUMetrics() }
        return SystemGPUMetrics(deviceUsage: number(statistics["Device Utilization %"]).map { min(max(Double($0) / 100, 0), 1) },
                                allocatedMemoryBytes: number(statistics["Alloc system memory"]))
    }

    private static func gpuProperty(_ key: String) -> Any? { registryProperty(serviceClass: "AGXAccelerator", key: key) }

    private static func registryProperty(serviceClass: String, key: String) -> Any? {
        guard let matching = IOServiceMatching(serviceClass) else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func diskMetrics(current: SystemDiskCounters, previous: SystemDiskCounters?,
                                    elapsed: TimeInterval?) -> SystemDiskMetrics {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ])
        let capacity = SystemDiskMetrics.resolvedCapacity(total: values?.volumeTotalCapacity,
                                                          availableForImportantUsage: values?.volumeAvailableCapacityForImportantUsage,
                                                          available: values?.volumeAvailableCapacity)
        let interval = max(elapsed ?? 0, 0)
        var readRate = 0.0
        var writeRate = 0.0
        if let previous, interval > 0 {
            readRate = Double(current.readBytes >= previous.readBytes ? current.readBytes - previous.readBytes : 0) / interval
            writeRate = Double(current.writeBytes >= previous.writeBytes ? current.writeBytes - previous.writeBytes : 0) / interval
        }
        return SystemDiskMetrics(totalBytes: capacity?.total, availableBytes: capacity?.available,
                                 readBytesPerSecond: readRate, writeBytesPerSecond: writeRate,
                                 cumulativeReadBytes: current.readBytes, cumulativeWriteBytes: current.writeBytes)
    }

    private static func diskCounters() -> SystemDiskCounters {
        guard let matching = IOServiceMatching("IOBlockStorageDriver") else { return SystemDiskCounters(readBytes: 0, writeBytes: 0) }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return SystemDiskCounters(readBytes: 0, writeBytes: 0)
        }
        defer { IOObjectRelease(iterator) }
        var readBytes: UInt64 = 0
        var writeBytes: UInt64 = 0
        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dictionary = properties?.takeRetainedValue() as NSDictionary?,
                  let statistics = dictionary["Statistics"] as? NSDictionary else { continue }
            readBytes += number(statistics["Bytes (Read)"]) ?? 0
            writeBytes += number(statistics["Bytes (Write)"]) ?? 0
        }
        return SystemDiskCounters(readBytes: readBytes, writeBytes: writeBytes)
    }

    private static func diskIdentity() -> SystemDiskIdentity {
        guard let volume = plist(run: "/usr/sbin/diskutil", ["info", "-plist", "/"]) as? [String: Any] else {
            return SystemDiskIdentity()
        }
        let physicalStore = (volume["APFSPhysicalStores"] as? [[String: Any]])?.first?["APFSPhysicalStore"] as? String
        let device = physicalStore.map(wholeDiskIdentifier).flatMap {
            plist(run: "/usr/sbin/diskutil", ["info", "-plist", $0]) as? [String: Any]
        }
        let smart = (device?["SMARTDeviceSpecificKeysMayVaryNotGuaranteed"]
            ?? volume["SMARTDeviceSpecificKeysMayVaryNotGuaranteed"]) as? [String: Any]
        let dataUnitBytes: UInt64 = 512_000
        return SystemDiskIdentity(
            volumeName: volume["VolumeName"] as? String ?? "Macintosh HD",
            fileSystem: volume["FilesystemUserVisibleName"] as? String ?? volume["FilesystemType"] as? String ?? "APFS",
            mountPoint: volume["MountPoint"] as? String ?? "/",
            deviceIdentifier: volume["DeviceIdentifier"] as? String ?? missingValue,
            model: device?["MediaName"] as? String ?? "Internal storage",
            connection: device?["BusProtocol"] as? String ?? volume["BusProtocol"] as? String ?? "Internal",
            isEncrypted: volume["Encryption"] as? Bool,
            isWritable: volume["WritableVolume"] as? Bool,
            smartStatus: device?["SMARTStatus"] as? String ?? volume["SMARTStatus"] as? String,
            healthPercent: int(smart?["PERCENTAGE_USED"]).map { max(0, 100 - $0) },
            temperatureCelsius: int(smart?["TEMPERATURE"]).map { max(0, $0 - 273) },
            powerCycles: number(smart?["POWER_CYCLES_0"]),
            powerOnHours: number(smart?["POWER_ON_HOURS_0"]),
            unsafeShutdowns: number(smart?["UNSAFE_SHUTDOWNS_0"]),
            mediaErrors: number(smart?["MEDIA_ERRORS_0"]),
            availableSparePercent: int(smart?["AVAILABLE_SPARE"]),
            lifetimeReadBytes: number(smart?["DATA_UNITS_READ_0"]).map { $0.multipliedReportingOverflow(by: dataUnitBytes).partialValue },
            lifetimeWrittenBytes: number(smart?["DATA_UNITS_WRITTEN_0"]).map { $0.multipliedReportingOverflow(by: dataUnitBytes).partialValue })
    }

    private static func hardwareProfile() -> [String: Any]? {
        guard let data = output(run: "/usr/sbin/system_profiler", ["SPHardwareDataType", "-json"]),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = root["SPHardwareDataType"] as? [[String: Any]] else { return nil }
        return entries.first
    }

    /// A system tool's standard output, or nil if it can't run (a sandbox may refuse it).
    private static func output(run tool: String, _ arguments: [String]) -> Data? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    private static func plist(run tool: String, _ arguments: [String]) -> Any? {
        output(run: tool, arguments).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) }
    }

    private static func wholeDiskIdentifier(_ identifier: String) -> String {
        let suffix = identifier.dropFirst(identifier.hasPrefix("disk") ? 4 : 0)
        guard let separator = suffix.firstIndex(of: "s") else { return identifier }
        return String(identifier[..<separator])
    }

    private static func platformSerialNumber() -> String? {
        registryProperty(serviceClass: "IOPlatformExpertDevice", key: "IOPlatformSerialNumber") as? String
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return String(decoding: value.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func sysctlInteger(_ name: String) -> Int? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    private static func number(_ value: Any?) -> UInt64? { (value as? NSNumber)?.uint64Value ?? value as? UInt64 }

    private static func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue ?? value as? Int }
}
