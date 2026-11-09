import Foundation

/// The Mesh profile 0.1 (spec/profiles/mesh.md, RFC 0007): the operations table, the vocabulary names, the `supports` keys
/// and limit fields, the skeleton templates, and the conventions' constants.
public enum MeshProfile {
    public static let id = "mesh"
    public static let version = "0.1"
    /// The media type meshes travel as (§1.1).
    public static let mediaType = "model/gltf-binary"

    /// The vocabulary names (§2). Descriptor params for these concepts MUST use these names.
    public enum Param {
        public static let seed = "seed", quality = "quality", resolution = "resolution", maxFaces = "max_faces"
        public static let texture = "texture", textureSize = "texture_size", background = "background"
        public static let placement = "placement", size = "size_m", onFlat = "on_flat", skeleton = "skeleton"
    }

    /// The operations' input and output names (§3).
    public enum Input {
        public static let image = "image", mesh = "mesh"
    }
    public enum Output {
        public static let mesh = "mesh", preview = "preview"
    }

    /// `texture` (§1.5).
    public static let textures = ["atlas", "vertex_colors"]
    /// `texture_size` (§2).
    public static let textureSizes = [256, 512, 1024, 2048, 4096, 8192]
    /// `background` (§3.1), and what `effective.background` reports.
    public static let backgrounds = ["remove", "keep"]
    public static let alpha = "alpha"
    /// `placement` (§1.4).
    public static let placements = ["centered", "grounded"]
    /// `on_flat` (§1.8).
    public static let onFlatModes = ["warn", "fail"]
    /// The material maps an offer may write (`supports.maps`).
    public static let maps = ["base_color", "metallic_roughness", "normal", "emissive"]

    /// A result whose thinnest extent is under this fraction of its longest is flat (§1.8; AB-R-0059).
    public static let flatRatio = 0.08
    /// The preview's smallest side (§1.7).
    public static let minPreviewSize = 512

    /// Warning codes the profile adds (§5).
    public enum WarningCode {
        public static let flatResult = "flat_result", facesReduced = "faces_reduced", textureReduced = "texture_reduced"
        public static let backgroundKept = "background_kept", jointsDropped = "joints_dropped", skinReplaced = "skin_replaced"
        public static let animationsDropped = "animations_dropped"
    }

    /// Error reasons the profile registers (§5).
    public enum Reason {
        /// With `input_invalid`: a flat result refused by `on_flat: fail`.
        public static let degenerateResult = "degenerate_result"
    }

    /// Progress phases (§1.15).
    public enum Phase {
        public static let matting = "matting", structure = "structure", shape = "shape", texture = "texture"
        public static let decimate = "decimate", export = "export", render = "render", skeleton = "skeleton", skin = "skin"
    }

    /// `supports` keys the profile defines (§4.1). Base defines `stream`, `seed` and `voices`.
    public enum SupportsKey {
        public static let backgroundRemoval = "background_removal", resolutions = "resolutions", textures = "textures"
        public static let textureSizes = "texture_sizes", maps = "maps", skeletons = "skeletons"
        public static let autoSkeleton = "auto_skeleton", maxInfluences = "max_influences", deterministic = "deterministic"
    }

    /// Limit fields the profile defines (§4.2).
    public enum LimitField {
        public static let minFaces = "min_faces", maxFaces = "max_faces", maxTextureSize = "max_texture_size"
        public static let maxInputFaces = "max_input_faces", maxJoints = "max_joints"
    }

    /// The registered skeleton templates (§3.2).
    public enum Skeleton {
        public static let vrmHumanoid = "vrm_humanoid"
    }

    /// A template's joint names, root first (§3.2), from the vocabulary; nil for one the profile doesn't register.
    public static func joints(template: String) -> [String]? {
        guard template == Skeleton.vrmHumanoid else { return nil }
        return vocabulary["$defs"]?["vrm_humanoid_joints"]?["const"]?.arrayValue?.compactMap(\.stringValue)
    }

    /// The bundled copy of schemas/v0/profiles/mesh/operations.json (a test keeps the two identical).
    public static let operations: ProfileTable = .bundled("mesh-operations")

    /// The bundled copy of schemas/v0/profiles/mesh/vocabulary.schema.json.
    public static let vocabulary: JSONValue = ProfileTable.bundledVocabulary("mesh-vocabulary")

    /// The vocabulary definition for a parameter name, with every `$ref` inlined (as `ImageProfile.vocabularySchema`).
    public static func vocabularySchema(_ name: String, operation: String) -> JSONValue? {
        operations.vocabularySchema(name, operation: operation, vocabulary: vocabulary)
    }

    /// How to place a result (§1.4): the uniform scale and then the offset that put `bounds` centred on the origin (or
    /// standing on Y = 0 when `grounded`) with its longest extent `size` metres. Apply as `p * scale + offset`.
    public static func placement(_ bounds: MeshBounds, grounded: Bool, size: Double) -> (scale: Double, offset: [Double]) {
        let longest = bounds.extents.max() ?? 0
        let scale = longest > 0 ? size / longest : 1
        let c = bounds.center
        var offset = c.map { -$0 * scale }
        if grounded { offset[1] = -bounds.min[1] * scale }
        return (scale, offset)
    }

    /// The text a generated mesh's preview carries in its PNG `Comment` (§1.11).
    public static func disclosure(model: String) -> String { "AI-generated with \(model)." }
}

extension JobResult {
    /// The mesh outputs (RFC 0007), in index order.
    public var meshes: [Output] { outputs.filter(\.isMesh) }

    /// The still that comes with a mesh output (Mesh §1.7): the `preview` image output, for clients without a 3D viewer.
    public func preview(for mesh: Output? = nil) -> Output? {
        outputs.first { $0.name == MeshProfile.Output.preview && $0.kind == .image }
    }
}
