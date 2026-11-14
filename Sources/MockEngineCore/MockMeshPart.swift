import Foundation
import MESCore
import MESEngineCore

// `mesh.generate_part` in the mock (Mesh §3.3, RFC 0009): a part made to fit a body. It runs no model. It reads the body's
// head bone and writes a hair card above it: a flat, skinned ribbon as wide as the box, hung from a joint named as the
// body's head bone, with a three-joint chain and one `VRMC_springBone` spring when physics is on. That is everything a
// client's part path depends on: the body is read, the part is in the body's coordinates, it is thin without being
// warned as flat, and its skin and springs reach the client.
//
// - `mock-hairdeck` (the default): needs a `subject_box`, makes spring bones, an atlas or no texture, cuts out an opaque
//   picture, under a licence with an attribution.
// - `mock-part-finder`: "locates" the part itself, so it takes no box; no physics; an atlas only; needs a cut-out picture.
extension MockMeshEngine {
    static let generatePart = "mesh.generate_part"

    static var partModels: [ModelOffer] {
        [
            offer("mock-hairdeck", "Mock HairDeck", license: attributedLicense, tiers: [.standard], isDefault: true,
                  notes: "Hair for a VRM, or any rigged GLB with a bone whose name ends in 'head'. Drag the box around the head.",
                  supports: ["parts": ["hair"], "subject_box": "required", "physics": true, "textures": ["atlas", "none"],
                             "background_removal": true],
                  limits: .init(profile: [:])),
            offer("mock-part-finder", "Mock part finder", license: .apache2, tiers: [.standard],
                  notes: "Finds the head itself, so it takes no box. Needs a cut-out picture. No spring bones.",
                  supports: ["parts": ["hair"]],
                  limits: .init(profile: [:])),
        ]
    }

    /// `subject_box` as a descriptor shows it: the vocabulary's shape, drawn on the picture (Base §6.1's `box` widget).
    static func partSchema(_ name: String, _ schema: [String: JSONValue]) -> [String: JSONValue] {
        var schema = schema
        switch name {
        case P.part: schema = ["type": "string", "enum": [.string(MeshProfile.Part.hair)], "description": schema["description"] ?? nil]
        case P.texture: schema["enum"] = ["atlas", .string(MeshProfile.noTexture)]
        case P.quality: schema["enum"] = ["standard"]
        default: break
        }
        return schema
    }

    /// The conformance suite's body (Mesh §6) and a quick rigged GLB for clients' tests: a small VRM 1.0 figure, 1.57 m
    /// tall, standing on the ground and facing +Z. Two skinned meshes, `Body` and `Face`, on VRM's humanoid skeleton as
    /// VRoid names it, with a `VRMC_vrm` humanoid map: its head bone is `J_Bip_C_Head`.
    public static func bodyGLB() throws -> Data {
        var g = GLB(json: ["asset": ["version": "2.0", "generator": "MESKit fixture"], "scene": 0])
        let sphere = Icosphere(level: 2)
        // (name, centre, radii, colour)
        let parts: [(String, [Double], [Double], [Double])] = [
            ("Body", [0, 0.70, 0], [0.17, 0.70, 0.11], [0.45, 0.5, 0.6, 1]),
            ("Face", [0, 1.50, 0.01], [0.07, 0.07, 0.07], [0.93, 0.78, 0.68, 1]),
        ]
        let bounds = MeshBounds(min: [-0.17, 0, -0.11], max: [0.17, 1.57, 0.11])
        let skeleton = Skeleton.layout(template: MeshProfile.Skeleton.vrmHumanoid, bounds: bounds)

        // Joint nodes first, so a joint's node index is its index in the skeleton.
        for (j, name) in skeleton.names.enumerated() {
            let p = skeleton.positions[j]
            let local = skeleton.parents[j].map { q in (0..<3).map { p[$0] - skeleton.positions[q][$0] } } ?? p
            var node: [String: JSONValue] = ["name": .string(name), "translation": .array(local.map { .number($0) })]
            let children = skeleton.parents.enumerated().filter { $0.element == j }.map { JSONValue.number(Double($0.offset)) }
            if !children.isEmpty { node["children"] = .array(children) }
            g.append("nodes", .object(node))
        }
        let ibms: [[Float]] = skeleton.positions.map { p in [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, Float(-p[0]), Float(-p[1]), Float(-p[2]), 1] }
        let skin = g.append("skins", ["name": "Body", "skeleton": 0, "joints": .array(skeleton.names.indices.map { .number(Double($0)) }),
                                      "inverseBindMatrices": .number(Double(g.addFloats(ibms, type: "MAT4", target: nil)))])
        var sceneNodes: [JSONValue] = [0]
        for (name, centre, radii, colour) in parts {
            let positions = sphere.vertices.map { v in (0..<3).map { centre[$0] + v[$0] * radii[$0] } }
            let normals: [[Float]] = sphere.vertices.map { v in
                let n = (0..<3).map { v[$0] / radii[$0] }, len = sqrt(n.reduce(0) { $0 + $1 * $1 })
                return n.map { Float($0 / len) }
            }
            // One bone per vertex: the nearest joint.
            let joints: [[UInt16]] = positions.map { v in
                let nearest = skeleton.positions.enumerated().min { a, b in distance(a.element, v) < distance(b.element, v) }!.offset
                return [UInt16(nearest)]
            }
            let attributes: [String: JSONValue] = [
                "POSITION": .number(Double(g.addFloats(positions.map { $0.map(Float.init) }, type: "VEC3", bounds: true))),
                "NORMAL": .number(Double(g.addFloats(normals, type: "VEC3"))),
                "JOINTS_0": .number(Double(g.addJoints(joints))),
                "WEIGHTS_0": .number(Double(g.addFloats(positions.map { _ in [1, 0, 0, 0] }, type: "VEC4"))),
            ]
            let material = g.append("materials", ["name": .string(name), "pbrMetallicRoughness": [
                "baseColorFactor": .array(colour.map { .number($0) }), "metallicFactor": 0, "roughnessFactor": 0.9]])
            let mesh = g.append("meshes", ["name": .string(name), "primitives": [[
                "attributes": .object(attributes), "indices": .number(Double(g.addIndices(sphere.indices))),
                "material": .number(Double(material)), "mode": 4]]])
            sceneNodes.append(.number(Double(g.append("nodes", ["name": .string(name), "mesh": .number(Double(mesh)), "skin": .number(Double(skin))]))))
        }
        g.append("scenes", ["nodes": .array(sceneNodes)])

        var humanBones: [String: JSONValue] = [:]
        for (j, name) in skeleton.names.enumerated() {
            if let bone = vrmBone(vroid: name) { humanBones[bone] = ["node": .number(Double(j))] }
        }
        g.json["extensionsUsed"] = ["VRMC_vrm"]
        g.json["extensions"] = ["VRMC_vrm": [
            "specVersion": "1.0",
            "meta": ["name": "MES conformance body", "version": "1", "authors": ["MESKit"],
                     "licenseUrl": "https://vrm.dev/licenses/1.0/", "avatarPermission": "everyone", "commercialUsage": "corporation",
                     "creditNotation": "unnecessary", "modification": "allowModificationRedistribution"],
            "humanoid": ["humanBones": .object(humanBones)],
        ]]
        return try g.data()
    }

    static func distance(_ a: [Double], _ b: [Double]) -> Double { sqrt((0..<3).reduce(0.0) { $0 + pow(a[$1] - b[$1], 2) }) }

    /// VRM 1.0's name for a bone VRoid names `J_Bip_<side>_<Bone>` (`J_Bip_L_Index2` → `leftIndexIntermediate`).
    static func vrmBone(vroid name: String) -> String? {
        let parts = name.split(separator: "_").map(String.init)
        guard parts.count == 4, parts[0] == "J", parts[1] == "Bip" else { return nil }
        let side = ["L": "left", "R": "right", "C": ""][parts[2]] ?? "", bone = parts[3]
        var vrm: String
        if bone == "ToeBase" {
            vrm = "Toes"
        } else if let digit = bone.last.flatMap({ Int(String($0)) }) {
            let finger = String(bone.dropLast())
            let segment = finger == "Thumb" ? ["Metacarpal", "Proximal", "Distal"] : ["Proximal", "Intermediate", "Distal"]
            guard (1...3).contains(digit) else { return nil }
            vrm = finger + segment[digit - 1]
        } else {
            vrm = bone
        }
        return side.isEmpty ? vrm.prefix(1).lowercased() + vrm.dropFirst() : side + vrm
    }

    /// A rotation (column-major 3×3, orthonormal) as a unit quaternion `[x, y, z, w]`.
    static func quaternion(_ r: [Double]) -> [Double] {
        let (m00, m10, m20, m01, m11, m21, m02, m12, m22) = (r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8])
        let trace = m00 + m11 + m22
        if trace > 0 {
            let s = sqrt(trace + 1) * 2
            return [(m21 - m12) / s, (m02 - m20) / s, (m10 - m01) / s, s / 4]
        } else if m00 > m11, m00 > m22 {
            let s = sqrt(1 + m00 - m11 - m22) * 2
            return [s / 4, (m01 + m10) / s, (m02 + m20) / s, (m21 - m12) / s]
        } else if m11 > m22 {
            let s = sqrt(1 + m11 - m00 - m22) * 2
            return [(m01 + m10) / s, s / 4, (m12 + m21) / s, (m02 - m20) / s]
        }
        let s = sqrt(1 + m22 - m00 - m11) * 2
        return [(m02 + m20) / s, (m12 + m21) / s, s / 4, (m10 - m01) / s]
    }
}

extension MockMeshEngine.Job {
    typealias P = MeshProfile.Param
    typealias K = MeshProfile.SupportsKey

    mutating func generatePart() async throws -> RunOutput {
        guard let imageURL = context.input(MeshProfile.Input.image)?.fileURL else {
            throw MESError(.invalidRequest, "Input 'image' is missing.", param: MeshProfile.Input.image)
        }
        guard let bodyURL = context.input(MeshProfile.Input.body)?.fileURL else {
            throw MESError(.invalidRequest, "Input 'body' is missing: the GLB or VRM the part goes on.", param: MeshProfile.Input.body)
        }
        // §3.3: the body is read, never changed, and not held to §1.1–1.2. It must be a GLB with the part's bone.
        let body: GLB
        do { body = try GLB(data: Data(contentsOf: bodyURL)) } catch {
            throw MESError(.inputInvalid, "Input 'body' isn't a GLB or VRM: \(error).", param: MeshProfile.Input.body)
        }
        let request = JobRequest(operation: context.operation, params: context.params)
        let (part, physics, texture) = MeshProfileRules.partDefaults(request, model: model)
        guard let bone = body.bodyBone(for: part) else {
            throw MESError(.inputInvalid, "The body has no head bone \(model.title) can find: it reads a VRM's humanoid head, or a node "
                           + "whose name ends in 'head'.", param: MeshProfile.Input.body)
        }

        // §1.10, §3.3: a picture with transparency is already cut out; an opaque one is cut out where the offer can.
        let (image, _) = try Raster.load(imageURL)
        let cutOut = stride(from: 3, to: image.pixels.count, by: 4).contains { image.pixels[$0] < 255 }
        let background: String
        if cutOut {
            background = MeshProfile.alpha
        } else if model.supports(K.backgroundRemoval)?.boolValue == true {
            background = "remove"
            try await step(MeshProfile.Phase.matting)
        } else {
            throw MESError(.unsupportedParameter, "\(model.title) needs a picture that is already cut out (one with transparency).",
                           param: MeshProfile.Input.image)
        }

        // The "model": where the box is, how wide, and the colour inside it.
        let box = SubjectBox(context.param(P.subjectBox))
        let (x0, y0, x1, y1) = (box ?? SubjectBox(x: 0, y: 0, width: 1, height: 1)).pixels(width: image.width, height: image.height)
        var sum = [0.0, 0.0, 0.0], count = 0.0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let (r, g, b, a) = image[x, y]
                guard a > 0 else { continue }
                sum[0] += Double(r); sum[1] += Double(g); sum[2] += Double(b); count += 1
            }
        }
        let colour = count > 0 ? sum.map { Float($0 / count / 255) } : [0.35, 0.25, 0.2]
        try await step(MeshProfile.Phase.shape, 2)

        // The head's place and turn in the body's file (scale dropped), and the card above it: three rows of two
        // vertices, flat in the head's own XY plane, leaning a little by the seed.
        let w = bone.world
        let columns = (0..<3).map { c -> [Double] in
            let v = [w[c * 4], w[c * 4 + 1], w[c * 4 + 2]], len = sqrt(v.reduce(0) { $0 + $1 * $1 })
            return len > 0 ? v.map { $0 / len } : (0..<3).map { $0 == c ? 1 : 0 }
        }
        let rotation = columns.flatMap { $0 }                                   // column-major 3×3
        let head = [w[12], w[13], w[14]]
        func world(_ local: [Double]) -> [Double] {
            (0..<3).map { row in head[row] + columns[0][row] * local[0] + columns[1][row] * local[1] + columns[2][row] * local[2] }
        }
        let half = 0.02 + 0.04 * (box?.width ?? 1)
        let lean = 0.02 * (Double(Tones.hash("\(seed)") % 1000) / 1000 - 0.5)
        let rows: [(y: Double, half: Double, x: Double)] = [(0.10, half, 0), (0.18, half * 0.7, lean / 2), (0.26, half * 0.4, lean)]
        var positions: [[Double]] = [], uvs: [[Float]] = [], joints: [[UInt16]] = []
        for (r, row) in rows.enumerated() {
            for side in [-1.0, 1.0] {
                positions.append(world([row.x + side * row.half, row.y, 0]))
                uvs.append([side < 0 ? 0 : 1, 1 - Float(r) / 2])
                joints.append([physics ? UInt16(r) : 0])                        // head, then the chain's first and second joints
            }
        }
        let normal = columns[2].map(Float.init)
        let indices: [UInt32] = [0, 1, 2, 2, 1, 3, 2, 3, 4, 4, 3, 5]
        try await step(MeshProfile.Phase.texture)

        var g = GLB(json: ["asset": ["version": "2.0", "generator": "MESKit mock-mesh-engine"], "scene": 0])
        var attributes: [String: JSONValue] = [
            "POSITION": .number(Double(g.addFloats(positions.map { $0.map(Float.init) }, type: "VEC3", bounds: true))),
            "NORMAL": .number(Double(g.addFloats(positions.map { _ in normal }, type: "VEC3"))),
            "JOINTS_0": .number(Double(g.addJoints(joints))),
            "WEIGHTS_0": .number(Double(g.addFloats(positions.map { _ in [1, 0, 0, 0] }, type: "VEC4"))),
        ]
        var pbr: [String: JSONValue] = ["metallicFactor": 0, "roughnessFactor": 1]
        switch texture {
        case "atlas":
            attributes["TEXCOORD_0"] = .number(Double(g.addFloats(uvs, type: "VEC2")))
            let swatch = Raster(width: 8, height: 8, fill: (UInt8(colour[0] * 255), UInt8(colour[1] * 255), UInt8(colour[2] * 255), 255))
            let source = g.addImage(try swatch.pngData(), mediaType: "image/png")
            g.append("samplers", ["magFilter": 9728, "minFilter": 9728])
            pbr["baseColorTexture"] = ["index": .number(Double(g.append("textures", ["source": .number(Double(source)), "sampler": 0])))]
        case "vertex_colors":
            attributes["COLOR_0"] = .number(Double(g.addFloats(positions.map { _ in colour + [1] }, type: "VEC4")))
        default:
            pbr["baseColorFactor"] = [0.8, 0.8, 0.8, 1]                         // `none`: a plain material
        }
        let material = g.append("materials", ["name": "MockHair", "doubleSided": true, "pbrMetallicRoughness": .object(pbr)])
        let mesh = g.append("meshes", ["name": "MockHair", "primitives": [[
            "attributes": .object(attributes), "indices": .number(Double(g.addIndices(indices))),
            "material": .number(Double(material)), "mode": 4]]])
        try await step(MeshProfile.Phase.skin)

        // The skeleton: the head bone, named as the body's and where the body has it; under it, with physics, a chain
        // along the card. No joint of the chain is turned, so every joint's rotation in the file is the head's.
        let quaternion = MockMeshEngine.quaternion(rotation)
        var places = [head]
        var headNode: [String: JSONValue] = ["name": .string(bone.name), "translation": .array(head.map { .number($0) }),
                                             "rotation": .array(quaternion.map { .number($0) })]
        if physics {
            headNode["children"] = [1]
            g.append("nodes", .object(headNode))
            var previous = [0.0, 0.0, 0.0]
            for (r, row) in rows.enumerated() {
                let local = [row.x, row.y, 0]
                var node: [String: JSONValue] = ["name": .string(r == rows.count - 1 ? "MockHair_end" : "MockHair_0\(r)"),
                                                 "translation": .array((0..<3).map { .number(local[$0] - previous[$0]) })]
                if r < rows.count - 1 { node["children"] = [.number(Double(r + 2))] }
                g.append("nodes", .object(node))
                places.append(world(local))
                previous = local
            }
        } else {
            g.append("nodes", .object(headNode))
        }
        // A joint's inverse bind matrix: the head's turn undone, then its place taken away.
        let ibms: [[Float]] = places.map { p in
            let t = (0..<3).map { c in -(columns[c][0] * p[0] + columns[c][1] * p[1] + columns[c][2] * p[2]) }
            return [columns[0][0], columns[1][0], columns[2][0], 0, columns[0][1], columns[1][1], columns[2][1], 0,
                    columns[0][2], columns[1][2], columns[2][2], 0, t[0], t[1], t[2], 1].map(Float.init)
        }
        let skin = g.append("skins", ["name": "MockHair", "skeleton": 0, "joints": .array(places.indices.map { .number(Double($0)) }),
                                      "inverseBindMatrices": .number(Double(g.addFloats(ibms, type: "MAT4", target: nil)))])
        let meshNode = g.append("nodes", ["name": "MockHair", "mesh": .number(Double(mesh)), "skin": .number(Double(skin))])
        g.append("scenes", ["nodes": [0, .number(Double(meshNode))]])
        if physics {
            g.json["extensionsUsed"] = [.string(MeshProfile.springBoneExtension)]
            g.json["extensions"] = [MeshProfile.springBoneExtension: [
                "specVersion": "1.0",
                "springs": [["name": "MockHair", "joints": [
                    ["node": 1, "hitRadius": 0.02, "stiffness": 1.0, "gravityPower": 0, "gravityDir": [0, -1, 0], "dragForce": 0.4],
                    ["node": 2, "hitRadius": 0.02, "stiffness": 1.0, "gravityPower": 0, "gravityDir": [0, -1, 0], "dragForce": 0.4],
                    ["node": 3],
                ]]],
            ]]
        }
        MockMeshEngine.stamp(&g, license: model.license, title: model.title, generated: true)
        try await step(MeshProfile.Phase.export)
        let meshURL = context.outputDirectory.appendingPathComponent("mesh.glb")
        try g.data().write(to: meshURL)

        try await step(MeshProfile.Phase.render)
        let previewURL = context.outputDirectory.appendingPathComponent("preview.png")
        let shown: [Float] = texture == MeshProfile.noTexture ? [0.8, 0.8, 0.8, 1] : colour + [1]
        try MeshPreview.render(positions: positions, triangles: [[0, 1, 2], [2, 1, 3], [2, 3, 4], [4, 3, 5]],
                               colors: positions.map { _ in shown }, size: 512)
            .writePNG(to: previewURL, comment: MeshProfile.disclosure(model: model.title), copyright: MockMeshEngine.copyright(model.license))

        var effective: [String: JSONValue] = [
            P.part: .string(part), P.physics: .bool(physics), P.texture: .string(texture), P.background: .string(background),
            "model_params": ["mock": true, "head_bone": .string(bone.name)],
        ]
        if let box { effective[P.subjectBox] = box.json }
        return RunOutput(outputs: [.mesh(meshURL), .file(previewURL, name: MeshProfile.Output.preview, kind: .image, mediaType: "image/png",
                                                         width: 512, height: 512)],
                         effective: effective, seed: seed, warnings: warnings)
    }
}
