import CoreGraphics
import Foundation
import ImageIO
import MESCore
import MESEngineCore
import UniformTypeIdentifiers

/// A mock Mesh-profile engine: `mesh.generate`, `mesh.rig` and `mesh.generate_part` (spec/profiles/mesh.md), with small
/// synthetic meshes that obey the profile's rules, and offers shaped like the fleet's (TRELLIS.2, SkinTokens, HairDeck), so
/// clients and the conformance suite can exercise the GLB conventions, facts, previews, placement, gates, flat results
/// and attribution. It runs no model: a "generated" mesh is an icosphere coloured from the image (vertex colours, or the
/// image as an atlas), a rig binds every vertex to the nearest joints of a skeleton laid out in the mesh's box, and a
/// part is a hair card on the body's head bone (MockMeshPart.swift).
///
/// - **generate:** `mock-trellis` (the default; every tier at 512/1024/1536, background removal, atlas or vertex colours,
///   textures to 2048, 100 – 20,480 faces, under a licence with an attribution) and `mock-mesh-open` (Apache-2.0, draft,
///   vertex colours only, at most 1,280 faces, no background removal). The extension `x-mock.flat` makes a flat "card".
/// - **rig:** `mock-skintokens` (the default; `vrm_humanoid` without its fingers, or a skeleton of its own; two influences
///   per vertex) and `mock-template-rigger` (`vrm_humanoid` only, all 52 joints, one influence).
/// - **generate_part:** `mock-hairdeck` (the default; needs a `subject_box`; spring bones; an atlas or no texture; cuts out
///   an opaque picture; a licence with an attribution) and `mock-part-finder` (takes no box, no physics, needs a cut-out
///   picture).
public struct MockMeshEngine: MediaEngine {
    /// Delay per progress step, as the other mocks'.
    public var stepDelay: Duration

    public init(stepDelay: Duration = .zero) { self.stepDelay = stepDelay }

    typealias P = MeshProfile.Param
    typealias K = MeshProfile.SupportsKey
    typealias L = MeshProfile.LimitField

    /// A stand-in for TRELLIS.2's governing licence (DINOv3): commercial use, and words every client must show.
    public static let attributedLicense = License(
        spdx: "LicenseRef-Mock-DINOv3", commercialUse: .yes, termsURL: "https://example.com/mock-dinov3-license",
        notice: "Built with Mock DINOv3. The mock conditioner's trade-control terms apply.", attribution: "Built with Mock DINOv3")
    static let mit = License(spdx: "MIT", commercialUse: .yes, termsURL: "https://opensource.org/license/mit")
    static let imageTypes = ["image/png", "image/jpeg"]
    /// The faces the mock "model" makes when nothing caps it (an icosphere at level 4).
    static let defaultFaces = 5120
    static let defaultTextureSize = 1024
    static let extensionFlat = "x-mock.flat"
    static let flatExtension = ExtensionSpec(name: extensionFlat, title: "Flat result (test)", schema: [
        "type": "boolean", "description": "Makes a near-zero-thickness card, to exercise Mesh §1.8.",
        "x-mes-ui": ["label": "Make a flat card", "widget": "toggle", "advanced": true],
    ])

    // MARK: - Descriptors

    public func descriptors() async -> [Descriptor] {
        MeshProfile.operations.operations.keys.sorted().map(Self.descriptor)
    }

    static func offer(_ id: String, _ title: String, license: License, tiers: [QualityTier], isDefault: Bool? = nil,
                      notes: String? = nil, supports: [String: JSONValue], limits: Descriptor.Limits) -> ModelOffer {
        ModelOffer(id: id, title: title, license: license, memoryClass: .large, speedClass: .slow, qualityTiers: tiers,
                   isDefault: isDefault, notes: notes, supports: supports, limits: limits)
    }

    public static func models(_ operation: String) -> [ModelOffer] {
        switch operation {
        case "mesh.generate":
            return [
                offer("mock-trellis", "Mock TRELLIS", license: attributedLicense, tiers: [.draft, .standard, .best], isDefault: true,
                      notes: "One object per picture; a cut-out PNG is used as it is.",
                      supports: ["background_removal": true, "resolutions": [512, 1024, 1536], "textures": ["atlas", "vertex_colors"],
                                 "texture_sizes": [256, 512, 1024, 2048], "maps": ["base_color"]],
                      limits: .init(profile: [L.minFaces: 100, L.maxFaces: 20480, L.maxTextureSize: 2048])),
                offer("mock-mesh-open", "Mock open mesh", license: .apache2, tiers: [.draft],
                      notes: "Vertex colours only, at most 1,280 faces.",
                      supports: ["textures": ["vertex_colors"]],
                      limits: .init(profile: [L.minFaces: 200, L.maxFaces: 1280])),
            ]
        case "mesh.rig":
            return [
                offer("mock-skintokens", "Mock SkinTokens", license: mit, tiers: [.standard], isDefault: true,
                      notes: "VRM's humanoid skeleton (without fingers), or one of its own for anything else.",
                      supports: ["skeletons": ["vrm_humanoid"], "auto_skeleton": true, "max_influences": 4, "deterministic": false],
                      limits: .init(profile: [L.maxInputFaces: 50000, L.maxJoints: 64])),
                offer("mock-template-rigger", "Mock template rigger", license: .apache2, tiers: [.standard],
                      notes: "VRM's humanoid skeleton only, every joint, one bone per vertex.",
                      supports: ["skeletons": ["vrm_humanoid"], "auto_skeleton": false, "max_influences": 1],
                      limits: .init(profile: [L.maxInputFaces: 50000, L.maxJoints: 64])),
            ]
        case generatePart: return partModels
        default: return []
        }
    }

    static func descriptor(_ operation: String) -> Descriptor {
        let spec = MeshProfile.operations.operations[operation]!
        let part = operation == generatePart
        let notes = part ? [MeshProfile.Input.body: "The avatar the part goes on: a .vrm or another rigged GLB. It is read, never changed.",
                            MeshProfile.Input.image: "The character wearing the part. A cut-out PNG is used as it is."] : [:]
        let inputs = spec.inputs.sorted { $0.key < $1.key }.map { name, io in
            InputSpec(name: name, kind: io.kind, required: io.required ?? false, max: 1,
                      mediaTypes: io.kind == .mesh ? [MeshProfile.mediaType] : imageTypes, notes: notes[name])
        }
        var properties: [String: JSONValue] = [:]
        for (order, name) in spec.vocabulary.enumerated() {
            guard case .object(var schema)? = MeshProfile.vocabularySchema(name, operation: operation) else { continue }
            if part { schema = partSchema(name, schema) }
            switch name {
            case P.texture where !part: schema["enum"] = ["atlas", "vertex_colors"]
            case P.resolution: schema = ["enum": [512, 1024, 1536], "description": schema["description"] ?? nil]
            case P.textureSize: schema["enum"] = [256, 512, 1024, 2048]
            case P.maxFaces: schema["minimum"] = 100; schema["maximum"] = 20480; schema["default"] = .number(Double(defaultFaces))
            case P.skeleton: schema = ["type": "string", "enum": [.string(MeshProfile.Skeleton.vrmHumanoid)],
                                       "description": schema["description"] ?? nil]
            default: break
            }
            schema["x-mes-ui"] = .object(ui(name, order: order))
            properties[name] = .object(schema)
        }
        let outputs = [OutputSpec(name: MeshProfile.Output.mesh, kind: .mesh, mediaTypes: [MeshProfile.mediaType], min: 1, max: 1),
                       OutputSpec(name: MeshProfile.Output.preview, kind: .image, mediaTypes: ["image/png"], min: 1, max: 1)]
        let generate = operation == "mesh.generate"
        return Descriptor(
            operation: operation, profile: MeshProfile.id, profileVersion: MeshProfile.version,
            title: generate ? "Image to 3D" : part ? "Make a part for a character" : "Rig a mesh",
            summary: "Mock: synthetic meshes that follow the Mesh profile's rules.", inputs: inputs,
            params: .object(["type": "object", "additionalProperties": false, "properties": .object(properties)]),
            outputs: outputs,
            limits: generate ? .init(profile: [L.minFaces: 100, L.maxFaces: 20480, L.maxTextureSize: 2048])
                : part ? nil : .init(profile: [L.maxInputFaces: 50000, L.maxJoints: 64]),
            qualityTiers: generate ? [.draft, .standard, .best] : [.standard], models: models(operation),
            extensions: generate ? [flatExtension] : nil, remote: .init(possible: false))
    }

    static func ui(_ name: String, order: Int) -> [String: JSONValue] {
        let widgets = ["seed": "seed", "quality": "picker", "resolution": "picker", "max_faces": "stepper", "texture": "picker",
                       "texture_size": "picker", "background": "picker", "placement": "picker", "size_m": "stepper",
                       "on_flat": "picker", "skeleton": "picker", "part": "picker", "subject_box": "box", "physics": "toggle"]
        let labels = ["max_faces": "Most faces", "texture": "Surface", "texture_size": "Texture size", "size_m": "Size (m)",
                      "on_flat": "If the result is flat", "subject_box": "Where the part is", "physics": "Spring bones"]
        var hints: [String: JSONValue] = ["label": .string(labels[name] ?? name.replacingOccurrences(of: "_", with: " ").capitalized),
                                          "order": .number(Double(order))]
        if let w = widgets[name] { hints["widget"] = .string(w) }
        if name == P.subjectBox { hints["help"] = "Drag a box around the head: hair and face." }
        if ["seed", "resolution", "on_flat"].contains(name) { hints["advanced"] = true }
        return hints
    }

    public func validate(_ request: JobRequest, descriptor: Descriptor) throws {
        try MeshProfileRules.validate(request, descriptor: descriptor)
    }

    // MARK: - Running

    public func run(_ context: RunContext) async throws -> RunOutput {
        var job = Job(context: context, stepDelay: stepDelay)
        switch context.operation {
        case "mesh.generate": return try await job.generate()
        case "mesh.rig": return try await job.rig()
        case MockMeshEngine.generatePart: return try await job.generatePart()
        default: throw MESError(.unknownOperation, "No operation \(context.operation).")
        }
    }

    struct Job {
        let context: RunContext
        let stepDelay: Duration
        var warnings: [Warning] = []

        init(context: RunContext, stepDelay: Duration) { self.context = context; self.stepDelay = stepDelay }

        var model: ModelOffer { context.model }
        var seed: Int { context.param(P.seed)?.intValue ?? Int(Tones.hash(context.jobID) % 1_000_000) }

        func step(_ phase: String, _ n: Int = 1) async throws {
            for i in 1...max(1, n) {
                try Task.checkCancellation()
                if stepDelay > .zero { try await Task.sleep(for: stepDelay) }
                await context.reporter.progress(.running, phase: phase, step: i, steps: n)
            }
        }

        mutating func warn(_ code: String, _ message: String, param: String? = nil) {
            warnings.append(Warning(code: code, message: message, param: param))
        }

        func limit(_ field: String) -> Double? { model.limits?.value(field) ?? context.descriptor.limits?.value(field) }

        // MARK: generate

        mutating func generate() async throws -> RunOutput {
            let params = context.params
            guard let url = context.input(MeshProfile.Input.image)?.fileURL else {
                throw MESError(.invalidRequest, "Input 'image' is missing.", param: MeshProfile.Input.image)
            }
            let (image, _) = try Raster.load(url)
            // §1.10, §3.1: an image with transparency is already cut out; otherwise remove or keep its background.
            let cutOut = stride(from: 3, to: image.pixels.count, by: 4).contains { image.pixels[$0] < 255 }
            let canRemove = model.supports(K.backgroundRemoval)?.boolValue == true
            let background: String
            if cutOut {
                background = MeshProfile.alpha
            } else if let asked = params[P.background]?.stringValue {
                background = asked
            } else if canRemove {
                background = "remove"
            } else {
                background = "keep"
                warn(MeshProfile.WarningCode.backgroundKept, "\(model.title) can't remove a background; the whole picture was used.",
                     param: P.background)
            }
            if background == "remove" { try await step(MeshProfile.Phase.matting) }
            try await step(MeshProfile.Phase.structure, 2)

            // Faces (§1.9): the request's cap, else the model's default within the offer's limit.
            let limitFaces = limit(L.maxFaces).map { Int($0) }
            var cap = params[P.maxFaces]?.intValue ?? MockMeshEngine.defaultFaces
            if params[P.maxFaces] == nil, let limitFaces, limitFaces < cap {
                warn(MeshProfile.WarningCode.facesReduced, "\(model.title) makes \(MockMeshEngine.defaultFaces) faces; its limit cut them to at most \(limitFaces).",
                     param: P.maxFaces)
                cap = limitFaces
            }
            var level = 1
            while level < 5, 20 * Int(pow(4, Double(level + 1))) <= cap { level += 1 }
            try await step(MeshProfile.Phase.shape, 2)

            // Surface (§1.5).
            let textures = model.supports(K.textures)?.arrayValue?.compactMap(\.stringValue) ?? ["atlas"]
            let texture = params[P.texture]?.stringValue ?? textures.first ?? "atlas"
            var textureSize: Int?
            if texture == "atlas" {
                var size = params[P.textureSize]?.intValue ?? MockMeshEngine.defaultTextureSize
                if params[P.textureSize] == nil, let max = limit(L.maxTextureSize).map({ Int($0) }), max < size {
                    warn(MeshProfile.WarningCode.textureReduced, "The \(size) px texture was scaled to \(max) px, \(model.title)'s limit.",
                         param: P.textureSize)
                    size = max
                }
                textureSize = size
            }
            try await step(MeshProfile.Phase.texture, 2)

            // The "model": an icosphere, jittered by the seed, squashed to a card on request.
            let flat = context.extensions[MockMeshEngine.extensionFlat]?.boolValue == true
            let sphere = Icosphere(level: level)
            let squash = [1.0, 1.0, flat ? 0.0004 : 0.85]
            var positions: [[Double]] = sphere.vertices.enumerated().map { i, v in
                let r = 1 + 0.04 * (Double(Tones.hash("\(seed):\(i)") % 1000) / 1000 - 0.5)
                return (0..<3).map { v[$0] * r * squash[$0] }
            }
            let normals: [[Float]] = sphere.vertices.map { v in
                let n = (0..<3).map { v[$0] / max(squash[$0] * squash[$0], 1e-6) }
                let len = sqrt(n.reduce(0) { $0 + $1 * $1 })
                return n.map { Float($0 / len) }
            }
            try await step(MeshProfile.Phase.decimate)

            // Placement (§1.4).
            let placement = params[P.placement]?.stringValue ?? "centered"
            let size = params[P.size]?.numberValue ?? 1
            let raw = MeshBounds(min: (0..<3).map { k in positions.map { $0[k] }.min()! }, max: (0..<3).map { k in positions.map { $0[k] }.max()! })
            let (scale, offset) = MeshProfile.placement(raw, grounded: placement == "grounded", size: size)
            positions = positions.map { p in (0..<3).map { p[$0] * scale + offset[$0] } }

            // Colour from the picture (white behind transparent pixels).
            let colors: [[Float]] = sphere.vertices.map { v in
                let x = Int(((v[0] + 1) / 2 * Double(image.width - 1)).rounded()), y = Int(((1 - v[1]) / 2 * Double(image.height - 1)).rounded())
                let (r, g, b, a) = image[max(0, min(image.width - 1, x)), max(0, min(image.height - 1, y))]
                let alpha = Float(a) / 255
                return [Float(r) / 255 + (1 - alpha), Float(g) / 255 + (1 - alpha), Float(b) / 255 + (1 - alpha), 1].map { min(1, $0) }
            }
            var glb: GLB
            if let textureSize {
                let resized = try Raster.draw(image.cgImage(), width: textureSize, height: textureSize)
                let uvs: [[Float]] = sphere.vertices.map { v in
                    [Float(0.5 + atan2(v[0], v[2]) / (2 * .pi)), Float(0.5 - asin(max(-1, min(1, v[1]))) / .pi)]
                }
                glb = GLB.mesh(positions: positions.map { $0.map(Float.init) }, normals: normals, indices: sphere.indices, uvs: uvs,
                               texture: try resized.pngData(), generator: "MESKit mock-mesh-engine")
            } else {
                glb = GLB.mesh(positions: positions.map { $0.map(Float.init) }, normals: normals, indices: sphere.indices, colors: colors,
                               generator: "MESKit mock-mesh-engine")
            }
            MockMeshEngine.stamp(&glb, license: model.license, title: model.title, generated: true)
            try await step(MeshProfile.Phase.export)
            let meshURL = context.outputDirectory.appendingPathComponent("mesh.glb")
            try glb.data().write(to: meshURL)

            try await step(MeshProfile.Phase.render)
            let previewURL = context.outputDirectory.appendingPathComponent("preview.png")
            let triangles = stride(from: 0, to: sphere.indices.count, by: 3).map { t in
                (0..<3).map { Int(sphere.indices[t + $0]) }
            }
            try MeshPreview.render(positions: positions, triangles: triangles, colors: colors, size: 512)
                .writePNG(to: previewURL, comment: MeshProfile.disclosure(model: model.title), copyright: MockMeshEngine.copyright(model.license))

            var effective: [String: JSONValue] = [
                P.maxFaces: .number(Double(cap)), P.texture: .string(texture), P.background: .string(background),
                P.placement: .string(placement), P.size: .number(size), "model_params": ["mock": true, "level": .number(Double(level))],
            ]
            if let textureSize { effective[P.textureSize] = .number(Double(textureSize)) }
            if let resolutions = model.supports(K.resolutions)?.arrayValue?.compactMap(\.intValue), !resolutions.isEmpty {
                let byTier = [QualityTier.draft: 512, .standard: 1024, .best: 1536][context.quality] ?? resolutions[0]
                effective[P.resolution] = .number(Double(params[P.resolution]?.intValue ?? (resolutions.contains(byTier) ? byTier : resolutions[0])))
            }
            return RunOutput(outputs: [.mesh(meshURL), .file(previewURL, name: MeshProfile.Output.preview, kind: .image, mediaType: "image/png",
                                                             width: 512, height: 512)],
                             effective: effective, seed: seed, warnings: warnings)
        }

        // MARK: rig

        mutating func rig() async throws -> RunOutput {
            guard let url = context.input(MeshProfile.Input.mesh)?.fileURL else {
                throw MESError(.invalidRequest, "Input 'mesh' is missing.", param: MeshProfile.Input.mesh)
            }
            var glb: GLB
            do { glb = try GLB(data: Data(contentsOf: url)) } catch {
                throw MESError(.inputInvalid, "The mesh isn't a GLB: \(error).", param: MeshProfile.Input.mesh)
            }
            let fatal = glb.problems().filter { !$0.contains("NORMAL") && !$0.contains("min and max") }
            if !fatal.isEmpty {
                throw MESError(.inputInvalid, "The mesh can't be rigged: \(fatal.joined(separator: "; ")).", param: MeshProfile.Input.mesh)
            }
            let facts: GLB.Facts
            do { facts = try glb.facts() } catch { throw MESError(.inputInvalid, "The mesh can't be read: \(error).", param: MeshProfile.Input.mesh) }
            if let max = limit(L.maxInputFaces), Double(facts.faces) > max {
                throw MESError(.outOfLimits, "The mesh has \(facts.faces) faces; \(model.title) rigs at most \(Int(max)).", param: MeshProfile.Input.mesh)
            }
            // §3.2: a skinned input is rigged afresh; animations are dropped.
            if !glb.array("skins").isEmpty {
                glb.json["skins"] = nil
                for (i, n) in glb.array("nodes").enumerated() {
                    guard var node = n.objectValue, node["skin"] != nil else { continue }
                    node["skin"] = nil
                    glb.set("nodes", i, node)
                }
                warn(MeshProfile.WarningCode.skinReplaced, "The mesh's skin was replaced.", param: MeshProfile.Input.mesh)
            }
            if !glb.array("animations").isEmpty {
                glb.json["animations"] = nil
                warn(MeshProfile.WarningCode.animationsDropped, "The mesh's animations were dropped.", param: MeshProfile.Input.mesh)
            }
            try await step(MeshProfile.Phase.skeleton, 2)

            // The skeleton, laid out in the mesh's box.
            let template = context.param(P.skeleton)?.stringValue
            var skeleton = Skeleton.layout(template: template, bounds: facts.bounds)
            if template != nil, model.id == "mock-skintokens" {
                let fingers = skeleton.names.filter { ["Thumb", "Index", "Middle", "Ring", "Little"].contains(where: $0.contains) }
                skeleton = skeleton.removing(Set(fingers))
                warn(MeshProfile.WarningCode.jointsDropped, "The mesh has no fingers to bind: the \(fingers.count) finger joints of \(template!) were left out.",
                     param: P.skeleton)
            }
            try await step(MeshProfile.Phase.skin, 2)

            // Joint nodes: one tree, its root added to the scene; translations relative to the parent.
            let firstJoint = glb.array("nodes").count
            for (j, name) in skeleton.names.enumerated() {
                let p = skeleton.positions[j], parent = skeleton.parents[j]
                let local = parent.map { q in (0..<3).map { p[$0] - skeleton.positions[q][$0] } } ?? p
                var node: [String: JSONValue] = ["name": .string(name), "translation": .array(local.map { .number($0) })]
                let children = skeleton.parents.enumerated().filter { $0.element == j }.map { JSONValue.number(Double(firstJoint + $0.offset)) }
                if !children.isEmpty { node["children"] = .array(children) }
                glb.append("nodes", .object(node))
            }
            let sceneIndex = glb.json["scene"]?.intValue ?? 0
            if var scene = glb.object("scenes", sceneIndex) {
                scene["nodes"] = .array((scene["nodes"]?.arrayValue ?? []) + [.number(Double(firstJoint))])
                glb.set("scenes", sceneIndex, scene)
            }
            let prims = glb.primitives()
            let meshWorld = prims.first?.world ?? [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
            let ibms: [[Float]] = skeleton.positions.map { p in
                let inv: [Double] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -p[0], -p[1], -p[2], 1]
                return MockMeshEngine.multiply(inv, meshWorld).map(Float.init)
            }
            let ibmAccessor = glb.addFloats(ibms, type: "MAT4", target: nil)
            let skin = glb.append("skins", ["joints": .array((0..<skeleton.names.count).map { .number(Double(firstJoint + $0)) }),
                                            "inverseBindMatrices": .number(Double(ibmAccessor)), "skeleton": .number(Double(firstJoint)),
                                            "name": .string(template ?? "auto")])
            // Weights: the nearest joints, inverse-distance, as many as the offer allows (at most two here).
            let influences = min(2, model.supports(K.maxInfluences)?.intValue ?? 4)
            var done = Set<String>()
            var allPositions: [[Double]] = [], allTriangles: [[Int]] = [], allColors: [[Float]] = []
            for p in prims {
                let world = try glb.worldPositions(p)
                let base = allPositions.count
                allPositions += world
                allColors += MockMeshEngine.vertexColors(glb, p, count: world.count)
                let tris = try glb.triangles(p)
                allTriangles += stride(from: 0, to: tris.count - tris.count % 3, by: 3).map { t in (0..<3).map { base + Int(tris[t + $0]) } }
                let key = "\(p.mesh)/\(p.index)"
                guard !done.contains(key) else { continue }
                done.insert(key)
                var joints: [[UInt16]] = [], weights: [[Float]] = []
                for v in world {
                    let near = skeleton.positions.enumerated()
                        .map { j, q in (j, sqrt((0..<3).reduce(0.0) { s, k in s + pow(v[k] - q[k], 2) })) }
                        .sorted { $0.1 < $1.1 }.prefix(influences)
                    let inv = near.map { 1 / max($0.1, 1e-6) }, total = inv.reduce(0, +)
                    joints.append(near.map { UInt16($0.0) })
                    weights.append((0..<4).map { $0 < inv.count ? Float(inv[$0] / total) : 0 })
                }
                let jointsAccessor = glb.addJoints(joints), weightsAccessor = glb.addFloats(weights, type: "VEC4")
                guard var mesh = glb.object("meshes", p.mesh), var primitives = mesh["primitives"]?.arrayValue,
                      var prim = primitives[p.index].objectValue, var attributes = prim["attributes"]?.objectValue else { continue }
                attributes["JOINTS_0"] = .number(Double(jointsAccessor))
                attributes["WEIGHTS_0"] = .number(Double(weightsAccessor))
                prim["attributes"] = .object(attributes)
                primitives[p.index] = .object(prim)
                mesh["primitives"] = .array(primitives)
                glb.set("meshes", p.mesh, mesh)
            }
            for n in Set(prims.map(\.node)) {
                guard var node = glb.object("nodes", n) else { continue }
                node["skin"] = .number(Double(skin))
                glb.set("nodes", n, node)
            }
            var extras = glb.mesExtras
            extras["rigged_with"] = .string(model.title)
            glb.mesExtras = extras
            MockMeshEngine.stamp(&glb, license: model.license, title: model.title, generated: false)
            try await step(MeshProfile.Phase.export)
            let meshURL = context.outputDirectory.appendingPathComponent("mesh.glb")
            try glb.data().write(to: meshURL)
            try await step(MeshProfile.Phase.render)
            let previewURL = context.outputDirectory.appendingPathComponent("preview.png")
            let inherited = glb.mesExtras["model"]?.stringValue
            try MeshPreview.render(positions: allPositions, triangles: allTriangles, colors: allColors, size: 512)
                .writePNG(to: previewURL, comment: inherited.map(MeshProfile.disclosure(model:)), copyright: MockMeshEngine.copyright(model.license))
            var effective: [String: JSONValue] = ["model_params": ["mock": true, "joints": .number(Double(skeleton.names.count))]]
            if let template { effective[P.skeleton] = .string(template) }
            return RunOutput(outputs: [.mesh(meshURL), .file(previewURL, name: MeshProfile.Output.preview, kind: .image, mediaType: "image/png",
                                                             width: 512, height: 512)],
                             effective: effective, seed: model.usesSeed ? seed : nil, warnings: warnings)
        }
    }

    // MARK: - Helpers

    /// The licence and disclosure in the file (Mesh §1.11, §1.12; Base §10.2 rule 2).
    static func stamp(_ glb: inout GLB, license: License, title: String, generated: Bool) {
        var extras = glb.mesExtras
        if generated {
            extras["ai_generated"] = true
            extras["model"] = .string(title)
        }
        if license.attribution != nil || license.notice != nil || license.commercialUse != .yes {
            var asset = glb.asset
            let previous = asset["copyright"]?.stringValue
            asset["copyright"] = .string([previous, copyright(license)].compactMap { $0 }.joined(separator: "; "))
            glb.asset = asset
            extras["license"] = .string(license.spdx)
            if let notice = license.notice { extras["notice"] = .string(notice) }
            if let attribution = license.attribution { extras["attribution"] = .string(attribution) }
        }
        glb.mesExtras = extras
    }

    static func copyright(_ license: License) -> String {
        [license.attribution, license.spdx].compactMap { $0 }.joined(separator: ". ")
    }

    static func multiply(_ a: [Double], _ b: [Double]) -> [Double] {
        var r = [Double](repeating: 0, count: 16)
        for col in 0..<4 { for row in 0..<4 { for k in 0..<4 { r[col * 4 + row] += a[k * 4 + row] * b[col * 4 + k] } } }
        return r
    }

    /// A primitive's colours for the preview: its texture sampled at each vertex, its `COLOR_0`, or a neutral grey.
    static func vertexColors(_ glb: GLB, _ p: GLB.Primitive, count: Int) -> [[Float]] {
        let grey: [Float] = [0.7, 0.7, 0.72, 1]
        if let c = p.attributes["COLOR_0"], let colors = try? glb.floats(accessor: c), colors.count == count {
            return colors.map { $0.count == 3 ? $0 + [1] : $0 }
        }
        guard let uvAccessor = p.attributes["TEXCOORD_0"], let uvs = try? glb.floats(accessor: uvAccessor), uvs.count == count,
              let material = p.material.flatMap({ glb.object("materials", $0) }),
              let tex = material["pbrMetallicRoughness"]?["baseColorTexture"]?["index"]?.intValue,
              let source = glb.object("textures", tex)?["source"]?.intValue,
              let (bytes, _) = try? glb.image(source),
              let src = CGImageSourceCreateWithData(bytes as CFData, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let raster = try? Raster.draw(image) else { return Array(repeating: grey, count: count) }
        return uvs.map { uv in
            let x = Int((Double(uv[0]) - floor(Double(uv[0]))) * Double(raster.width - 1))
            let y = Int((Double(uv[1]) - floor(Double(uv[1]))) * Double(raster.height - 1))
            let (r, g, b, _) = raster[x, y]
            return [Float(r) / 255, Float(g) / 255, Float(b) / 255, 1]
        }
    }

    /// A UV-textured icosphere of `faces` (an icosphere has 20 × 4ⁿ), radius 0.5 m, centred: the conformance suite's mesh
    /// input (Mesh §6) and a quick GLB for clients' tests.
    public static func sphereGLB(faces: Int = 1280, textureSize: Int = 64) throws -> Data {
        var level = 0
        while 20 * Int(pow(4, Double(level + 1))) <= faces { level += 1 }
        let sphere = Icosphere(level: level)
        var texture = Raster(width: textureSize, height: textureSize, fill: (200, 40, 40, 255))
        for y in 0..<textureSize { for x in 0..<textureSize where (x / 8 + y / 8) % 2 == 0 { texture[x, y] = (240, 220, 200, 255) } }
        let uvs: [[Float]] = sphere.vertices.map { v in [Float(0.5 + atan2(v[0], v[2]) / (2 * .pi)), Float(0.5 - asin(max(-1, min(1, v[1]))) / .pi)] }
        let glb = GLB.mesh(positions: sphere.vertices.map { $0.map { Float($0 * 0.5) } }, normals: sphere.vertices.map { $0.map(Float.init) },
                           indices: sphere.indices, uvs: uvs, texture: try texture.pngData(), generator: "MESKit fixture")
        return try glb.data()
    }
}

/// An icosphere: a unit sphere of 20 × 4ⁿ triangles, counter-clockwise from outside.
struct Icosphere {
    var vertices: [[Double]] = []
    var indices: [UInt32] = []

    init(level: Int) {
        let t = (1 + sqrt(5.0)) / 2
        var verts: [[Double]] = [[-1, t, 0], [1, t, 0], [-1, -t, 0], [1, -t, 0], [0, -1, t], [0, 1, t], [0, -1, -t], [0, 1, -t],
                                 [t, 0, -1], [t, 0, 1], [-t, 0, -1], [-t, 0, 1]].map(Icosphere.unit)
        var faces: [[Int]] = [[0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11], [1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6],
                              [7, 1, 8], [3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9], [4, 9, 5], [2, 4, 11], [6, 2, 10],
                              [8, 6, 7], [9, 8, 1]]
        for _ in 0..<level {
            var cache: [Int: Int] = [:]
            func mid(_ a: Int, _ b: Int) -> Int {
                let key = min(a, b) << 32 | max(a, b)
                if let m = cache[key] { return m }
                verts.append(Icosphere.unit((0..<3).map { (verts[a][$0] + verts[b][$0]) / 2 }))
                cache[key] = verts.count - 1
                return verts.count - 1
            }
            faces = faces.flatMap { f -> [[Int]] in
                let a = mid(f[0], f[1]), b = mid(f[1], f[2]), c = mid(f[2], f[0])
                return [[f[0], a, c], [f[1], b, a], [f[2], c, b], [a, b, c]]
            }
        }
        vertices = verts
        indices = faces.flatMap { $0.map(UInt32.init) }
    }

    static func unit(_ v: [Double]) -> [Double] {
        let l = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return v.map { $0 / l }
    }
}

/// A skeleton laid out in a mesh's box: joint names (root first), parents, positions in scene space.
struct Skeleton {
    var names: [String]
    var parents: [Int?]
    var positions: [[Double]]

    func removing(_ drop: Set<String>) -> Skeleton {
        let keep = names.indices.filter { !drop.contains(names[$0]) }
        let remap = Dictionary(uniqueKeysWithValues: keep.enumerated().map { ($0.element, $0.offset) })
        return Skeleton(names: keep.map { names[$0] }, parents: keep.map { parents[$0].flatMap { remap[$0] } },
                        positions: keep.map { positions[$0] })
    }

    static func layout(template: String?, bounds: MeshBounds) -> Skeleton {
        let lo = bounds.min, e = bounds.extents.map { max($0, 1e-4) }
        let cx = bounds.center[0], cz = bounds.center[2]
        func at(_ x: Double, _ y: Double, _ z: Double = 0) -> [Double] { [cx + x * e[0], lo[1] + y * e[1], cz + z * e[2]] }
        guard template == MeshProfile.Skeleton.vrmHumanoid, let names = MeshProfile.joints(template: template!) else {
            return Skeleton(names: ["root", "body", "top"], parents: [nil, 0, 1], positions: [at(0, 0), at(0, 0.5), at(0, 1)])
        }
        var parents: [Int?] = [], positions: [[Double]] = []
        let index = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($0.element, $0.offset) })
        for name in names {
            let parts = name.split(separator: "_").map(String.init)            // J, Bip, C/L/R, Bone
            let side = parts[2] == "L" ? 1.0 : parts[2] == "R" ? -1.0 : 0, bone = parts[3]
            func p(_ n: String) -> Int? { index["J_Bip_\(parts[2])_\(n)"] ?? index["J_Bip_C_\(n)"] }
            switch bone {
            case "Hips": parents.append(nil); positions.append(at(0, 0.5))
            case "Spine": parents.append(p("Hips")); positions.append(at(0, 0.58))
            case "Chest": parents.append(p("Spine")); positions.append(at(0, 0.66))
            case "UpperChest": parents.append(p("Chest")); positions.append(at(0, 0.72))
            case "Neck": parents.append(p("UpperChest")); positions.append(at(0, 0.82))
            case "Head": parents.append(p("Neck")); positions.append(at(0, 0.88))
            case "Shoulder": parents.append(index["J_Bip_C_UpperChest"]); positions.append(at(side * 0.08, 0.78))
            case "UpperArm": parents.append(p("Shoulder")); positions.append(at(side * 0.2, 0.78))
            case "LowerArm": parents.append(p("UpperArm")); positions.append(at(side * 0.33, 0.78))
            case "Hand": parents.append(p("LowerArm")); positions.append(at(side * 0.44, 0.78))
            case "UpperLeg": parents.append(index["J_Bip_C_Hips"]); positions.append(at(side * 0.1, 0.48))
            case "LowerLeg": parents.append(p("UpperLeg")); positions.append(at(side * 0.1, 0.27))
            case "Foot": parents.append(p("LowerLeg")); positions.append(at(side * 0.1, 0.05))
            case "ToeBase": parents.append(p("Foot")); positions.append(at(side * 0.1, 0.02, 0.3))
            default:
                // Fingers: Thumb1…Little3, each chain from the hand.
                let finger = String(bone.dropLast()), k = Int(String(bone.last!)) ?? 1
                let row = Double(["Thumb", "Index", "Middle", "Ring", "Little"].firstIndex(of: finger) ?? 0)
                parents.append(k == 1 ? p("Hand") : p("\(finger)\(k - 1)"))
                positions.append(at(side * (0.46 + 0.015 * Double(k)), 0.78 - 0.008 * (row - 2), finger == "Thumb" ? 0.1 : 0))
            }
        }
        return Skeleton(names: names, parents: parents, positions: positions)
    }
}

/// The preview still (Mesh §1.7): an orthographic, flat-shaded render from azimuth 30° and elevation 20°, on transparent.
enum MeshPreview {
    static func render(positions: [[Double]], triangles: [[Int]], colors: [[Float]], size: Int) throws -> Raster {
        let az = 30.0 * .pi / 180, el = 20.0 * .pi / 180
        let d = [sin(az) * cos(el), sin(el), cos(az) * cos(el)]                 // towards the camera
        func cross(_ a: [Double], _ b: [Double]) -> [Double] { [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]] }
        func dot(_ a: [Double], _ b: [Double]) -> Double { a[0] * b[0] + a[1] * b[1] + a[2] * b[2] }
        func norm(_ a: [Double]) -> [Double] { let l = sqrt(dot(a, a)); return l > 0 ? a.map { $0 / l } : a }
        let right = norm(cross([0, 1, 0], d)), up = cross(d, right)
        let light = norm([d[0] + 0.3, d[1] + 0.6, d[2]])
        var lo = [Double](repeating: .infinity, count: 3), hi = [Double](repeating: -.infinity, count: 3)
        for p in positions { for k in 0..<3 { lo[k] = min(lo[k], p[k]); hi[k] = max(hi[k], p[k]) } }
        let c = (0..<3).map { (lo[$0] + hi[$0]) / 2 }
        let projected = positions.map { p -> (Double, Double, Double) in
            let q = (0..<3).map { p[$0] - c[$0] }
            return (dot(q, right), dot(q, up), dot(q, d))
        }
        let span = max(projected.map { abs($0.0) }.max() ?? 1, projected.map { abs($0.1) }.max() ?? 1, 1e-6)
        let scale = 0.45 * Double(size) / span, half = Double(size) / 2
        var raster = Raster(width: size, height: size, fill: (0, 0, 0, 0))
        let order = triangles.indices.sorted { a, b in
            triangles[a].reduce(0) { $0 + projected[$1].2 } < triangles[b].reduce(0) { $0 + projected[$1].2 }
        }
        try raster.pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: Raster.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw MESError(.engineError, "Couldn't draw the preview.")
            }
            ctx.setLineWidth(0.6)
            for t in order {
                let tri = triangles[t]
                guard tri.allSatisfy({ positions.indices.contains($0) }) else { continue }
                let a = positions[tri[0]], b = positions[tri[1]], cc = positions[tri[2]]
                let n = norm(cross((0..<3).map { b[$0] - a[$0] }, (0..<3).map { cc[$0] - a[$0] }))
                let shade = 0.35 + 0.65 * abs(dot(n, light))
                let rgb = (0..<3).map { k in Double(tri.reduce(Float(0)) { $0 + (colors.indices.contains($1) ? colors[$1][k] : 0.7) }) / 3 * shade }
                let color = CGColor(srgbRed: min(1, rgb[0]), green: min(1, rgb[1]), blue: min(1, rgb[2]), alpha: 1)
                ctx.setFillColor(color)
                ctx.setStrokeColor(color)
                ctx.beginPath()
                for (i, v) in tri.enumerated() {
                    let pt = CGPoint(x: half + projected[v].0 * scale, y: half + projected[v].1 * scale)
                    if i == 0 { ctx.move(to: pt) } else { ctx.addLine(to: pt) }
                }
                ctx.closePath()
                ctx.drawPath(using: .fillStroke)
            }
        }
        // CoreGraphics draws bottom-up into this buffer; rows are already top-down in memory for a bitmap context.
        return raster
    }
}

extension Raster {
    func pngData() throws -> Data {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            throw MESError(.engineError, "Couldn't create a PNG.")
        }
        CGImageDestinationAddImage(dest, cgImage(), nil)
        guard CGImageDestinationFinalize(dest) else { throw MESError(.engineError, "Couldn't write a PNG.") }
        return out as Data
    }

    /// A PNG with its `Comment` and `Copyright` text (Base §10.2 rule 2, Mesh §1.11).
    func writePNG(to url: URL, comment: String?, copyright: String?) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw MESError(.engineError, "Couldn't create a PNG.")
        }
        var png: [CFString: Any] = [:]
        if let comment { png[kCGImagePropertyPNGComment] = comment }
        if let copyright, !copyright.isEmpty { png[kCGImagePropertyPNGCopyright] = copyright }
        CGImageDestinationAddImage(dest, cgImage(), [kCGImagePropertyPNGDictionary: png] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw MESError(.engineError, "Couldn't write a PNG.") }
    }
}
