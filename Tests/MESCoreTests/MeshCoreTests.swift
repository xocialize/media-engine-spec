import Foundation
@testable import MESCore
import Testing

// Mesh 0.1 and RFC 0007 in MESCore: the bundled table and vocabulary, the mesh facts and attribution, the GLB reader and
// writer, and the conventions' helpers.

@Suite("MESCore: Mesh 0.1")
struct MeshCoreTests {
    @Test("The bundled Mesh table and vocabulary are identical to schemas/v0/profiles/mesh")
    func meshTable() throws {
        let canonical = try MESJSON.decoder.decode(ProfileTable.self, from: Data(contentsOf:
            schemas.appendingPathComponent("profiles/mesh/operations.json")))
        #expect(MeshProfile.operations == canonical)
        #expect(MeshProfile.operations.operations.keys.sorted() == ["mesh.generate", "mesh.generate_part", "mesh.rig"])
        #expect(MeshProfile.vocabulary == (try json(schemas.appendingPathComponent("profiles/mesh/vocabulary.schema.json"))))
        #expect(MeshProfile.operations.operations["mesh.generate"]?.places == true)
        #expect(MeshProfile.operations.operations["mesh.rig"]?.keepsGeometry == true)
        #expect(MeshProfile.operations.operations["mesh.generate"]?.outputs["preview"]?.kind == .image)
        #expect(MeshProfile.vocabulary["$defs"]?["texture_size"]?["enum"] == .array(MeshProfile.textureSizes.map { .number(Double($0)) }))
        #expect(MeshProfile.vocabulary["$defs"]?["placement"]?["enum"] == .array(MeshProfile.placements.map { .string($0) }))
        let joints = try #require(MeshProfile.joints(template: "vrm_humanoid"))
        #expect(joints.count == 52 && joints.first == "J_Bip_C_Hips" && Set(joints).count == 52 && joints.contains("J_Bip_R_ToeBase"))
        #expect(MeshProfile.joints(template: "mixamo") == nil)
        #expect(Kind(rawValue: "mesh") == .mesh)
    }

    @Test("License attribution and mesh facts round-trip, and the schema rejects a mesh output without its facts")
    func wireFields() throws {
        let license = License(spdx: "LicenseRef-DINOv3", commercialUse: .yes, attribution: "Built with DINOv3")
        let encoded = try JSONValue(encoding: license)
        #expect(encoded["attribution"] == "Built with DINOv3")
        #expect(try MESJSON.decoder.decode(License.self, from: MESJSON.encoder.encode(license)) == license)
        let bounds = MeshBounds(min: [-0.5, 0, -0.1], max: [0.5, 2, 0.1])
        #expect(bounds.extents == [1, 2, 0.2] && bounds.center == [0, 1, 0] && abs(bounds.thinness - 0.1) < 1e-12)
        #expect(MeshBounds(min: [0, 0, 0], max: [0, 0, 0]).thinness == 0)
        let out = Output(index: 0, name: "mesh", kind: .mesh, mediaType: "model/gltf-binary", bytes: 1, sha256: String(repeating: "a", count: 64),
                         href: "/x", vertices: 8, faces: 12, bounds: bounds, textureSize: 512)
        #expect(out.isMesh && !out.hasAudioTrack)
        let loader = SchemaLoader()
        let (node, url, _) = try schema("base/job.schema.json#/$defs/Output", loader: loader)
        let validator = SchemaValidator(loader: loader)
        #expect(validator.validate(try JSONValue(encoding: out), against: node, in: try #require(loader.load(url)), base: url).isEmpty)
        var bare = out
        bare.bounds = nil
        #expect(!validator.validate(try JSONValue(encoding: bare), against: node, in: try #require(loader.load(url)), base: url).isEmpty)
    }

    static func cube(colors: Bool = true, texture: Data? = nil) -> GLB {
        let p: [[Float]] = [[-0.5, -0.5, 0.5], [0.5, -0.5, 0.5], [0.5, 0.5, 0.5], [-0.5, 0.5, 0.5],
                            [-0.5, -0.5, -0.5], [0.5, -0.5, -0.5], [0.5, 0.5, -0.5], [-0.5, 0.5, -0.5]]
        let idx: [UInt32] = [0, 1, 2, 0, 2, 3, 1, 5, 6, 1, 6, 2, 5, 4, 7, 5, 7, 6, 4, 0, 3, 4, 3, 7, 3, 2, 6, 3, 6, 7, 4, 5, 1, 4, 1, 0]
        let n = p.map { v -> [Float] in let l = (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).squareRoot(); return v.map { $0 / l } }
        if let texture {
            return GLB.mesh(positions: p, normals: n, indices: idx, uvs: p.map { [$0[0] + 0.5, $0[1] + 0.5] }, texture: texture)
        }
        return GLB.mesh(positions: p, normals: n, indices: idx, colors: colors ? p.map { _ in [1, 0, 0, 1] } : nil)
    }

    /// A 4×2 PNG (IHDR only matters to the facts).
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAQAAAACCAYAAAB/qH1jAAAAEUlEQVR4nGP4z8DwHwyZGBgAP/0D/fVg4DkAAAAASUVORK5CYII=")!

    @Test("GLB: a written file reads back with its facts, follows the conventions, and a texture's size is read from its header")
    func glbRoundTrip() throws {
        let data = try Self.cube().data()
        #expect(data.count % 4 == 0 && data.prefix(4) == Data("glTF".utf8))
        let glb = try GLB(data: data)
        #expect(glb.problems().isEmpty, "\(glb.problems())")
        let facts = try glb.facts()
        #expect(facts.vertices == 8 && facts.faces == 12 && facts.textureSize == nil && facts.joints == nil && facts.hasVertexColors)
        #expect(facts.bounds == MeshBounds(min: [-0.5, -0.5, -0.5], max: [0.5, 0.5, 0.5]))
        let textured = try GLB(data: Self.cube(texture: Self.png).data())
        #expect(try textured.facts().textureSize == 4)
        #expect(ImageSize.of(Self.png)! == (4, 2))
        #expect(try glb.floats(accessor: glb.primitives()[0].attributes["COLOR_0"]!).first == [1, 0, 0, 1])
    }

    @Test("GLB: node transforms place vertices in scene space; non-GLB bytes and broken conventions are reported")
    func glbScene() throws {
        var glb = Self.cube()
        glb.set("nodes", 0, ["mesh": 0, "translation": [0, 0.5, 0], "scale": [2, 2, 2]])
        let facts = try GLB(data: glb.data()).facts()
        #expect(facts.bounds == MeshBounds(min: [-1, -0.5, -1], max: [1, 1.5, 1]))
        #expect(throws: GLB.Failure.self) { try GLB(data: Data("not a glb at all".utf8)) }
        glb.json["extensionsRequired"] = ["KHR_draco_mesh_compression"]
        var prims = glb.object("meshes", 0)!
        prims["primitives"] = [["attributes": ["POSITION": 0], "mode": 1]]
        glb.set("meshes", 0, prims)
        let problems = try GLB(data: glb.data()).problems()
        #expect(problems.contains { $0.contains("KHR_draco") } && problems.contains { $0.contains("triangles") }
                && problems.contains { $0.contains("NORMAL") }, "\(problems)")
    }

    @Test("Placement: centred or grounded, the longest extent the asked size")
    func placement() {
        let raw = MeshBounds(min: [1, 1, 1], max: [3, 5, 2])
        let (s, o) = MeshProfile.placement(raw, grounded: false, size: 2)
        #expect(s == 0.5 && o == [-1, -1.5, -0.75])
        let (gs, go) = MeshProfile.placement(raw, grounded: true, size: 1)
        #expect(gs == 0.25 && go[1] == -0.25 && go[0] == -0.5)
    }
}
