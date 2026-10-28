import Foundation
import MESCore
import MESEngineCore

/// What an engine app gives its console. The kit side (`activity`, `cancel`, `operations`) is `MESEngineServer`'s operator
/// API; the model side is the engine's own, since only the engine knows its catalog, its downloads and its memory.
///
/// An engine conforms in a few lines over its server and its runtime; `MESEngineUI` does the rest.
public protocol EngineConsoleBackend: Sendable {
    /// Every job from every client: a snapshot now, then one after every change (`MESEngineServer.activity()`).
    func activity() -> AsyncStream<EngineActivity>

    /// Cancels any client's job (`MESEngineServer.cancel(job:)`).
    func cancel(job id: String) async throws

    /// The operations as clients see them now (`MESEngineServer.operations()`), for the autoswitch table.
    func operations() async -> [Descriptor]

    /// Every model the engine can use, on or off, with what each does when it's on.
    func models() async -> [EngineModel]

    /// Switches a model on or off and saves the choice, then has the server reload its descriptors. Switching an opt-in
    /// model on records that the operator accepted its terms (`ModelEnablement`).
    func setEnabled(_ enabled: Bool, model id: String) async throws

    /// Downloads a model's weights now, instead of on the first job that needs them, without loading the model: it stays
    /// out of memory until a job needs it (Gaea's GPP `materialize`). `progress` is 0–1.
    func download(model id: String, progress: @escaping @Sendable (Double) -> Void) async throws

    /// Releases a model from memory, if no job is using it.
    func unload(model id: String) async
}

extension EngineConsoleBackend {
    public func download(model id: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        throw MESError(.engineError, "This engine downloads models when a job first needs them.")
    }
    public func unload(model id: String) async {}
}

/// One model as the console shows it: a card in the Models section.
public struct EngineModel: Sendable, Identifiable, Equatable {
    /// Where its weights are.
    public enum Install: Sendable, Equatable {
        /// Not on this Mac: downloaded when a job first needs it, or now from its card. `bytes` when known.
        case notDownloaded(bytes: UInt64?)
        case downloading(fraction: Double?)
        case downloaded(bytes: UInt64?)
        /// Nothing to download (shaders, classical algorithms).
        case builtIn
    }

    /// What the model does when it's on: one operation it serves.
    public struct Role: Sendable, Equatable, Identifiable {
        public var operation: String
        /// The tiers it serves for that operation.
        public var qualityTiers: [QualityTier]
        /// The operation's default when a request names no model (Base §6 rule 2), at the tiers above.
        public var isDefault: Bool
        /// Runs only when a request names it (research and other opt-in models).
        public var namedOnly: Bool
        public var id: String { operation }

        public init(operation: String, qualityTiers: [QualityTier], isDefault: Bool = false, namedOnly: Bool = false) {
            self.operation = operation; self.qualityTiers = qualityTiers; self.isDefault = isDefault; self.namedOnly = namedOnly
        }
    }

    public var id: String
    public var title: String
    /// A sentence or two on what the model is good at.
    public var summary: String
    public var license: License
    /// Off until the operator turns it on and accepts its terms (research and other restricted licences).
    public var optIn: Bool
    public var enabled: Bool
    /// When the operator accepted an opt-in model's terms.
    public var acceptedAt: Date?
    public var roles: [Role]
    /// How to use it well (the offer's `notes`).
    public var notes: String?
    public var memoryClass: ModelOffer.MemoryClass?
    public var speedClass: ModelOffer.SpeedClass?
    /// Memory while loaded.
    public var footprintBytes: UInt64?
    public var install: Install
    public var resident: Bool
    /// Why it can't run on this Mac, if it can't (registration problems, memory).
    public var unavailable: String?
    /// Where the weights come from, e.g. a Hugging Face repo id.
    public var source: String?
    /// A link for `source`.
    public var sourceURL: URL?
    /// Short facts worth a pill: "16-bit", "Work in progress".
    public var tags: [String]
    /// The plugin it comes in, for engines whose models are plugins (Gaea). Nil when the engine has it built in.
    public var plugin: Plugin?
    /// The version installed: its plugin's release, or the weights' revision.
    public var version: String?
    /// A newer version the engine knows of. For a plugin's model, updating the plugin installs it (the Plugins page).
    public var update: EngineUpdate?

    /// The plugin a model comes in.
    public struct Plugin: Sendable, Equatable, Hashable {
        /// The plugin's id (`EnginePlugin.id`).
        public var id: String
        public var title: String
        public init(id: String, title: String) { self.id = id; self.title = title }
    }

    public init(id: String, title: String, summary: String = "", license: License, optIn: Bool = false, enabled: Bool = true,
                acceptedAt: Date? = nil, roles: [Role] = [], notes: String? = nil, memoryClass: ModelOffer.MemoryClass? = nil,
                speedClass: ModelOffer.SpeedClass? = nil, footprintBytes: UInt64? = nil, install: Install = .notDownloaded(bytes: nil),
                resident: Bool = false, unavailable: String? = nil, source: String? = nil, sourceURL: URL? = nil,
                tags: [String] = [], plugin: Plugin? = nil, version: String? = nil, update: EngineUpdate? = nil) {
        self.id = id; self.title = title; self.summary = summary; self.license = license; self.optIn = optIn
        self.enabled = enabled; self.acceptedAt = acceptedAt; self.roles = roles; self.notes = notes
        self.memoryClass = memoryClass; self.speedClass = speedClass; self.footprintBytes = footprintBytes
        self.install = install; self.resident = resident; self.unavailable = unavailable; self.source = source
        self.sourceURL = sourceURL; self.tags = tags; self.plugin = plugin; self.version = version; self.update = update
    }

    /// Never chosen automatically, even when on.
    public var isNamedOnly: Bool { !roles.isEmpty && roles.allSatisfy(\.namedOnly) }

    public var isDownloaded: Bool {
        switch install {
        case .downloaded, .builtIn: true
        default: false
        }
    }
}

/// A newer version of a model or plugin than the one installed.
public struct EngineUpdate: Sendable, Equatable, Hashable {
    public var version: String
    /// What changed, e.g. a release's notes.
    public var notes: String?
    public var publishedAt: Date?
    /// Where to read about it, e.g. the GitHub Release.
    public var url: URL?

    public init(version: String, notes: String? = nil, publishedAt: Date? = nil, url: URL? = nil) {
        self.version = version; self.notes = notes; self.publishedAt = publishedAt; self.url = url
    }
}
