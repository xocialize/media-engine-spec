import AppKit
import DesignScaffold
import MESCore
import MESEngineCore
import Observation
import SwiftUI

/// The engine's menu-bar item. It shows the engine's icon with a count of active jobs, or live CPU, GPU and memory
/// readings (percentages, mini graphs, gigabytes) the operator picks. Its menu shows the job running now with its
/// progress, what's waiting, which models are in memory, and the console's sections. The metric rendering is Nativ's
/// (MIT, see THIRD-PARTY-NOTICES.md).
@MainActor
public final class EngineStatusItemController: NSObject, NSMenuDelegate {
    private let console: EngineConsoleModel
    private let system: SystemMonitorStore
    private let preferences: MenuBarPreferences
    private let open: (ConsoleSection) -> Void
    private let statusItem: NSStatusItem
    private let customization: MenuBarCustomizationMenu
    private let samplingObserver = UUID()
    private var sampling = false

    /// - Parameter open: shows the console window on a section.
    public init(console: EngineConsoleModel, system: SystemMonitorStore, menuBar: MenuBarPreferences,
                open: @escaping (ConsoleSection) -> Void) {
        self.console = console
        self.system = system
        self.preferences = menuBar
        self.open = open
        customization = MenuBarCustomizationMenu(preferences: menuBar)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        system.onSample = { [weak self] in self?.updateButton() }
        observe()
        updateButton()
    }

    // MARK: - The button

    /// Redraws when the metrics chosen, the jobs, or the engine's status change.
    private func observe() {
        withObservationTracking {
            _ = preferences.orderedItems
            _ = console.activity.jobs.count
            _ = console.activity.running.map(\.id)
            _ = console.status
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateButton()
                self?.observe()
            }
        }
    }

    private func updateButton() {
        let items = preferences.orderedItems
        // Sample the Mac only while the menu bar shows readings.
        if items.isEmpty, sampling {
            system.endObservation(samplingObserver)
            sampling = false
        } else if !items.isEmpty, !sampling {
            system.beginObservation(samplingObserver)
            sampling = true
        }
        guard let button = statusItem.button else { return }
        let active = console.activity.running.count + console.activity.upcoming.count
        var images: [NSImage] = []
        var descriptions: [String] = []
        if items.isEmpty || active > 0 {
            images.append(Self.engineImage(symbol: console.info.symbol, count: active, failed: isFailed))
            descriptions.append(active > 0 ? "\(console.info.name), \(active) active job\(active == 1 ? "" : "s")" : console.info.name)
        }
        let snapshot = system.snapshot
        for item in items {
            let usage = usage(item.metric, snapshot)
            let percent = Int((usage * 100).rounded())
            switch item.style {
            case .percentage:
                images.append(Self.percentageImage(label: item.metric.menuBarLabel, percent: percent))
                descriptions.append("\(item.metric.title) \(percent)%")
            case .graph:
                images.append(Self.graphImage(values: history(item.metric).suffix(30).map(\.value)))
                descriptions.append("\(item.metric.title) \(percent)% usage graph")
            case .gigabytes:
                let value = snapshot.memory.usedBytes > 0
                    ? (Double(snapshot.memory.usedBytes) / 1_073_741_824).formatted(.number.precision(.fractionLength(0))) + "\u{2009}GB"
                    : missingValue
                images.append(Self.gigabytesImage(value: value))
                descriptions.append("Memory \(value)")
            }
        }
        let description = descriptions.joined(separator: ", ")
        let image = Self.composite(images, accessibilityDescription: description)
        button.image = image
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.title = ""
        button.toolTip = description
        statusItem.length = image.size.width + 6
    }

    private var isFailed: Bool { if case .failed = console.status { true } else { false } }

    private func usage(_ metric: MenuBarMetric, _ s: SystemMonitorSnapshot) -> Double {
        switch metric {
        case .cpu: s.cpu.totalUsage
        case .gpu: s.gpu.deviceUsage ?? 0
        case .ram: s.memory.usage
        }
    }

    private func history(_ metric: MenuBarMetric) -> [SystemHistorySample] {
        switch metric {
        case .cpu: system.cpuHistory
        case .gpu: system.gpuHistory
        case .ram: system.memoryHistory
        }
    }

    // MARK: - The menu

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(headerItem())
        menu.addItem(.separator())

        let activity = console.activity
        menu.addItem(.sectionHeader(title: "Now"))
        if activity.running.isEmpty {
            menu.addItem(disabled(isFailed ? "Stopped" : "Idle"))
        } else {
            for job in activity.running { menu.addItem(runningItem(job)) }
        }
        if !activity.upcoming.isEmpty {
            menu.addItem(.sectionHeader(title: "Up Next · \(activity.upcoming.count)"))
            for job in activity.upcoming.prefix(5) {
                let item = action(jobLine(job, prefix: job.queuePosition.map { "\($0). " } ?? "· ")) { [weak self] in self?.open(.queue) }
                item.toolTip = job.summary
                menu.addItem(item)
            }
            if activity.upcoming.count > 5 { menu.addItem(disabled("and \(activity.upcoming.count - 5) more")) }
        }
        let resident = console.models.filter(\.resident)
        if !resident.isEmpty {
            menu.addItem(.sectionHeader(title: "In Memory"))
            for model in resident {
                let size = model.footprintBytes.map { " · \(ConsoleFormat.memory($0))" } ?? ""
                let item = NSMenuItem(title: model.title + size, action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                submenu.addItem(action("Release from Memory") { [weak self] in self?.console.unload(model: model.id) })
                submenu.addItem(action("Show in Models") { [weak self] in
                    self?.console.selectedModelID = model.id
                    self?.open(.models)
                })
                item.submenu = submenu
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        for (index, section) in ConsoleSection.allCases.enumerated() {
            let item = action("Open \(section.title)", key: "\(index + 1)") { [weak self] in self?.open(section) }
            item.image = NSImage(systemSymbolName: section.symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        let customize = NSMenuItem(title: "Customize Menu Bar", action: nil, keyEquivalent: "")
        customize.image = NSImage(systemSymbolName: "menubar.rectangle", accessibilityDescription: nil)
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        customization.addItems(to: submenu)
        customize.submenu = submenu
        menu.addItem(customize)
        if let endpoint = console.endpoint {
            menu.addItem(action("Copy Engine Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(endpoint, forType: .string)
            })
        }
        menu.addItem(.separator())
        menu.addItem(action("Quit \(console.info.name)", key: "q") { NSApp.terminate(nil) })
    }

    private func headerItem() -> NSMenuItem {
        let item = NSMenuItem()
        let status: String = switch console.status {
        case .starting(let message): message
        case .failed(let message): message
        case .serving: [console.endpoint, console.modeSummary].compactMap { $0 }.joined(separator: "\n")
        }
        let view = NSHostingView(rootView: MenuHeader(name: console.info.name, symbol: console.info.symbol, status: status))
        view.frame.size = view.fittingSize
        item.view = view
        return item
    }

    private func runningItem(_ job: JobActivity) -> NSMenuItem {
        let item = NSMenuItem()
        let view = NSHostingView(rootView: RunningJobMenuRow(console: console, jobID: job.id) { [weak self] in
            self?.statusItem.menu?.cancelTracking()
            self?.open(.queue)
        } cancel: { [weak self] in
            self?.statusItem.menu?.cancelTracking()
            self?.console.cancel(job: job.id)
        })
        view.frame.size = NSSize(width: 300, height: view.fittingSize.height)
        item.view = view
        return item
    }

    private func jobLine(_ job: JobActivity, prefix: String) -> String {
        "\(prefix)\(console.operationTitle(job.operation)) · \(job.model.title ?? job.model.id)"
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, key: String = "", _ perform: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, keyEquivalent: key, perform: perform)
        item.isEnabled = true
        return item
    }

    // MARK: - Images (Nativ's menu-bar renderer)

    /// The engine's symbol, with the number of active jobs beside it.
    static func engineImage(symbol: String, count: Int, failed: Bool) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let glyph = NSImage(systemSymbolName: failed ? "exclamationmark.triangle" : symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) ?? NSImage()
        let text = count > 0 ? NSAttributedString(string: "\(count)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.black,
        ]) : nil
        let width = glyph.size.width + (text.map { $0.size().width + 3 } ?? 0)
        let image = NSImage(size: NSSize(width: max(width, 18), height: 20), flipped: false) { rect in
            glyph.draw(in: NSRect(x: rect.minX, y: rect.midY - glyph.size.height / 2, width: glyph.size.width,
                                  height: glyph.size.height))
            if let text {
                let size = text.size()
                text.draw(at: NSPoint(x: rect.minX + glyph.size.width + 3, y: rect.midY - size.height / 2))
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    static func percentageImage(label: String, percent: Int) -> NSImage {
        twoLineImage(width: 34, label: label, value: "\(percent)%", valueSize: 10)
    }

    static func gigabytesImage(value: String) -> NSImage {
        twoLineImage(width: 48, label: "MEM", value: value, valueSize: 9)
    }

    private static func twoLineImage(width: CGFloat, label: String, value: String, valueSize: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: 20), flipped: false) { rect in
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let labelText = NSAttributedString(string: label, attributes: [
                .font: NSFont.systemFont(ofSize: 7, weight: .semibold), .foregroundColor: NSColor.black, .paragraphStyle: paragraph,
            ])
            let valueText = NSAttributedString(string: value, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: valueSize, weight: .semibold), .foregroundColor: NSColor.black,
                .paragraphStyle: paragraph,
            ])
            let spacing: CGFloat = -2
            let labelHeight = labelText.size().height
            let valueHeight = valueText.size().height
            let originY = floor((rect.height - (labelHeight + spacing + valueHeight)) / 2)
            valueText.draw(in: NSRect(x: rect.minX, y: originY, width: rect.width, height: valueHeight))
            labelText.draw(in: NSRect(x: rect.minX, y: originY + valueHeight + spacing, width: rect.width, height: labelHeight))
            return true
        }
        image.isTemplate = true
        return image
    }

    static func graphImage(values: [Double]) -> NSImage {
        let image = NSImage(size: NSSize(width: 42, height: 18), flipped: false) { rect in
            NSColor.labelColor.setStroke()
            let frame = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 3.5, yRadius: 3.5)
            frame.lineWidth = 1
            frame.stroke()
            guard values.count > 1 else { return true }
            let plot = rect.insetBy(dx: 3, dy: 3)
            let path = NSBezierPath()
            for (index, raw) in values.enumerated() {
                let point = NSPoint(x: plot.minX + plot.width * CGFloat(index) / CGFloat(max(values.count - 1, 1)),
                                    y: plot.minY + plot.height * CGFloat(min(max(raw, 0), 1)))
                if index == 0 { path.move(to: point) } else { path.line(to: point) }
            }
            if let fill = path.copy() as? NSBezierPath {
                fill.line(to: NSPoint(x: plot.maxX, y: plot.minY))
                fill.line(to: NSPoint(x: plot.minX, y: plot.minY))
                fill.close()
                NSColor.labelColor.withAlphaComponent(0.22).setFill()
                fill.fill()
            }
            path.lineWidth = 1.25
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    static func composite(_ images: [NSImage], accessibilityDescription: String) -> NSImage {
        let spacing: CGFloat = 4
        let height = images.map(\.size.height).max() ?? 20
        let width = images.reduce(0) { $0 + $1.size.width } + spacing * CGFloat(max(images.count - 1, 0))
        let image = NSImage(size: NSSize(width: max(width, 1), height: height), flipped: false) { rect in
            var x = rect.minX
            for part in images {
                part.draw(in: NSRect(x: x, y: rect.midY - part.size.height / 2, width: part.size.width, height: part.size.height))
                x += part.size.width + spacing
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
    }
}

/// A menu item that runs a closure.
private final class ClosureMenuItem: NSMenuItem {
    private let perform: () -> Void

    init(title: String, keyEquivalent: String, perform: @escaping () -> Void) {
        self.perform = perform
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { perform() }
}

// MARK: - Menu rows

private struct MenuHeader: View {
    let name: String
    let symbol: String
    let status: String

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.s) {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium)).foregroundStyle(Tokens.Color.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(Tokens.Font.headline)
                Text(status).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(width: 300, alignment: .leading)
    }
}

/// The running job in the menu: what it is, its progress, and a cancel button. Live while the menu is open.
private struct RunningJobMenuRow: View {
    let console: EngineConsoleModel
    let jobID: String
    let show: () -> Void
    let cancel: () -> Void
    @State private var hovered = false

    var body: some View {
        let job = console.activity.jobs.first { $0.id == jobID }
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: OperationSymbol.symbol(job?.operation))
                    Text(job.map { console.operationTitle($0.operation) } ?? "Finished").font(Tokens.Font.headline)
                    Text(job.map { $0.model.title ?? $0.model.id } ?? "").foregroundStyle(Tokens.Color.secondaryLabel).lineLimit(1)
                    Spacer()
                    if job?.outcome == nil {
                        Button(action: cancel) { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(Tokens.Color.tertiaryLabel)
                            .help("Cancel this job")
                    }
                }
                .font(Tokens.Font.body)
                if let fraction = job?.progress?.fraction {
                    ProgressView(value: min(max(fraction, 0), 1)).controlSize(.small)
                } else if job?.outcome == nil {
                    ProgressView().progressViewStyle(.linear).controlSize(.small)
                }
                HStack {
                    Text(job?.progress?.message ?? job?.summary ?? "").lineLimit(1)
                    Spacer()
                    if let ran = job?.ran(now: context.date) { Text(ConsoleFormat.duration(ran)).monospacedDigit() }
                }
                .font(Tokens.Font.caption)
                .foregroundStyle(Tokens.Color.secondaryLabel)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(hovered ? Tokens.Color.fillElevated : Color.clear, in: RoundedRectangle(cornerRadius: 5).inset(by: 1))
        .contentShape(.rect)
        .onHover { hovered = $0 }
        .onTapGesture(perform: show)
    }
}
