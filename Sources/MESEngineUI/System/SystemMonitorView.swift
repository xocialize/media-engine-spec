import DesignScaffold
import SwiftUI

// The System page: live performance and hardware health for the Mac the engine runs on. Its layout is Nativ's system
// monitor (MIT, see THIRD-PARTY-NOTICES.md); the Memory page adds what an engine operator needs, the engine's own
// footprint and the GPU working set models must fit in.

enum SystemTab: String, CaseIterable, Identifiable {
    case overview, cpu, gpu, memory, disk, sensors

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "Memory"
        case .disk: "Disk"
        case .sensors: "Sensors"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .cpu: "cpu"
        case .gpu: "display"
        case .memory: "memorychip"
        case .disk: "internaldrive"
        case .sensors: "thermometer.medium"
        }
    }
}

/// Live performance and hardware health for this Mac. Samples while it's on screen.
public struct SystemMonitorView: View {
    let store: SystemMonitorStore
    let menuBar: MenuBarPreferences
    @State private var observer = UUID()
    @State private var tab: SystemTab = .overview

    public init(store: SystemMonitorStore, menuBar: MenuBarPreferences) {
        self.store = store
        self.menuBar = menuBar
    }

    public var body: some View {
        VStack(spacing: 0) {
            ConsoleSectionHeader(title: "System", subtitle: "Live performance and hardware health for this Mac") {
                MenuBarCustomizationButton(preferences: menuBar)
                HStack(spacing: 6) {
                    Circle().fill(store.isSampling ? Tokens.Color.ready : Tokens.Color.tertiaryLabel).frame(width: 7, height: 7)
                    Text(store.isSampling ? "Live" : "Paused")
                        .font(Tokens.Font.caption.weight(.semibold))
                        .foregroundStyle(Tokens.Color.secondaryLabel)
                }
                Button {
                    if store.isPaused { store.resume() } else { store.pause() }
                } label: {
                    Image(systemName: store.isPaused ? "play.fill" : "pause.fill").frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .help(store.isPaused ? "Resume monitoring" : "Pause monitoring")
                Button { store.refresh() } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .help("Refresh now")
            }
            Separator(.horizontal)
            ConsoleTabBar(tabs: SystemTab.allCases, selection: $tab, title: \.title, symbol: \.symbol)
            Separator(.horizontal)
            page.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { store.beginObservation(observer) }
        .onDisappear { store.endObservation(observer) }
    }

    @ViewBuilder private var page: some View {
        let s = store.snapshot
        switch tab {
        case .overview: OverviewPage(snapshot: s)
        case .cpu: CPUPage(snapshot: s, history: store.cpuHistory)
        case .gpu: GPUPage(snapshot: s, gpuHistory: store.gpuHistory, aneHistory: store.aneHistory, fpsHistory: store.fpsHistory)
        case .memory:
            MemoryPage(snapshot: s, memoryHistory: store.memoryHistory, swapHistory: store.swapHistory,
                       footprintHistory: store.footprintHistory)
        case .disk: DiskPage(snapshot: s, readHistory: store.diskReadHistory, writeHistory: store.diskWriteHistory)
        case .sensors: SensorsPage(snapshot: s, temperatureHistory: store.temperatureHistory, powerHistory: store.powerHistory)
        }
    }
}

// MARK: - Overview

private struct OverviewPage: View {
    let snapshot: SystemMonitorSnapshot
    private var identity: SystemMonitorIdentity { snapshot.identity }

    var body: some View {
        ConsolePage(title: "Overview", subtitle: "Hardware at a glance") {
            ConsolePanel {
                VStack(spacing: Tokens.Space.m) {
                    SystemDeviceArtwork(identity: identity)
                    VStack(spacing: Tokens.Space.xs) {
                        Text(identity.computerName).font(Tokens.Font.panelTitle)
                        Text(identity.chipName).font(Tokens.Font.body.weight(.medium)).foregroundStyle(Tokens.Color.secondaryLabel)
                        Text(identity.operatingSystem).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.tertiaryLabel)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Tokens.Space.s)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 140), spacing: 14), count: 4), spacing: 14) {
                MetricBadge(title: "CPU", value: ConsoleFormat.percent(snapshot.cpu.totalUsage),
                            detail: "\(identity.physicalCoreCount) cores", symbol: "cpu", tint: ConsolePalette.cpu)
                MetricBadge(title: "GPU", value: ConsoleFormat.percent(snapshot.gpu.deviceUsage),
                            detail: identity.gpuCoreCount.map { "\($0) cores" } ?? identity.gpuName, symbol: "display",
                            tint: ConsolePalette.gpu)
                MetricBadge(title: "Memory", value: ConsoleFormat.percent(snapshot.memory.usage),
                            detail: "\(ConsoleFormat.memory(snapshot.memory.usedBytes)) used", symbol: "memorychip",
                            tint: ConsolePalette.memory)
                MetricBadge(title: "Disk", value: ConsoleFormat.percent(snapshot.disk.usage),
                            detail: snapshot.disk.availableBytes.map { "\(ConsoleFormat.bytes($0)) available" } ?? "Capacity unavailable",
                            symbol: "internaldrive", tint: ConsolePalette.disk)
            }
            AdaptivePair {
                InfoCard(title: "Hardware") {
                    InfoRow("Processor", value: "\(identity.chipName) · \(coreSummary)")
                    InfoRow("Memory", value: ConsoleFormat.memory(snapshot.memory.totalBytes))
                    InfoRow("GPU working set", value: ConsoleFormat.memory(identity.gpuWorkingSetBytes))
                    InfoRow("Graphics", value: identity.gpuCoreCount.map { "\(identity.gpuName) · \($0) cores" } ?? identity.gpuName)
                    InfoRow("Neural Engine", value: identity.aneCoreCount.map { "\($0) cores" } ?? missingValue)
                    InfoRow("Disk", value: "\(identity.disk.volumeName) · "
                        + (snapshot.disk.totalBytes.map(ConsoleFormat.bytes) ?? "Unavailable"))
                    InfoRow("Display", value: displaySummary)
                }
            } trailing: {
                InfoCard(title: "Device") {
                    InfoRow("Model identifier", value: identity.modelIdentifier)
                    InfoRow("Model number", value: identity.modelNumber ?? missingValue)
                    InfoRow("Serial number", value: identity.serialNumber)
                    InfoRow("File system", value: identity.disk.fileSystem)
                    InfoRow("Storage health", value: identity.disk.smartStatus ?? missingValue)
                    InfoRow("Thermal pressure", value: snapshot.thermal.thermalPressureLabel)
                    InfoRow("Uptime", value: ConsoleFormat.uptime(snapshot.uptime))
                }
            }
        }
    }

    private var coreSummary: String {
        identity.efficiencyCoreCount > 0 || identity.performanceCoreCount > 0
            ? "\(identity.efficiencyCoreCount)E / \(identity.performanceCoreCount)P" : "\(identity.physicalCoreCount) cores"
    }

    private var displaySummary: String {
        var parts = [identity.displayName, identity.displayResolution]
        if let rate = identity.displayRefreshRate { parts.append("\(Int(rate.rounded())) Hz") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - CPU

private struct CPUPage: View {
    let snapshot: SystemMonitorSnapshot
    let history: [SystemHistorySample]

    var body: some View {
        ConsolePage(title: "CPU", subtitle: "\(snapshot.identity.chipName) · \(snapshot.identity.physicalCoreCount) cores") {
            ConsolePanel {
                HStack(spacing: Tokens.Space.xl) {
                    UsageGauge(value: snapshot.cpu.totalUsage, tint: ConsolePalette.cpu, label: "CPU usage")
                    VStack(alignment: .leading, spacing: Tokens.Space.m) {
                        Text(snapshot.identity.chipName).font(Tokens.Font.headline)
                        SegmentedBar(segments: [(snapshot.cpu.systemUsage, ConsolePalette.write),
                                                (snapshot.cpu.userUsage, ConsolePalette.cpu)])
                        HStack(spacing: 18) {
                            LegendItem(title: "System", value: ConsoleFormat.percent(snapshot.cpu.systemUsage), color: ConsolePalette.write)
                            LegendItem(title: "User", value: ConsoleFormat.percent(snapshot.cpu.userUsage), color: ConsolePalette.cpu)
                            LegendItem(title: "Idle", value: ConsoleFormat.percent(snapshot.cpu.idleUsage), color: ConsolePalette.idle)
                            Spacer()
                            Text("Load " + snapshot.cpu.loadAverages.map { $0.formatted(.number.precision(.fractionLength(2))) }
                                .joined(separator: " · "))
                                .font(Tokens.Font.caption.monospacedDigit())
                                .foregroundStyle(Tokens.Color.secondaryLabel)
                        }
                    }
                }
            }
            PercentHistoryChart(title: "Usage History", samples: history, color: ConsolePalette.cpu)
            VStack(alignment: .leading, spacing: Tokens.Space.m) {
                Text("Load per Core").font(Tokens.Font.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14)], spacing: Tokens.Space.m) {
                    ForEach(Array(snapshot.cpu.coreUsage.enumerated()), id: \.offset) { index, usage in
                        LabeledBar(title: coreTitle(index), value: usage,
                                   tint: isEfficiency(index) ? ConsolePalette.cpu : ConsolePalette.disk)
                    }
                }
                .padding(Tokens.Space.m + 2)
                .cardSurface()
            }
        }
    }

    private func isEfficiency(_ index: Int) -> Bool { index < snapshot.identity.efficiencyCoreCount }

    private func coreTitle(_ index: Int) -> String {
        isEfficiency(index) ? "Efficiency core \(index + 1)"
            : "Performance core \(max(index - snapshot.identity.efficiencyCoreCount + 1, 1))"
    }
}

// MARK: - GPU

private struct GPUPage: View {
    let snapshot: SystemMonitorSnapshot
    let gpuHistory: [SystemHistorySample]
    let aneHistory: [SystemHistorySample]
    let fpsHistory: [SystemHistorySample]

    var body: some View {
        ConsolePage(title: "GPU", subtitle: snapshot.identity.gpuCoreCount.map { "\(snapshot.identity.gpuName) · \($0) cores" }
            ?? snapshot.identity.gpuName) {
            ConsolePanel {
                VStack(alignment: .leading, spacing: Tokens.Space.l) {
                    HStack {
                        Label(snapshot.identity.gpuName, systemImage: "display").font(Tokens.Font.headline)
                        Spacer()
                        if let memory = snapshot.gpu.allocatedMemoryBytes {
                            Text("\(ConsoleFormat.memory(memory)) allocated").font(Tokens.Font.caption)
                                .foregroundStyle(Tokens.Color.secondaryLabel)
                        }
                    }
                    LabeledBar(title: "GPU utilization", value: snapshot.gpu.deviceUsage, tint: ConsolePalette.cpu)
                    LabeledBar(title: "Neural Engine utilization", value: snapshot.gpu.aneUsage, tint: ConsolePalette.neural)
                    HStack {
                        Label("Display frame rate", systemImage: "speedometer").foregroundStyle(Tokens.Color.secondaryLabel)
                        Spacer()
                        Text(ConsoleFormat.framesPerSecond(snapshot.gpu.framesPerSecond)).fontWeight(.semibold).monospacedDigit()
                    }
                    .font(Tokens.Font.body)
                }
            }
            AdaptivePair {
                PercentHistoryChart(title: "GPU Utilization History", samples: gpuHistory, color: ConsolePalette.cpu)
            } trailing: {
                PercentHistoryChart(title: "Neural Engine Utilization History", samples: aneHistory, color: ConsolePalette.neural)
            }
            ValueHistoryChart(title: "FPS History", samples: fpsHistory, color: ConsolePalette.cpu, seriesName: "Frame rate",
                              format: { ConsoleFormat.framesPerSecond($0) }, axisStep: 30, axisMinimum: 30)
        }
    }
}

// MARK: - Memory

private struct MemoryPage: View {
    let snapshot: SystemMonitorSnapshot
    let memoryHistory: [SystemHistorySample]
    let swapHistory: [SystemHistorySample]
    let footprintHistory: [SystemHistorySample]
    private var memory: SystemMemoryMetrics { snapshot.memory }

    var body: some View {
        ConsolePage(title: "Memory", subtitle: "\(ConsoleFormat.memory(memory.totalBytes)) unified memory") {
            ConsolePanel {
                HStack(spacing: Tokens.Space.xl) {
                    UsageGauge(value: memory.usage, tint: pressureColor, label: "Memory pressure \(memory.pressureLabel)")
                    VStack(alignment: .leading, spacing: Tokens.Space.m) {
                        HStack {
                            Text("Used: \(ConsoleFormat.memory(memory.usedBytes))").font(Tokens.Font.headline)
                            Spacer()
                            Text("Total: \(ConsoleFormat.memory(memory.totalBytes))").foregroundStyle(Tokens.Color.secondaryLabel)
                        }
                        SegmentedBar(segments: [(fraction(memory.activeBytes), ConsolePalette.cpu),
                                                (fraction(memory.wiredBytes), ConsolePalette.disk),
                                                (fraction(memory.compressedBytes), ConsolePalette.write)])
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: Tokens.Space.l) { legend }
                            VStack(alignment: .leading, spacing: 7) { legend }
                        }
                    }
                }
            }
            AdaptivePair {
                InfoCard(title: "This Engine") {
                    InfoRow("Engine process", value: ConsoleFormat.memory(snapshot.processFootprintBytes))
                    InfoRow("GPU working set", value: ConsoleFormat.memory(snapshot.identity.gpuWorkingSetBytes))
                    InfoRow("GPU allocated", value: ConsoleFormat.memory(snapshot.gpu.allocatedMemoryBytes))
                    InfoRow("Pressure", value: memory.pressureLabel)
                }
            } trailing: {
                InfoCard(title: "Swap") {
                    InfoRow("Used", value: ConsoleFormat.memory(memory.swapUsedBytes))
                    InfoRow("Total", value: ConsoleFormat.memory(memory.swapTotalBytes))
                    InfoRow("Cached files", value: ConsoleFormat.memory(memory.cachedBytes))
                    InfoRow("Available", value: ConsoleFormat.memory(memory.freeBytes))
                }
            }
            ValueHistoryChart(title: "Engine Footprint History", samples: footprintHistory, color: ConsolePalette.memory,
                              seriesName: "Engine process", format: { ConsoleFormat.memory(UInt64(max($0, 0))) },
                              axisStep: Double(4 << 30), axisMinimum: Double(4 << 30))
            PercentHistoryChart(title: "Memory Usage History", samples: memoryHistory, color: ConsolePalette.cpu)
            PercentHistoryChart(title: "Swap History", samples: swapHistory, color: ConsolePalette.swap,
                                footer: "\(ConsoleFormat.memory(memory.swapUsedBytes)) of \(ConsoleFormat.memory(memory.swapTotalBytes))")
        }
    }

    private func fraction(_ bytes: UInt64) -> Double { memory.totalBytes > 0 ? Double(bytes) / Double(memory.totalBytes) : 0 }

    @ViewBuilder private var legend: some View {
        LegendItem(title: "Active", value: ConsoleFormat.memory(memory.activeBytes), color: ConsolePalette.cpu)
        LegendItem(title: "Wired", value: ConsoleFormat.memory(memory.wiredBytes), color: ConsolePalette.disk)
        LegendItem(title: "Compressed", value: ConsoleFormat.memory(memory.compressedBytes), color: ConsolePalette.write)
        LegendItem(title: "Available", value: ConsoleFormat.memory(memory.freeBytes), color: ConsolePalette.idle)
    }

    private var pressureColor: Color {
        switch memory.pressureLabel {
        case "Normal": ConsolePalette.cpu
        case "Elevated": Tokens.Color.working
        default: Tokens.Color.failure
        }
    }
}

// MARK: - Disk

private struct DiskPage: View {
    let snapshot: SystemMonitorSnapshot
    let readHistory: [SystemHistorySample]
    let writeHistory: [SystemHistorySample]
    private var disk: SystemDiskIdentity { snapshot.identity.disk }

    var body: some View {
        ConsolePage(title: "Disk", subtitle: "\(disk.volumeName) · \(disk.fileSystem)") {
            ConsolePanel {
                HStack(spacing: Tokens.Space.xl) {
                    UsageGauge(value: snapshot.disk.usage, tint: usageColor, label: "Disk usage")
                    VStack(alignment: .leading, spacing: Tokens.Space.m) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(disk.volumeName).font(Tokens.Font.headline)
                                Text(disk.fileSystem).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel)
                            }
                            Spacer()
                            Text(snapshot.disk.totalBytes.map(ConsoleFormat.bytes) ?? missingValue)
                                .fontWeight(.medium).foregroundStyle(Tokens.Color.secondaryLabel)
                        }
                        ProgressView(value: snapshot.disk.usage ?? 0).tint(usageColor)
                        HStack(spacing: 20) {
                            LegendItem(title: "Used", value: snapshot.disk.usedBytes.map(ConsoleFormat.bytes) ?? missingValue,
                                       color: usageColor)
                            LegendItem(title: "Available", value: snapshot.disk.availableBytes.map(ConsoleFormat.bytes) ?? missingValue,
                                       color: ConsolePalette.idle)
                        }
                    }
                }
            }
            DiskHistoryChart(readSamples: readHistory, writeSamples: writeHistory,
                             currentRead: snapshot.disk.readBytesPerSecond, currentWrite: snapshot.disk.writeBytesPerSecond)
            AdaptivePair {
                InfoCard(title: "Details") {
                    InfoRow("Read", value: ConsoleFormat.byteRate(snapshot.disk.readBytesPerSecond), color: ConsolePalette.read)
                    InfoRow("Write", value: ConsoleFormat.byteRate(snapshot.disk.writeBytesPerSecond), color: ConsolePalette.write)
                    InfoRow("Read since boot", value: ConsoleFormat.bytes(snapshot.disk.cumulativeReadBytes))
                    InfoRow("Written since boot", value: ConsoleFormat.bytes(snapshot.disk.cumulativeWriteBytes))
                    InfoRow("Model", value: disk.model)
                    InfoRow("Connection", value: disk.connection)
                    InfoRow("BSD name", value: disk.deviceIdentifier)
                    InfoRow("Encrypted", value: ConsoleFormat.boolean(disk.isEncrypted))
                }
            } trailing: {
                InfoCard(title: "SMART") {
                    InfoRow("Status", value: disk.smartStatus ?? missingValue)
                    InfoRow("Total read", value: disk.lifetimeReadBytes.map(ConsoleFormat.bytes) ?? missingValue)
                    InfoRow("Total written", value: disk.lifetimeWrittenBytes.map(ConsoleFormat.bytes) ?? missingValue)
                    InfoRow("Temperature", value: disk.temperatureCelsius.map { "\($0)°C" } ?? missingValue)
                    InfoRow("Health", value: disk.healthPercent.map { "\($0)%" } ?? missingValue)
                    InfoRow("Power cycles", value: disk.powerCycles.map { $0.formatted() } ?? missingValue)
                    InfoRow("Power-on hours", value: disk.powerOnHours.map { $0.formatted() } ?? missingValue)
                    InfoRow("Media errors", value: disk.mediaErrors.map { $0.formatted() } ?? missingValue)
                }
            }
        }
    }

    private var usageColor: Color {
        guard let usage = snapshot.disk.usage else { return Tokens.Color.secondaryLabel }
        return usage >= 0.90 ? Tokens.Color.failure : ConsolePalette.cpu
    }
}

// MARK: - Sensors

private struct SensorsPage: View {
    let snapshot: SystemMonitorSnapshot
    let temperatureHistory: [SystemHistorySample]
    let powerHistory: [SystemHistorySample]
    private var thermal: SystemThermalMetrics { snapshot.thermal }
    private var power: SystemPowerMetrics { snapshot.power }

    var body: some View {
        ConsolePage(title: "Sensors", subtitle: subtitle) {
            if !SystemSensorSampler.isAvailable {
                ConsolePanel {
                    Label("This build reads thermal pressure only. Temperatures, fans and power need private interfaces, "
                          + "which builds outside the App Store include.", systemImage: "info.circle")
                        .font(Tokens.Font.body)
                        .foregroundStyle(Tokens.Color.secondaryLabel)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 140), spacing: 14), count: 4), spacing: 14) {
                MetricBadge(title: "Die temperature", value: ConsoleFormat.celsius(thermal.dieTemperatureCelsius),
                            detail: thermal.hottestSensorName ?? missingValue, symbol: "thermometer.medium", tint: ConsolePalette.heat)
                MetricBadge(title: "Power", value: ConsoleFormat.watts(power.headlineWatts),
                            detail: power.hasAnyReading ? power.headlineLabel : missingValue, symbol: "bolt.fill",
                            tint: ConsolePalette.power)
                MetricBadge(title: "Fans", value: ConsoleFormat.rpm(thermal.maximumFanRPM),
                            detail: thermal.hasFans ? "\(thermal.fanSpeedsRPM.count) fans" : missingValue, symbol: "fan.fill",
                            tint: ConsolePalette.cooling)
                MetricBadge(title: "Thermal pressure", value: thermal.thermalPressureLabel,
                            detail: thermal.thermalPressure == .nominal ? "Not throttling" : "Throttling likely",
                            symbol: "gauge.with.dots.needle.67percent", tint: pressureTint)
            }
            if SystemSensorSampler.isAvailable {
                ValueHistoryChart(title: "Temperature History", samples: temperatureHistory, color: ConsolePalette.heat,
                                  seriesName: "Die temperature", format: { ConsoleFormat.celsius($0) }, axisStep: 10,
                                  axisMinimum: 60, anchorsAtZero: false)
                ValueHistoryChart(title: "Power History", samples: powerHistory, color: ConsolePalette.power,
                                  seriesName: power.headlineLabel, format: { ConsoleFormat.watts($0) }, axisStep: 10, axisMinimum: 10)
                AdaptivePair {
                    InfoCard(title: "Power Breakdown") {
                        InfoRow("CPU", value: ConsoleFormat.watts(power.cpuWatts))
                        InfoRow("GPU", value: ConsoleFormat.watts(power.gpuWatts))
                        InfoRow("Neural Engine", value: ConsoleFormat.watts(power.aneWatts))
                        InfoRow("Memory", value: ConsoleFormat.watts(power.dramWatts))
                        InfoRow("SoC package", value: ConsoleFormat.watts(power.socWatts))
                        InfoRow("System input", value: ConsoleFormat.watts(power.systemInputWatts))
                    }
                } trailing: {
                    InfoCard(title: "Cooling") {
                        if thermal.hasFans {
                            ForEach(Array(thermal.fanSpeedsRPM.enumerated()), id: \.offset) { index, rpm in
                                InfoRow("Fan \(index + 1)", value: ConsoleFormat.rpm(rpm))
                            }
                        } else {
                            InfoRow("Fans", value: "None reported")
                        }
                        InfoRow("Thermal pressure", value: thermal.thermalPressureLabel)
                        InfoRow("Sensors", value: "\(thermal.sensors.count)")
                    }
                }
                if !thermal.sensors.isEmpty {
                    VStack(alignment: .leading, spacing: Tokens.Space.m) {
                        Text("All Sensors").font(Tokens.Font.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14)], spacing: Tokens.Space.m) {
                            ForEach(thermal.sensors) { InfoRow($0.name, value: ConsoleFormat.celsius($0.celsius)) }
                        }
                        .padding(Tokens.Space.m + 2)
                        .cardSurface()
                    }
                }
            }
        }
    }

    private var subtitle: String {
        guard let temperature = thermal.dieTemperatureCelsius else { return "Temperature, power and cooling" }
        return "\(ConsoleFormat.celsius(temperature)) · \(thermal.sensors.count) sensors"
    }

    private var pressureTint: Color {
        switch thermal.thermalPressure {
        case .nominal: Tokens.Color.ready
        case .fair: Tokens.Color.working
        default: Tokens.Color.failure
        }
    }
}

// MARK: - Parts

private struct UsageGauge: View {
    let value: Double?
    let tint: Color
    let label: String

    var body: some View {
        Gauge(value: value ?? 0) {
            Text(label)
        } currentValueLabel: {
            Text(ConsoleFormat.percent(value)).font(Tokens.Font.headline.monospacedDigit())
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .tint(tint)
        .frame(width: 86, height: 86)
        .accessibilityLabel(label)
    }
}

/// A label, a percentage and a bar.
struct LabeledBar: View {
    let title: String
    let value: Double?
    let tint: Color

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text(title).foregroundStyle(Tokens.Color.secondaryLabel)
                Spacer()
                Text(ConsoleFormat.percent(value)).fontWeight(.semibold).monospacedDigit()
            }
            .font(Tokens.Font.body)
            ProgressView(value: value ?? 0).tint(tint)
        }
    }
}
