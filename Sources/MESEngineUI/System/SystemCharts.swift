import Charts
import DesignScaffold
import SwiftUI

// History charts for the System page: a percentage area chart, a value chart in the quantity's own units, and the disk's
// read/write lines, each with a hover readout. Ported from Nativ (MIT, see THIRD-PARTY-NOTICES.md).

/// A 0–100% area chart.
struct PercentHistoryChart: View {
    let title: String
    let samples: [SystemHistorySample]
    let color: Color
    var footer: String?
    @State private var hovered: SystemHistorySample?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            HStack {
                Text(title).font(Tokens.Font.headline)
                Spacer()
                if let footer { Text(footer).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel) }
            }
            if samples.isEmpty {
                ChartPlaceholder()
            } else {
                Chart {
                    ForEach(samples) { sample in
                        AreaMark(x: .value("Time", sample.recordedAt), y: .value("Usage", sample.value * 100))
                            .foregroundStyle(LinearGradient(colors: [color.opacity(0.42), color.opacity(0.06)],
                                                            startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.catmullRom)
                        LineMark(x: .value("Time", sample.recordedAt), y: .value("Usage", sample.value * 100))
                            .foregroundStyle(color)
                            .lineStyle(.init(lineWidth: 1.5))
                            .interpolationMethod(.catmullRom)
                    }
                    if let hovered {
                        HoverMarks(date: hovered.recordedAt,
                                   rows: [ChartHoverRow(title: title, value: ConsoleFormat.percent(hovered.value), color: color)])
                        PointMark(x: .value("Hovered time", hovered.recordedAt), y: .value("Hovered usage", hovered.value * 100))
                            .foregroundStyle(color)
                            .symbolSize(38)
                    }
                }
                .chartXScale(domain: chartTimeDomain(for: [samples]), range: .plotDimension(startPadding: 0, endPadding: 0))
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                        AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
                        AxisValueLabel { if let percent = value.as(Int.self) { Text("\(percent)%") } }
                            .foregroundStyle(Tokens.Color.secondaryLabel)
                    }
                }
                .chartXAxis { timeAxis }
                .chartOverlay { proxy in
                    ChartHoverOverlay(proxy: proxy, dataRevision: samples.last?.recordedAt) { date in
                        let next = date.flatMap(samples.nearest(to:))
                        if hovered != next { hovered = next }
                    }
                }
                .frame(minHeight: 170)
            }
        }
        .padding(Tokens.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}

/// A chart of a quantity in its own units (frame rate, temperature, power, bytes).
struct ValueHistoryChart: View {
    let title: String
    let samples: [SystemHistorySample]
    let color: Color
    /// The hover readout's row label.
    let seriesName: String
    let format: (Double) -> String
    /// The y-axis snaps to multiples of this, so the plot doesn't rescale on every sample.
    let axisStep: Double
    /// The smallest upper bound, so a quiet chart doesn't zoom into noise.
    let axisMinimum: Double
    /// Whether zero is a meaningful floor. A die never approaches 0 °C, so temperature anchors just below its minimum
    /// instead; otherwise real drift would render as a flat line at the top of the plot.
    var anchorsAtZero = true
    @State private var hovered: SystemHistorySample?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            HStack {
                Text(title).font(Tokens.Font.headline)
                Spacer()
                if let current = samples.last?.value {
                    Text(format(current)).font(Tokens.Font.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Tokens.Color.secondaryLabel)
                }
            }
            if samples.isEmpty {
                ChartPlaceholder()
            } else {
                Chart {
                    ForEach(samples) { sample in
                        // Filled from the axis floor, not zero: on a series that doesn't anchor at zero the default
                        // baseline sits outside the domain and the area bleeds past the bottom of the plot.
                        AreaMark(x: .value("Time", sample.recordedAt), yStart: .value("Baseline", axisRange.lowerBound),
                                 yEnd: .value(seriesName, sample.value))
                            .foregroundStyle(LinearGradient(colors: [color.opacity(0.44), color.opacity(0.06)],
                                                            startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.catmullRom)
                        LineMark(x: .value("Time", sample.recordedAt), y: .value(seriesName, sample.value))
                            .foregroundStyle(color)
                            .lineStyle(.init(lineWidth: 1.5))
                            .interpolationMethod(.catmullRom)
                    }
                    if let hovered {
                        HoverMarks(date: hovered.recordedAt,
                                   rows: [ChartHoverRow(title: seriesName, value: format(hovered.value), color: color)])
                        PointMark(x: .value("Hovered time", hovered.recordedAt), y: .value("Hovered \(seriesName)", hovered.value))
                            .foregroundStyle(color)
                            .symbolSize(38)
                    }
                }
                .chartXScale(domain: chartTimeDomain(for: [samples]), range: .plotDimension(startPadding: 0, endPadding: 0))
                .chartYScale(domain: axisRange)
                .chartYAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { value in
                        AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
                        AxisValueLabel { if let number = value.as(Double.self) { Text(format(number)) } }
                            .foregroundStyle(Tokens.Color.secondaryLabel)
                    }
                }
                .chartXAxis { timeAxis }
                .chartOverlay { proxy in
                    ChartHoverOverlay(proxy: proxy, dataRevision: samples.last?.recordedAt) { date in
                        let next = date.flatMap(samples.nearest(to:))
                        if hovered != next { hovered = next }
                    }
                }
                .frame(minHeight: 190)
            }
        }
        .padding(Tokens.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private var axisRange: ClosedRange<Double> {
        let values = samples.map(\.value)
        let upper = max(axisMinimum, ceil((values.max() ?? 0) / axisStep) * axisStep)
        guard !anchorsAtZero else { return 0...upper }
        let lower = max(0, floor((values.min() ?? 0) / axisStep) * axisStep)
        // A run flat enough to land inside one step would otherwise give an empty domain.
        return lower < upper ? lower...upper : lower...(lower + axisStep)
    }
}

/// Disk read and write rates on one chart.
struct DiskHistoryChart: View {
    let readSamples: [SystemHistorySample]
    let writeSamples: [SystemHistorySample]
    let currentRead: Double
    let currentWrite: Double
    @State private var hoveredDate: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                Text("Read/Write History").font(Tokens.Font.headline)
                Spacer()
                LegendItem(title: "Read", value: ConsoleFormat.byteRate(currentRead), color: ConsolePalette.read)
                LegendItem(title: "Write", value: ConsoleFormat.byteRate(currentWrite), color: ConsolePalette.write)
            }
            if readSamples.isEmpty && writeSamples.isEmpty {
                ChartPlaceholder()
            } else {
                Chart {
                    ForEach(readSamples) { sample in
                        LineMark(x: .value("Time", sample.recordedAt), y: .value("Bytes per second", sample.value),
                                 series: .value("Series", "Read"))
                            .foregroundStyle(ConsolePalette.read)
                            .interpolationMethod(.catmullRom)
                    }
                    ForEach(writeSamples) { sample in
                        LineMark(x: .value("Time", sample.recordedAt), y: .value("Bytes per second", sample.value),
                                 series: .value("Series", "Write"))
                            .foregroundStyle(ConsolePalette.write)
                            .interpolationMethod(.catmullRom)
                    }
                    if let hoveredDate {
                        HoverMarks(date: hoveredDate, rows: rows(at: hoveredDate))
                    }
                }
                .chartXScale(domain: chartTimeDomain(for: [readSamples, writeSamples]),
                             range: .plotDimension(startPadding: 0, endPadding: 0))
                .chartYAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { value in
                        AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
                        AxisValueLabel { if let bytes = value.as(Double.self) { Text(ConsoleFormat.byteRate(bytes)) } }
                            .foregroundStyle(Tokens.Color.secondaryLabel)
                    }
                }
                .chartXAxis { timeAxis }
                .chartOverlay { proxy in
                    ChartHoverOverlay(proxy: proxy, dataRevision: [readSamples.last?.recordedAt, writeSamples.last?.recordedAt]
                        .compactMap { $0 }.max()) { date in
                        if hoveredDate != date { hoveredDate = date }
                    }
                }
                .frame(minHeight: 190)
            }
        }
        .padding(Tokens.Space.l)
        .cardSurface()
    }

    private func rows(at date: Date) -> [ChartHoverRow] {
        var rows: [ChartHoverRow] = []
        if let read = readSamples.nearest(to: date) {
            rows.append(ChartHoverRow(title: "Read", value: ConsoleFormat.byteRate(read.value), color: ConsolePalette.read))
        }
        if let write = writeSamples.nearest(to: date) {
            rows.append(ChartHoverRow(title: "Write", value: ConsoleFormat.byteRate(write.value), color: ConsolePalette.write))
        }
        return rows
    }
}

// MARK: - Shared chart parts

@AxisContentBuilder
private var timeAxis: some AxisContent {
    AxisMarks(values: .automatic(desiredCount: 5)) {
        AxisGridLine().foregroundStyle(Color.secondary.opacity(0.08))
        AxisValueLabel(format: .dateTime.hour().minute()).foregroundStyle(Tokens.Color.secondaryLabel)
    }
}

/// The dashed rule and tooltip at the hovered time.
private struct HoverMarks: ChartContent {
    let date: Date
    let rows: [ChartHoverRow]

    var body: some ChartContent {
        RuleMark(x: .value("Hovered time", date))
            .foregroundStyle(Color.secondary.opacity(0.45))
            .lineStyle(.init(lineWidth: 1, dash: [3, 3]))
            .annotation(position: .top, alignment: .center, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                ChartHoverTooltip(recordedAt: date, rows: rows)
            }
    }
}

/// Tracks the pointer over the plot and reports the date under it.
private struct ChartHoverOverlay: View {
    let proxy: ChartProxy
    let dataRevision: Date?
    let onDateChange: (Date?) -> Void
    @State private var pointer: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        pointer = location
                        onDateChange(date(at: location, in: geometry))
                    case .ended:
                        pointer = nil
                        onDateChange(nil)
                    }
                }
                .onChange(of: dataRevision) { _, _ in
                    guard let pointer else { return }
                    onDateChange(date(at: pointer, in: geometry))
                }
        }
    }

    private func date(at location: CGPoint, in geometry: GeometryProxy) -> Date? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let rect = geometry[plotFrame]
        guard rect.contains(location) else { return nil }
        return proxy.value(atX: location.x - rect.minX)
    }
}

private func chartTimeDomain(for groups: [[SystemHistorySample]]) -> ClosedRange<Date> {
    let dates = groups.flatMap { [$0.first?.recordedAt, $0.last?.recordedAt].compactMap { $0 } }
    guard let first = dates.min(), let last = dates.max() else {
        let now = Date()
        return now.addingTimeInterval(-1)...now
    }
    return first < last ? first...last : first.addingTimeInterval(-0.5)...last.addingTimeInterval(0.5)
}

private struct ChartHoverRow: Identifiable {
    let title: String
    let value: String
    let color: Color
    var id: String { title }
}

private struct ChartHoverTooltip: View {
    let recordedAt: Date
    let rows: [ChartHoverRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(recordedAt, format: .dateTime.hour().minute().second())
                .font(Tokens.Font.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(Tokens.Color.secondaryLabel)
            ForEach(rows) { row in
                HStack(spacing: 6) {
                    Circle().fill(row.color).frame(width: 6, height: 6)
                    Text(row.title).foregroundStyle(Tokens.Color.secondaryLabel)
                    Spacer(minLength: 10)
                    Text(row.value).fontWeight(.semibold).monospacedDigit()
                }
                .font(Tokens.Font.caption)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(minWidth: 128)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Tokens.Radius.control + 2, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.control + 2, style: .continuous).stroke(Color.primary.opacity(0.12))
        }
        .shadow(color: Color.black.opacity(0.12), radius: 8, y: 3)
    }
}

private struct ChartPlaceholder: View {
    var body: some View {
        VStack(spacing: Tokens.Space.s) {
            ProgressView().controlSize(.small)
            Text("Collecting live samples…").font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel)
        }
        .frame(maxWidth: .infinity, minHeight: 170)
    }
}

extension Array where Element == SystemHistorySample {
    /// The sample closest in time to `date` (binary search; samples are in time order).
    func nearest(to date: Date) -> SystemHistorySample? {
        guard !isEmpty else { return nil }
        var low = 0
        var high = count
        while low < high {
            let middle = (low + high) / 2
            if self[middle].recordedAt < date { low = middle + 1 } else { high = middle }
        }
        if low == 0 { return self[0] }
        if low == count { return self[count - 1] }
        let previous = self[low - 1]
        let next = self[low]
        return abs(previous.recordedAt.timeIntervalSince(date)) <= abs(next.recordedAt.timeIntervalSince(date)) ? previous : next
    }
}
