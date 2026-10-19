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
/// opt-in model that's on is still offered `named_only` (Base §6 rule 2). The choices persist as JSON.
///
///     let enablement = ModelEnablement(file: state.appendingPathComponent("models.json"))
///     enablement.isEnabled("z-image-turbo", optIn: false)   // true until switched off
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
    public let file: URL?
    private let state: Mutex<Choices>

    public init(file: URL?) {
        self.file = file
        let loaded = file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? Self.decoder.decode(Choices.self, from: $0) }
        state = Mutex(loaded ?? Choices())
    }

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
        guard let file else { return }
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
