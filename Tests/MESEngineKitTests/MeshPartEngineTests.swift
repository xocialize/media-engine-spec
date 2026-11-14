import Foundation
import Hummingbird
import HummingbirdTesting
@testable import MESCore
@testable import MESEngineCore
@testable import MESEngineKit
@testable import MockEngineCore
import Testing

// RFC 0009 in the kit: `mesh.generate_part` against the mock over HTTP. The part stays on its body, thin without a
// flat_result; the box's structure is 400 ahead of the schema; the gates route and refuse (parts, subject_box, physics,
// textures); the body and the picture are refused when the model can't use them.

@Suite("Mesh: a part made to fit a body (RFC 0009)")
struct MeshPartEngineTests {
    func app() async throws -> some ApplicationProtocol {
        try await MESEngineServer(engine: MockMeshEngine(), configuration: freshConfig()).makeApplication()
    }

    static let box: JSONValue = ["x": 0.25, "y": 0.25, "width": 0.5, "height": 0.5]
    static func glb(_ data: Data) -> RequestInput { .one(.inline(mediaType: "model/gltf-binary", data: data)) }

    static func part(_ params: [String: JSONValue] = ["subject_box": box], model: String? = nil, transparent: Bool = true,
                     body: Data? = nil) throws -> JobRequest {
        JobRequest(operation: "mesh.generate_part",
                   inputs: ["image": MeshEngineTests.image(transparent: transparent), "body": glb(try body ?? MockMeshEngine.bodyGLB())],
                   params: params, model: model)
    }

    @Test("The descriptor: both inputs required, the part's parameters, a box widget, two offers with their supports")
    func descriptor() async throws {
        let d = try #require(await MockMeshEngine().descriptors().first { $0.operation == "mesh.generate_part" })
        #expect(d.inputs.map(\.name) == ["body", "image"] && d.inputs.allSatisfy(\.required))
        #expect(d.inputs[0].kind == .mesh && d.inputs[0].mediaTypes == ["model/gltf-binary"])
        let props = d.params["properties"]?.objectValue ?? [:]
        #expect(Set(props.keys) == ["part", "subject_box", "physics", "texture", "seed", "quality"])
        #expect(props["subject_box"]?["x-mes-ui"]?["widget"] == "box" && props["texture"]?["enum"] == ["atlas", "none"])
        #expect(d.models.map(\.id) == ["mock-hairdeck", "mock-part-finder"] && d.limits == nil && d.extensions == nil)
        #expect(MeshProfileRules.subjectBoxSupport(d.models[0]) == .required && MeshProfileRules.subjectBoxSupport(d.models[1]) == nil)
        #expect(conforms(try jsonBody(d), to: "base/descriptor.schema.json").isEmpty)
        for m in d.models {
            #expect(conforms(try jsonBody(JSONValue.object(m.supports ?? [:])), to: "profiles/mesh/supports.schema.json#/$defs/generate_part_supports").isEmpty, "\(m.id)")
        }
    }

    @Test("A part: on the body's head bone, in the body's coordinates, skinned, with springs; thin, and never warned as flat")
    func onTheBody() async throws {
        try await app().test(.live) { client in
            let bodyData = try MockMeshEngine.bodyGLB()
            let head = try #require(try GLB(data: bodyData).bodyBone(for: "hair"))
            #expect(head.name == "J_Bip_C_Head")
            let job = try await client.run(try Self.part(["subject_box": Self.box, "seed": 7]))
            #expect(job.outcome == .succeeded && job.plan?.model.id == "mock-hairdeck", "\(job.error?.message ?? "")")
            let mesh = try #require(job.result?.meshes.first)
            #expect(mesh.joints == 4 && mesh.vertices == 6 && mesh.faces == 4 && mesh.textureSize == 8)
            // The card is flat (a hair card is), sits above the head bone, and carries no flat_result.
            let b = try #require(mesh.bounds)
            #expect(b.thinness < MeshProfile.flatRatio && !job.warnings.map(\.code).contains("flat_result"), "\(job.warnings)")
            #expect(abs(b.min[1] - (head.world[13] + 0.10)) < 1e-4 && abs(b.max[1] - (head.world[13] + 0.26)) < 1e-4)
            #expect(abs(b.center[0]) < 0.02 && (b.extents.max() ?? 0) < 0.2, "moved or scaled: \(b)")
            let eff = job.result?.effective ?? [:]
            #expect(eff["part"] == "hair" && eff["physics"] == true && eff["texture"] == "atlas" && eff["background"] == "alpha"
                    && eff["subject_box"] == Self.box && eff["seed"] == 7, "\(eff)")
            #expect(eff["placement"] == nil && eff["size_m"] == nil)
            #expect(job.result?.preview(for: mesh)?.width == 512)
            #expect(conforms(try await client.get("/jobs/\(job.id)").body, to: "base/job.schema.json").isEmpty)

            let glb = try GLB(data: Data(buffer: try await client.get("/jobs/\(job.id)/outputs/\(mesh.index)").body))
            #expect(glb.problems().isEmpty, "\(glb.problems())")
            let joints = glb.array("skins")[0]["joints"]?.arrayValue?.compactMap(\.intValue) ?? []
            #expect(glb.array("skins").count == 1 && joints == [0, 1, 2, 3])
            #expect(glb.object("nodes", 0)?["name"] == "J_Bip_C_Head")
            let root = glb.worldMatrix(node: 0)
            #expect((12...14).allSatisfy { abs(root[$0] - head.world[$0]) < 1e-6 })
            #expect(glb.json["extensionsUsed"] == ["VRMC_springBone"] && glb.json["extensionsRequired"] == nil)
            #expect(glb.json["extensions"]?["VRMC_springBone"]?["springs"]?.arrayValue?.first?["joints"]?.arrayValue?.count == 3)
            // Disclosure and the licence's attribution are in the file; everything else is the model's.
            #expect(glb.mesExtras["ai_generated"] == true && glb.mesExtras["model"] == "Mock HairDeck")
            #expect(glb.asset["copyright"]?.stringValue?.contains("Built with Mock DINOv3") == true)
            // The body never comes back: the part has six vertices, the body hundreds.
            #expect(try GLB(data: bodyData).facts().vertices > 300)
        }
    }

    @Test("physics false: skinned to the head bone alone, no VRMC_springBone; texture none: a plain material, no texture_size")
    func physicsAndTexture() async throws {
        try await app().test(.live) { client in
            let job = try await client.run(try Self.part(["subject_box": Self.box, "physics": false, "texture": "none"]))
            #expect(job.outcome == .succeeded, "\(job.error?.message ?? "")")
            let mesh = try #require(job.result?.meshes.first)
            #expect(mesh.joints == 1 && mesh.textureSize == nil)
            #expect(job.result?.effective["physics"] == false && job.result?.effective["texture"] == "none")
            let glb = try GLB(data: Data(buffer: try await client.get("/jobs/\(job.id)/outputs/\(mesh.index)").body))
            #expect(glb.json["extensions"] == nil && glb.json["extensionsUsed"] == nil && glb.array("images").isEmpty)
            #expect(try glb.facts().hasVertexColors == false && glb.problems().isEmpty)
            #expect(glb.object("nodes", 0)?["name"] == "J_Bip_C_Head" && glb.object("nodes", 0)?["children"] == nil)
        }
    }

    @Test("The box: malformed is 400 ahead of the schema; with one the request goes to the offer that takes it, without to the one that finds the part")
    func box() async throws {
        try await app().test(.live) { client in
            func refusal(_ r: JobRequest) async throws -> (String, String?) {
                let body = try decode(ErrorBody.self, try await client.post("/jobs", r).body)
                return (body.error.code, body.error.param)
            }
            let bad: [JSONValue] = [["x": 0.6, "y": 0.1, "width": 0.6, "height": 0.4], ["x": 0.1, "y": 0.7, "width": 0.4, "height": 0.4],
                                    ["x": 0.2, "y": 0.2, "width": 0, "height": 0.4], ["x": -0.1, "y": 0.2, "width": 0.4, "height": 0.4],
                                    ["x": 0.2, "y": 0.2, "width": 1.5, "height": 0.4], [0.25, 0.1, 0.75, 0.5],
                                    ["x": 0.2, "y": 0.2, "width": 0.4], "the head"]
            for value in bad {
                let (code, param) = try await refusal(try Self.part(["subject_box": value]))
                #expect(code == "invalid_request" && param == "subject_box", "\(value): \(code)")
            }
            // Routed by the gate (Base §6.4 rule 2).
            let boxed = try await client.run(try Self.part())
            #expect(boxed.plan?.model.id == "mock-hairdeck")
            let found = try await client.run(try Self.part([:]))
            #expect(found.outcome == .succeeded && found.plan?.model.id == "mock-part-finder", "\(found.error?.message ?? "")")
            #expect(found.result?.effective["subject_box"] == nil && found.result?.effective["physics"] == false)
            #expect(found.result?.meshes.first?.joints == 1)
            // Named: never substituted (rule 3).
            #expect(try await refusal(try Self.part([:], model: "mock-hairdeck")) == ("unsupported_parameter", "subject_box"))
            #expect(try await refusal(try Self.part(model: "mock-part-finder")) == ("unsupported_parameter", "subject_box"))
        }
    }

    @Test("Gates and parameters: physics, texture and part by the offer; a placement or a face cap isn't a part's parameter")
    func gates() async throws {
        try await app().test(.live) { client in
            func code(_ r: JobRequest) async throws -> String { try client.errorCode(try await client.post("/jobs", r)) }
            #expect(try await code(try Self.part(["physics": true], model: "mock-part-finder")) == "unsupported_parameter")
            #expect(try await code(try Self.part(["texture": "none"], model: "mock-part-finder")) == "unsupported_parameter")
            #expect(try await code(try Self.part(["subject_box": Self.box, "texture": "vertex_colors"])) == "out_of_limits")
            #expect(try await code(try Self.part(["subject_box": Self.box, "part": "garment"])) == "out_of_limits")
            for name in ["placement", "size_m", "on_flat", "max_faces", "texture_size", "resolution", "background"] {
                let value: JSONValue = ["placement": "grounded", "on_flat": "fail", "background": "keep"][name] ?? 1024
                #expect(try await code(try Self.part(["subject_box": Self.box, name: value])) == "unsupported_parameter", "\(name)")
            }
            // physics: true with no box and no model named: no offer both makes springs and finds the part.
            #expect(try await code(try Self.part(["physics": true])) == "unsupported_parameter")
            var noBody = try Self.part()
            noBody.inputs?["body"] = nil
            #expect(try await code(noBody) == "invalid_request")
        }
    }

    @Test("Rules without a server: every gate of §4.1, an optional box, and the defaults a request leaves to its offer")
    func rules() throws {
        let d = MockMeshEngine.descriptor("mesh.generate_part")
        func offer(_ supports: [String: JSONValue]) -> ModelOffer {
            ModelOffer(id: "m", title: "M", license: .apache2, memoryClass: .small, speedClass: .fast, qualityTiers: [.standard],
                       supports: supports)
        }
        func admits(_ params: [String: JSONValue], _ supports: [String: JSONValue]) -> Bool {
            let r = JobRequest(operation: "mesh.generate_part", params: params)
            return MeshProfileRules.requirements(r, descriptor: d).allSatisfy { $0.admits(offer(supports)) }
        }
        let box = Self.box
        #expect(admits(["subject_box": box], ["parts": ["hair"], "subject_box": "optional"]))
        #expect(admits([:], ["parts": ["hair"], "subject_box": "optional"]))
        #expect(admits(["subject_box": box], ["parts": ["hair"], "subject_box": "required"]))
        #expect(!admits([:], ["parts": ["hair"], "subject_box": "required"]))
        #expect(!admits(["subject_box": box], ["parts": ["hair"]]))
        #expect(admits(["physics": false], ["parts": ["hair"]]) && !admits(["physics": true], ["parts": ["hair"]]))
        #expect(admits(["physics": true], ["parts": ["hair"], "physics": true]))
        #expect(admits(["part": "hair"], ["parts": ["hair"]]) && !admits(["part": "x-acme.horns"], ["parts": ["hair"]]))
        #expect(admits(["part": "x-acme.horns"], ["parts": ["hair", "x-acme.horns"]]) && !admits(["part": "hair"], [:]))
        #expect(admits(["texture": "atlas"], ["parts": ["hair"]]) && !admits(["texture": "none"], ["parts": ["hair"]]))
        #expect(admits(["texture": "none"], ["parts": ["hair"], "textures": ["atlas", "none"]]))

        let full = offer(["parts": ["x-acme.horns", "hair"], "physics": true, "textures": ["none", "atlas"]])
        let left = MeshProfileRules.partDefaults(JobRequest(operation: "mesh.generate_part"), model: full)
        #expect(left.part == "x-acme.horns" && left.physics && left.texture == "none")
        let asked = MeshProfileRules.partDefaults(JobRequest(operation: "mesh.generate_part", params: ["part": "hair", "physics": false, "texture": "atlas"]),
                                                  model: full)
        #expect(asked.part == "hair" && !asked.physics && asked.texture == "atlas")
        let bare = MeshProfileRules.partDefaults(JobRequest(operation: "mesh.generate_part"), model: offer(["parts": ["hair"]]))
        #expect(bare.part == "hair" && !bare.physics && bare.texture == "atlas")

        // The structure check runs ahead of the schema, and only for a part.
        #expect(throws: MESError.self) {
            try ProfileRules.validateStructure(JobRequest(operation: "mesh.generate_part", params: ["subject_box": ["x": 0.9, "y": 0, "width": 0.2, "height": 1]]),
                                               descriptor: d)
        }
        try ProfileRules.validateStructure(JobRequest(operation: "mesh.generate_part", params: ["subject_box": box]), descriptor: d)
        try ProfileRules.validateStructure(JobRequest(operation: "mesh.generate", params: ["subject_box": "x"]), descriptor: MockMeshEngine.descriptor("mesh.generate"))
        // texture_size goes with an atlas alone.
        #expect(throws: MESError.self) {
            try MeshProfileRules.validate(JobRequest(operation: "mesh.generate", params: ["texture": "none", "texture_size": 512]),
                                          descriptor: MockMeshEngine.descriptor("mesh.generate"))
        }
    }

    @Test("The kit checks only a placed result for flatness: a flat generate is warned, the same flat file from a part or a rig is not")
    func flatOnlyWherePlaced() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mesh-part-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("card.glb")
        let card = GLB.mesh(positions: [[-0.5, 0, 0], [0.5, 0, 0], [0, 1, 0]], normals: Array(repeating: [0, 0, 1], count: 3), indices: [0, 1, 2],
                            colors: Array(repeating: [1, 1, 1, 1], count: 3))
        try card.data().write(to: file)
        let model = MockMeshEngine.partModels[0]
        func warnings(_ operation: String, _ params: [String: JSONValue] = [:]) throws -> [String] {
            try MeshProfileRules.finish([.mesh(file)], request: JobRequest(operation: operation, params: params), model: model).1.map(\.code)
        }
        #expect(try warnings("mesh.generate") == ["flat_result"])
        #expect(try warnings("mesh.generate_part").isEmpty && warnings("mesh.rig").isEmpty)
        // on_flat means nothing to a part, even if one reached the kit.
        #expect(try warnings("mesh.generate_part", ["on_flat": "fail"]).isEmpty)
        #expect(throws: MESError.self) { try warnings("mesh.generate", ["on_flat": "fail"]) }
    }

    @Test("The body and the picture: not a GLB, or no head bone, is input_invalid; an opaque picture is cut out or refused; a turned head is followed")
    func inputs() async throws {
        try await app().test(.live) { client in
            let notGLB = try await client.run(try Self.part(body: Data("not a glb".utf8)))
            #expect(notGLB.outcome == .failed && notGLB.error?.code == "input_invalid" && notGLB.error?.param == "body")
            // A sphere has no bones.
            let boneless = try await client.run(try Self.part(body: try MockMeshEngine.sphereGLB()))
            #expect(boneless.outcome == .failed && boneless.error?.code == "input_invalid" && boneless.error?.param == "body")

            let cut = try await client.run(try Self.part(transparent: false))
            #expect(cut.outcome == .succeeded && cut.result?.effective["background"] == "remove", "\(cut.error?.message ?? "")")
            let refused = try await client.run(try Self.part([:], model: "mock-part-finder", transparent: false))
            #expect(refused.outcome == .failed && refused.error?.code == "unsupported_parameter" && refused.error?.param == "image")

            // A body that isn't a VRM, whose head is found by name, moved and turned a quarter about Y: the part's root
            // joint has the head's place and turn, and the card lies in the head's own plane (now the YZ plane).
            var body = GLB()
            body.append("nodes", ["name": "Armature", "translation": [2, 0, -1], "children": [1]])
            body.append("nodes", ["name": "mixamorig:Head", "translation": [0, 1.5, 0], "rotation": [0, 0.7071067811865476, 0, 0.7071067811865476]])
            body.append("scenes", ["nodes": [0]])
            let turned = try await client.run(try Self.part(body: try body.data()))
            #expect(turned.outcome == .succeeded, "\(turned.error?.message ?? "")")
            let mesh = try #require(turned.result?.meshes.first)
            let glb = try GLB(data: Data(buffer: try await client.get("/jobs/\(turned.id)/outputs/\(mesh.index)").body))
            #expect(glb.object("nodes", 0)?["name"] == "mixamorig:Head")
            let root = glb.worldMatrix(node: 0), expected = body.worldMatrix(node: 1)
            #expect(zip(root, expected).allSatisfy { abs($0 - $1) < 1e-6 }, "\(root) vs \(expected)")
            let b = try #require(mesh.bounds)
            #expect(abs(b.center[0] - 2) < 1e-4 && b.extents[0] < 1e-4 && b.extents[2] > 0.03 && abs(b.min[1] - 1.6) < 1e-4, "\(b)")
            // The skin binds each vertex where it is: skinning the bind pose gives the positions back.
            let ibm = try glb.floats(accessor: glb.array("skins")[0]["inverseBindMatrices"]!.intValue!)
            for (j, m) in ibm.enumerated() {
                let world = glb.worldMatrix(node: j), inverse = m.map(Double.init)
                let product = Matrix.multiply(world, inverse)
                #expect(zip(product, Matrix.identity).allSatisfy { abs($0 - $1) < 1e-5 }, "joint \(j)")
            }
        }
    }
}
