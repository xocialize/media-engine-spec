import Foundation
import MESCore
import MESEngineCore
import Observation

/// The console's sections.
public enum ConsoleSection: String, CaseIterable, Identifiable, Sendable {
    case queue, models, plugins, system

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .queue: "Queue"
        case .models: "Models"
        case .plugins: "Plugins"
        case .system: "System"
        }
    }

    public var symbol: String {
        switch self {
        case .queue: "list.bullet.rectangle"
        case .models: "shippingbox"
        case .plugins: "puzzlepiece.extension"
        case .system: "gauge.with.dots.needle.50percent"
        }
    }
}

/// Who the engine is, for the console's chrome.
public struct EngineConsoleInfo: Sendable {
    /// "Pixel Agency Image Engine".
    public var name: String
    /// The MES profile it serves, e.g. "Image".
    public var profile: String
    /// An SF Symbol for the engine (the menu-bar icon and the sidebar).
    public var symbol: String
    public var version: String

    public init(name: String, profile: String, symbol: String, version: String) {
        self.name = name; self.profile = profile; self.symbol = symbol; self.version = version
    }
}

/// The model the default choice picks for one operation at one tier, given the models that are on.
public struct AutoswitchRoute: Sendable, Equatable, Identifiable {
    public var operation: String
    public var title: String
    /// Per tier, the model a request that names none gets (nil: nothing serves the tier).
    public var picks: [(tier: QualityTier, model: ModelOffer?)]
    public var id: String { operation }

    public static func == (a: Self, b: Self) -> Bool {
        a.operation == b.operation && a.title == b.title
            && a.picks.map { "\($0.tier.rawValue)=\($0.model?.id ?? "")" } == b.picks.map { "\($0.tier.rawValue)=\($0.model?.id ?? "")" }
    }
}

/// The console's state, shared by the window and the menu-bar item.
@MainActor @Observable
public final class EngineConsoleModel {
    public enum Status: Equatable, Sendable {
        case starting(String)
        case serving
        case failed(String)
    }

    public let info: EngineConsoleInfo
    public var status: Status = .starting("Starting…")
    /// Where clients reach the engine, e.g. `http://127.0.0.1:17610/mes/v0`.
    public var endpoint: String?
    /// "Open mode · this Mac only", "Paired mode · any Mac on the network".
    public var modeSummary: String?
    public var section: ConsoleSection = .queue

    public private(set) var activity = EngineActivity()
    public private(set) var models: [EngineModel] = []
    public private(set) var operations: [Descriptor] = []
    /// Downloads started from the console, by model id: fraction done, nil while unknown.
    private(set) var downloads: [String: Double?] = [:]
    /// The last failure of a console action, shown until dismissed.
    var actionError: String?
    /// The model whose card is open on the Models page.
    public var selectedModelID: String?

    /// Installed plugins, when the engine has a Plugins page (`attach(_:plugins:)`).
    public internal(set) var plugins: [EnginePlugin] = []
    public internal(set) var trustedTeams: [EngineTrustedTeam] = []
    /// Whether the console shows the Plugins page.
    public private(set) var hasPlugins = false
    /// Adds, updates and rollbacks in flight, by plugin id (or repo URL for an add): fraction done, nil while unknown.
    var pluginWork: [String: Double?] = [:]
    /// A plugin signed by a team that isn't trusted yet, waiting for the operator.
    var trustPrompt: PluginTrustRequest?
    /// The plugin highlighted on the Plugins page.
    public var selectedPluginID: String?

    @ObservationIgnored private var backend: (any EngineConsoleBackend)?
    @ObservationIgnored var pluginBackend: (any EnginePluginBackend)?
    @ObservationIgnored private var activityTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    public init(info: EngineConsoleInfo) {
        self.info = info
    }

    /// The sections this engine has: Plugins only when it was attached with a plugin backend.
    public var sections: [ConsoleSection] {
        ConsoleSection.allCases.filter { $0 != .plugins || hasPlugins }
    }

    /// Connects the console to the running engine: follows its activity and loads its models, and its plugins when it
    /// has a Plugins page.
    public func attach(_ backend: any EngineConsoleBackend, plugins: (any EnginePluginBackend)? = nil) {
        self.backend = backend
        pluginBackend = plugins
        hasPlugins = plugins != nil
        status = .serving
        activityTask?.cancel()
        activityTask = Task { [weak self] in
            var lastRunning: [String] = []
            for await snapshot in backend.activity() {
                guard let self else { return }
                self.activity = snapshot
                // A job starting or finishing loads or releases models: refresh their state.
                let running = snapshot.running.map(\.id)
                if running != lastRunning {
                    lastRunning = running
                    await self.refreshModels()
                }
            }
        }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshModels()
                await self?.refreshPlugins()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    public func refreshModels() async {
        guard let backend else { return }
        async let models = backend.models()
        async let operations = backend.operations()
        let (m, o) = await (models, operations)
        if self.models != m { self.models = m }
        if self.operations != o { self.operations = o }
    }

    // MARK: - Actions

    func setEnabled(_ enabled: Bool, model id: String) {
        guard let backend else { return }
        if let index = models.firstIndex(where: { $0.id == id }) { models[index].enabled = enabled }   // optimistic
        Task {
            do {
                try await backend.setEnabled(enabled, model: id)
            } catch {
                actionError = "Couldn't turn \(title(of: id)) \(enabled ? "on" : "off"): \(Self.describe(error))"
            }
            await refreshModels()
        }
    }

    func download(model id: String) {
        guard let backend, downloads[id] == nil else { return }
        downloads[id] = .some(nil)
        Task {
            do {
                try await backend.download(model: id) { fraction in
                    Task { @MainActor [weak self] in
                        if self?.downloads[id] != nil { self?.downloads[id] = .some(fraction) }
                    }
                }
            } catch {
                actionError = "Couldn't download \(title(of: id)): \(Self.describe(error))"
            }
            downloads[id] = nil
            await refreshModels()
        }
    }

    func unload(model id: String) {
        guard let backend else { return }
        Task {
            await backend.unload(model: id)
            await refreshModels()
        }
    }

    func cancel(job id: String) {
        guard let backend else { return }
        Task {
            do {
                try await backend.cancel(job: id)
            } catch {
                actionError = "Couldn't cancel the job: \(Self.describe(error))"
            }
        }
    }

    // MARK: - Derived

    var enabledCount: Int { models.filter(\.enabled).count }

    func title(of modelID: String) -> String { models.first { $0.id == modelID }?.title ?? modelID }

    func operationTitle(_ operation: String) -> String {
        operations.first { $0.operation == operation }?.title ?? Self.fallbackTitle(operation)
    }

    /// The model's install state, with any console download's progress folded in.
    func install(of model: EngineModel) -> EngineModel.Install {
        if let progress = downloads[model.id] { return .downloading(fraction: progress) }
        return model.install
    }

    /// For each operation, what a request that names no model gets at each tier (Base §6 rule 2): the `default` offer
    /// for the tier, else its first offer that isn't named-only. Engines may refine this per request (restore by kind).
    var autoswitch: [AutoswitchRoute] {
        operations.map { descriptor in
            let picks = QualityTier.allCases.filter { descriptor.qualityTiers.contains($0) }.map { tier in
                let candidates = descriptor.models.filter { $0.qualityTiers.contains(tier) && $0.namedOnly != true }
                return (tier: tier, model: candidates.first { $0.isDefault == true } ?? candidates.first)
            }
            return AutoswitchRoute(operation: descriptor.operation, title: descriptor.title, picks: picks)
        }
    }

    /// What turning `model` off would leave with no model: operations and tiers it alone serves by default.
    func orphans(ifDisabling model: EngineModel) -> [String] {
        operations.compactMap { descriptor -> String? in
            guard descriptor.models.contains(where: { $0.id == model.id && $0.namedOnly != true }) else { return nil }
            let others = descriptor.models.filter { $0.id != model.id && $0.namedOnly != true }
            let lost = descriptor.qualityTiers.filter { tier in
                descriptor.models.contains { $0.id == model.id && $0.qualityTiers.contains(tier) }
                    && !others.contains { $0.qualityTiers.contains(tier) }
            }
            guard !lost.isEmpty else { return nil }
            let tiers = lost.count == descriptor.qualityTiers.count ? "" : " at " + lost.map(\.rawValue).joined(separator: ", ")
            return descriptor.title + tiers
        }
    }

    /// Where a model is the autoswitch pick now.
    func picks(of modelID: String) -> [(operation: String, tiers: [QualityTier])] {
        autoswitch.compactMap { route in
            let tiers = route.picks.filter { $0.model?.id == modelID }.map(\.tier)
            return tiers.isEmpty ? nil : (route.title, tiers)
        }
    }

    static func fallbackTitle(_ operation: String) -> String {
        let name = operation.split(separator: ".").last.map(String.init) ?? operation
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    static func describe(_ error: any Error) -> String {
        (error as? MESError)?.message ?? (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}
