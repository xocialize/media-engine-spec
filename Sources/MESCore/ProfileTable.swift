import Foundation

/// One operation's normative requirements, from a profile's operations.json (Image, Audio).
public struct ProfileOperationSpec: Codable, Sendable, Equatable {
    public struct IO: Codable, Sendable, Equatable {
        public var kind: Kind
        public var required: Bool?
        public var valueSchema: String?
        /// Audio: the output may stream (Base §6).
        public var streamable: Bool?
        enum CodingKeys: String, CodingKey { case kind, required, streamable; case valueSchema = "value_schema" }
    }
    public var inputs: [String: IO]
    public var outputs: [String: IO]
    public var vocabulary: [String]
    public var vocabularyDefs: [String: String]?
    public var keepsInputSize: Bool?
    public var preservesUnmasked: Bool?
    public var exactScale: Bool?
    public var requiresOneOf: [String]?
    /// The image input an `ic` adapter's slots fill (Image §1.10).
    public var adapterInput: String?
    /// Vocabulary parameters a request must carry (Audio: `edit_speech`'s `edit`).
    public var requiredParams: [String]?
    /// Audio: each audio output is `duration_s` long, to the frame.
    public var exactDuration: Bool?
    /// Results report the seed each used.
    public var seeded: Bool?
    enum CodingKeys: String, CodingKey {
        case inputs, outputs, vocabulary, seeded
        case vocabularyDefs = "vocabulary_defs", keepsInputSize = "keeps_input_size"
        case preservesUnmasked = "preserves_unmasked", exactScale = "exact_scale", requiresOneOf = "requires_one_of"
        case adapterInput = "adapter_input", requiredParams = "required_params", exactDuration = "exact_duration"
    }
}

/// A profile's operations table (schemas/v0/profiles/<profile>/operations.json).
public struct ProfileTable: Codable, Sendable, Equatable {
    public var profile: String
    public var version: String
    public var operations: [String: ProfileOperationSpec]

    /// Loads a table bundled with MESCore.
    static func bundled(_ resource: String) -> ProfileTable {
        guard let url = Bundle.module.url(forResource: resource, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let table = try? MESJSON.decoder.decode(ProfileTable.self, from: data) else {
            fatalError("MESCore: bundled \(resource).json is missing or invalid")
        }
        return table
    }

    static func bundledVocabulary(_ resource: String) -> JSONValue {
        guard let url = Bundle.module.url(forResource: resource, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let value = try? MESJSON.decoder.decode(JSONValue.self, from: data) else {
            fatalError("MESCore: bundled \(resource).json is missing or invalid")
        }
        return value
    }

    /// The vocabulary definition for a parameter name (honouring `vocabulary_defs`), with every `$ref` inlined so it
    /// can sit inside a descriptor's self-contained `params` schema.
    public func vocabularySchema(_ name: String, operation: String, vocabulary: JSONValue) -> JSONValue? {
        let defName = operations[operation]?.vocabularyDefs?[name] ?? name
        guard let def = vocabulary["$defs"]?[defName] else { return nil }
        return Self.inline(def, vocabulary)
    }

    static func inline(_ value: JSONValue, _ vocabulary: JSONValue) -> JSONValue {
        switch value {
        case .object(let o):
            if case .string(let ref)? = o["$ref"], ref.hasPrefix("#/$defs/") {
                var target: JSONValue? = vocabulary["$defs"]
                for part in ref.dropFirst("#/$defs/".count).split(separator: "/") { target = target?[String(part)] }
                if let target { return inline(target, vocabulary) }
            }
            return .object(o.mapValues { inline($0, vocabulary) })
        case .array(let a): return .array(a.map { inline($0, vocabulary) })
        default: return value
        }
    }
}
