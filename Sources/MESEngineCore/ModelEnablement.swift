import Foundation
import Synchronization

/// Which models an engine may use: its operator's enabled set (Engines-PRD ENG-4, ENG-14).
///
/// An engine switches models itself, by operation and quality tier, so its operator doesn't pick a model to load. They
/// choose which models may be picked at all. A model that's off isn't offered: it's absent from the descriptors, so no
/// default chooses it and no request can name it, and the next enabled model for its tier takes its place.
///
/// Models are on by default, except opt-in ones (research and other restricted licences). Those are off until the
/// operator turns them on, which records that they accepted the model's terms (Base §10.2 `accepted_required`). An
/// opt-in model that's on is still offered `named_only` (Base §6 rule 2). The choices persist through a
/// `ModelEnablementStore`: a JSON file by default, or the engine's own database (Gaea keeps them in gaea.sqlite, which
/// no other process opens).
///
///     let enablement = ModelEnablement(file: state.appendingPathComponent("models.json"))
///     enablement.isEnabled("z-image-turbo", optIn: false)   // true until switched off
///
///     let enablement = try ModelEnablement(store: MyDatabaseEnablementStore(db))
public final class ModelEnablement: Sendable {
    public struct Choices: Codable, Sendable, Equatable {
        /// Models on by default that the operator switched off.
        public var disabled: Set<String> = []
        /// Opt-in models the operator switched on.
        public var enabled: Set<String> = []
        /// When the operator accepted each opt-in model's terms.
        public var accepted: [String: Date] = [:]
        public init() {}
    }

    /// Where the choices persist; nil keeps them in memory only.
    public let store: (any ModelEnablementStore)?
    private let state: Mutex<Choices>

    /// Choices kept in `store`, loaded now. Throws what the store's `load()` throws.
    public init(store: any ModelEnablementStore) throws {
        self.store = store
        state = Mutex(try store.load())
    }

    /// Choices kept as JSON in `file`, or in memory only when nil. A missing or unreadable file starts from the defaults.
    public init(file: URL?) {
        let store = file.map(JSONFileEnablementStore.init(file:))
        self.store = store
        state = Mutex((try? store?.load()) ?? Choices())
    }

    /// The JSON file the choices persist in, when the store is one.
    public var file: URL? { (store as? JSONFileEnablementStore)?.file }

    public var choices: Choices { state.withLock { $0 } }

    public func isEnabled(_ id: String, optIn: Bool) -> Bool {
        state.withLock { optIn ? $0.enabled.contains(id) : !$0.disabled.contains(id) }
    }

    /// When the operator accepted `id`'s terms, if it's an opt-in model they switched on.
    public func acceptedAt(_ id: String) -> Date? { state.withLock { $0.accepted[id] } }

    /// Switches a model on or off and saves. Switching an opt-in model on records that its terms were accepted now;
    /// switching it off withdraws that.
    public func set(_ id: String, enabled: Bool, optIn: Bool) throws {
        let snapshot = state.withLock { choices -> Choices in
            if optIn {
                if enabled {
                    choices.enabled.insert(id)
                    choices.accepted[id] = Date()
                } else {
                    choices.enabled.remove(id)
                    choices.accepted[id] = nil
                }
            } else if enabled {
                choices.disabled.remove(id)
            } else {
                choices.disabled.insert(id)
            }
            return choices
        }
        try save(snapshot)
    }

    private func save(_ choices: Choices) throws {
        try store?.save(choices)
    }
}

/// Where an engine's enabled set persists. `ModelEnablement` holds the choices in memory and calls `save` after every
/// change, so a store only reads and writes the whole set. Gaea implements one over its own database.
public protocol ModelEnablementStore: Sendable {
    /// The saved choices, or empty `Choices` when nothing is saved yet.
    func load() throws -> ModelEnablement.Choices
    /// Replaces the saved choices.
    func save(_ choices: ModelEnablement.Choices) throws
}

/// The default store: the choices as JSON in one file, written atomically.
public struct JSONFileEnablementStore: ModelEnablementStore {
    public let file: URL

    public init(file: URL) { self.file = file }

    public func load() throws -> ModelEnablement.Choices {
        guard FileManager.default.fileExists(atPath: file.path) else { return ModelEnablement.Choices() }
        return try Self.decoder.decode(ModelEnablement.Choices.self, from: Data(contentsOf: file))
    }

    public func save(_ choices: ModelEnablement.Choices) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(choices).write(to: file, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
