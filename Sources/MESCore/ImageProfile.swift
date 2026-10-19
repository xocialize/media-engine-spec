import Foundation

/// The Image profile 0.1 (spec/profiles/image.md): the operations table and the vocabulary names.
public enum ImageProfile {
    public static let id = "image"
    public static let version = "0.1"

    /// The vocabulary names (§2). Descriptor params for these concepts MUST use these names.
    public enum Param {
        public static let prompt = "prompt", negativePrompt = "negative_prompt", seed = "seed", quality = "quality"
        public static let size = "size", aspect = "aspect", megapixels = "megapixels", strength = "strength"
        public static let count = "count", scale = "scale", content = "content", output = "output", canvas = "canvas"
        public static let kind = "kind", outputs = "outputs", language = "language", preset = "preset"
        public static let promptEnhance = "prompt_enhance", targetOperation = "target_operation", targetModel = "target_model"
    }

    /// `prompt_enhance` (§1.9, §2): whether the engine may rewrite a prompt or instruction before the model sees it.
    public enum PromptEnhanceMode: String, Codable, Sendable, CaseIterable { case auto, on, off }

    /// Warning codes the profile adds (§4).
    public enum WarningCode {
        public static let sizeSnapped = "size_snapped", maskResampled = "mask_resampled"
        public static let colorConverted = "color_converted", alphaReapplied = "alpha_reapplied"
        public static let negativePromptIgnored = "negative_prompt_ignored", countReduced = "count_reduced"
        public static let promptRewritten = "prompt_rewritten", promptEnhanceIgnored = "prompt_enhance_ignored"
        public static let promptEnhanceFailed = "prompt_enhance_failed"
    }

    /// Helper roles the profile registers (§4, Base §10.1).
    public enum HelperRole {
        /// A model that rewrote the prompt or instruction (§1.9).
        public static let promptEnhance = "prompt_enhance"
    }

    /// One operation's normative requirements, from operations.json.
    public struct OperationSpec: Codable, Sendable, Equatable {
        public struct IO: Codable, Sendable, Equatable {
            public var kind: Kind
            public var required: Bool?
            public var valueSchema: String?
            enum CodingKeys: String, CodingKey { case kind, required; case valueSchema = "value_schema" }
        }
        public var inputs: [String: IO]
        public var outputs: [String: IO]
        public var vocabulary: [String]
        public var vocabularyDefs: [String: String]?
        public var keepsInputSize: Bool?
        public var preservesUnmasked: Bool?
        public var exactScale: Bool?
        public var requiresOneOf: [String]?
        /// The image input an `ic` adapter's slots fill (§1.10).
        public var adapterInput: String?
        enum CodingKeys: String, CodingKey {
            case inputs, outputs, vocabulary
            case vocabularyDefs = "vocabulary_defs", keepsInputSize = "keeps_input_size"
            case preservesUnmasked = "preserves_unmasked", exactScale = "exact_scale", requiresOneOf = "requires_one_of"
            case adapterInput = "adapter_input"
        }
    }

    public struct Table: Codable, Sendable, Equatable {
        public var profile: String
        public var version: String
        public var operations: [String: OperationSpec]
    }

    /// The bundled copy of schemas/v0/profiles/image/operations.json (a test keeps the two identical).
    public static let operations: Table = {
        guard let url = Bundle.module.url(forResource: "image-operations", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let table = try? MESJSON.decoder.decode(Table.self, from: data) else {
            fatalError("MESCore: bundled image-operations.json is missing or invalid")
        }
        return table
    }()

    /// The bundled copy of schemas/v0/profiles/image/vocabulary.schema.json.
    public static let vocabulary: JSONValue = {
        guard let url = Bundle.module.url(forResource: "image-vocabulary", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let value = try? MESJSON.decoder.decode(JSONValue.self, from: data) else {
            fatalError("MESCore: bundled image-vocabulary.json is missing or invalid")
        }
        return value
    }()

    /// The vocabulary definition for a parameter name (honouring the table's `vocabulary_defs`), with every
    /// `$ref` inlined so it can sit inside a descriptor's self-contained `params` schema.
    public static func vocabularySchema(_ name: String, operation: String) -> JSONValue? {
        let defName = operations.operations[operation]?.vocabularyDefs?[name] ?? name
        guard let def = vocabulary["$defs"]?[defName] else { return nil }
        return inline(def)
    }

    static func inline(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let o):
            if case .string(let ref)? = o["$ref"], ref.hasPrefix("#/$defs/"),
               let target = vocabulary["$defs"]?[String(ref.dropFirst("#/$defs/".count))] {
                return inline(target)
            }
            return .object(o.mapValues(inline))
        case .array(let a): return .array(a.map(inline))
        default: return value
        }
    }
}

