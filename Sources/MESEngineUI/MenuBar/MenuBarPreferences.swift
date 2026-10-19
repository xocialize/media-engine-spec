import Foundation
import Observation

// Which live metrics the engine's menu-bar item shows in place of its icon. Ported from Nativ (MIT, see
// THIRD-PARTY-NOTICES.md).

enum MenuBarMetric: String, CaseIterable, Identifiable {
    case cpu, gpu, ram

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .ram: "Memory"
        }
    }

    /// The label above the value in the menu bar.
    var menuBarLabel: String { self == .ram ? "MEM" : title }

    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .gpu: "display"
        case .ram: "memorychip"
        }
    }

    var styles: [MenuBarStyle] { self == .ram ? [.percentage, .graph, .gigabytes] : [.percentage, .graph] }
}

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case percentage, graph, gigabytes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .percentage: "Percentage"
        case .graph: "Mini graph"
        case .gigabytes: "GB"
        }
    }

    var symbol: String {
        switch self {
        case .percentage: "percent"
        case .graph: "chart.xyaxis.line"
        case .gigabytes: "memorychip"
        }
    }
}

struct MenuBarItem: Hashable, Identifiable {
    let metric: MenuBarMetric
    let style: MenuBarStyle

    var id: String { "\(metric.rawValue).\(style.rawValue)" }

    init(metric: MenuBarMetric, style: MenuBarStyle) {
        self.metric = metric
        self.style = style
    }

    init?(id: String) {
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let metric = MenuBarMetric(rawValue: String(parts[0])),
              let style = MenuBarStyle(rawValue: String(parts[1])), metric.styles.contains(style) else { return nil }
        self.metric = metric
        self.style = style
    }
}

/// The menu-bar item's content: the engine's icon (no metrics), or any mix of CPU, GPU and memory readings. Kept in the
/// app's defaults, so each engine app remembers its own.
@MainActor @Observable
public final class MenuBarPreferences {
    private(set) var items: Set<MenuBarItem> {
        didSet { defaults.set(items.map(\.id).sorted(), forKey: Self.key) }
    }

    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "MESEngineUI.menuBarItems"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        items = Set((defaults.stringArray(forKey: Self.key) ?? []).compactMap(MenuBarItem.init(id:)))
    }

    /// In display order.
    var orderedItems: [MenuBarItem] {
        MenuBarMetric.allCases.flatMap { metric in
            metric.styles.map { MenuBarItem(metric: metric, style: $0) }.filter(items.contains)
        }
    }

    var showsEngineIcon: Bool { items.isEmpty }

    func contains(_ metric: MenuBarMetric, _ style: MenuBarStyle) -> Bool {
        items.contains(MenuBarItem(metric: metric, style: style))
    }

    func toggle(_ metric: MenuBarMetric, _ style: MenuBarStyle) {
        let item = MenuBarItem(metric: metric, style: style)
        if items.contains(item) { items.remove(item) } else { items.insert(item) }
    }

    func useEngineIcon() { items = [] }
}
