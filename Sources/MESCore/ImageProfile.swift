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
        public static let layerCount = "layer_count"
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

    /// One operation's normative requirements, from operations.json (shared by every profile's table).
    public typealias OperationSpec = ProfileOperationSpec
    public typealias Table = ProfileTable

    /// The bundled copy of schemas/v0/profiles/image/operations.json (a test keeps the two identical).
    public static let operations: Table = .bundled("image-operations")

    /// The bundled copy of schemas/v0/profiles/image/vocabulary.schema.json.
    public static let vocabulary: JSONValue = ProfileTable.bundledVocabulary("image-vocabulary")

    /// `supports` keys the profile defines (§2.1, Base §6.4).
    public enum SupportsKey {
        /// Boolean, absent `true`, Warn: `negative_prompt_ignored`.
        public static let negativePrompt = "negative_prompt"
        /// `decompose`: boolean, absent `true`, Gate: an `outputs` that contains `composite`.
        public static let composite = "composite"
    }

    /// Offer limit fields the profile defines (§2.1).
    public enum LimitField {
        /// `decompose`: the most layers the model returns.
        public static let maxLayerCount = "max_layer_count"
    }

    /// The vocabulary definition for a parameter name (honouring the table's `vocabulary_defs`), with every
    /// `$ref` inlined so it can sit inside a descriptor's self-contained `params` schema.
    public static func vocabularySchema(_ name: String, operation: String) -> JSONValue? {
        operations.vocabularySchema(name, operation: operation, vocabulary: vocabulary)
    }
}
