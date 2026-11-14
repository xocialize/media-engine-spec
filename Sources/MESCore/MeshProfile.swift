import Foundation

/// The Mesh profile 0.1 (spec/profiles/mesh.md, RFCs 0007 and 0009): the operations table, the vocabulary names, the
/// `supports` keys and limit fields, the skeleton templates, the parts, and the conventions' constants.
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
        /// `mesh.generate_part` (§3.3, RFC 0009).
        public static let part = "part", subjectBox = "subject_box", physics = "physics"
    }

    /// The operations' input and output names (§3).
    public enum Input {
        public static let image = "image", mesh = "mesh"
        /// The rigged GLB or `.vrm` a part goes on (§3.3).
        public static let body = "body"
    }
    public enum Output {
        public static let mesh = "mesh", preview = "preview"
    }

    /// `texture` (§1.5): an atlas, colour per vertex, or neither (`none`, RFC 0009).
    public static let textures = ["atlas", "vertex_colors", "none"]
    /// `texture: none`: no texture and no `COLOR_0`, a plain material.
    public static let noTexture = "none"
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
        /// `mesh.generate_part` (§4.1, RFC 0009): the parts an offer makes (required, the first the default), what it does
        /// with a `subject_box` (`SubjectBoxSupport`), and whether it makes spring bones.
        public static let parts = "parts", subjectBox = "subject_box", physics = "physics"
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

    /// The registered parts (§3.3, RFC 0009). `garment` and `accessory` are reserved for the first models that make them.
    public enum Part {
        /// The character's hair, hung from the body's head bone.
        public static let hair = "hair"
    }
    /// The registered parts, from the vocabulary.
    public static var parts: [String] { vocabulary["$defs"]?["part_kind"]?["enum"]?.arrayValue?.compactMap(\.stringValue) ?? [Part.hair] }

    /// The VRM humanoid bone a registered part hangs from (§3.3): `head` for `hair`. Nil for a part the profile doesn't
    /// register.
    public static func humanoidBone(part: String) -> String? { part == Part.hair ? "head" : nil }

    /// `supports.subject_box` (§3.3): what an offer does with a box.
    public enum SubjectBoxSupport: String, Sendable {
        /// The model doesn't locate the part: a request must carry a box.
        case required
        /// The model locates the part itself, and a box overrides that.
        case optional
    }

    /// The glTF extension a part's physics travels in (§3.3): in `extensionsUsed`, never `extensionsRequired`.
    public static let springBoneExtension = "VRMC_springBone"

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

/// `subject_box` (Mesh §2, §3.3, RFC 0009): where in the picture a part is read from, in shares of the upright image from
/// its top-left corner.
public struct SubjectBox: Sendable, Equatable {
    public var x: Double, y: Double, width: Double, height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    /// From a request's value. Nil when it isn't `{x, y, width, height}`, four finite numbers and nothing else.
    public init?(_ value: JSONValue?) {
        guard let box = value?.objectValue, Set(box.keys) == ["x", "y", "width", "height"],
              let x = box["x"]?.numberValue, let y = box["y"]?.numberValue,
              let width = box["width"]?.numberValue, let height = box["height"]?.numberValue,
              [x, y, width, height].allSatisfy(\.isFinite) else { return nil }
        self.init(x: x, y: y, width: width, height: height)
    }

    /// What is wrong with a request's `subject_box`, or nil: it must be four numbers, have some area and lie inside the
    /// image (400 `invalid_request`).
    public static func problem(_ value: JSONValue?) -> String? {
        guard let box = SubjectBox(value) else {
            return "subject_box is {x, y, width, height}, each a number from 0 to 1 of the image."
        }
        return box.problem
    }

    /// Why the box isn't one, or nil. A hair's breadth past the edge (rounding) is let through.
    public var problem: String? {
        let slack = 1e-9
        guard x >= 0, y >= 0, width > 0, height > 0, x + width <= 1 + slack, y + height <= 1 + slack else {
            return "subject_box must have some area and lie inside the image (0 to 1 from its top-left corner)."
        }
        return nil
    }

    public var json: JSONValue { ["x": .number(x), "y": .number(y), "width": .number(width), "height": .number(height)] }

    /// The box in pixels of an upright image `width` × `height`, as `(x0, y0, x1, y1)`: left and top rounded down, right
    /// and bottom up, kept inside the image and at least a pixel each way.
    public func pixels(width w: Int, height h: Int) -> (x0: Int, y0: Int, x1: Int, y1: Int) {
        let x0 = max(0, min(w - 1, Int((x * Double(w)).rounded(.down)))), y0 = max(0, min(h - 1, Int((y * Double(h)).rounded(.down))))
        let x1 = max(x0 + 1, min(w, Int(((x + width) * Double(w)).rounded(.up))))
        let y1 = max(y0 + 1, min(h, Int(((y + height) * Double(h)).rounded(.up))))
        return (x0, y0, x1, y1)
    }
}

extension GLB {
    /// The node a VRM maps to a humanoid bone (`head`, `hips`, …): VRM 1.0's `VRMC_vrm`, else VRM 0.x's `VRM`. Nil when
    /// the file is no VRM or has no such bone.
    public func humanoidBone(_ bone: String) -> Int? {
        let extensions = json["extensions"]
        if let node = extensions?["VRMC_vrm"]?["humanoid"]?["humanBones"]?[bone]?["node"]?.intValue { return node }
        return extensions?["VRM"]?["humanoid"]?["humanBones"]?.arrayValue?
            .first { $0["bone"]?.stringValue == bone }?["node"]?.intValue
    }

    /// The bone of a body a part hangs from (Mesh §3.3): the VRM humanoid bone where the body is a VRM, else a node
    /// whose name ends in the bone's name, whatever its case (`J_Bip_C_Head`, `mixamorig:Head`). Returns the node, its
    /// name, and its global transform at rest (column-major 4×4). Nil when the body has none.
    public func bodyBone(for part: String) -> (node: Int, name: String, world: [Double])? {
        guard let bone = MeshProfile.humanoidBone(part: part) else { return nil }
        let nodes = array("nodes")
        let found = humanoidBone(bone) ?? nodes.firstIndex { ($0["name"]?.stringValue ?? "").lowercased().hasSuffix(bone) }
        guard let node = found, nodes.indices.contains(node) else { return nil }
        return (node, nodes[node]["name"]?.stringValue ?? bone, worldMatrix(node: node))
    }

    /// A node's global transform (column-major 4×4): its own and every ancestor's, whether or not a scene lists it.
    public func worldMatrix(node: Int) -> [Double] {
        let nodes = array("nodes")
        var parent: [Int: Int] = [:]
        for (i, n) in nodes.enumerated() { for c in n["children"]?.arrayValue?.compactMap(\.intValue) ?? [] { parent[c] = i } }
        guard nodes.indices.contains(node) else { return Matrix.identity }
        var world = Matrix.local(nodes[node].objectValue ?? [:]), at = node, hops = 0
        while let up = parent[at], hops < nodes.count {
            world = Matrix.multiply(Matrix.local(nodes[up].objectValue ?? [:]), world)
            at = up
            hops += 1
        }
        return world
    }
}

extension JobResult {
    /// The mesh outputs (RFC 0007), in index order.
    public var meshes: [Output] { outputs.filter(\.isMesh) }

    /// The still that comes with a mesh output (Mesh §1.7): the `preview` image output, for clients without a 3D viewer.
    public func preview(for mesh: Output? = nil) -> Output? {
        outputs.first { $0.name == MeshProfile.Output.preview && $0.kind == .image }
    }
}
