import Foundation
@testable import MESCore
import Testing

// RFC 0009 in MESCore: `mesh.generate_part` in the bundled table and vocabulary, the box as a value, and finding the bone
// of a body a part hangs from.

@Suite("MESCore: a part made to fit a body (RFC 0009)")
struct MeshPartCoreTests {
    @Test("The table has mesh.generate_part: image and body in, mesh and preview out, never placed")
    func table() throws {
        let op = try #require(MeshProfile.operations.operations["mesh.generate_part"])
        #expect(op.inputs["image"]?.kind == .image && op.inputs["image"]?.required == true)
        #expect(op.inputs["body"]?.kind == .mesh && op.inputs["body"]?.required == true)
        #expect(op.outputs["mesh"]?.kind == .mesh && op.outputs["preview"]?.kind == .image)
        #expect(op.vocabulary == ["part", "subject_box", "physics", "texture", "seed", "quality"])
        #expect(op.fitsBody == true && op.places == nil && op.keepsGeometry == nil && op.seeded == true)
        #expect(MeshProfile.operations.operations["mesh.generate"]?.fitsBody == nil)
        for name in ["placement", "size_m", "on_flat", "max_faces", "texture_size", "resolution", "background"] {
            #expect(!op.vocabulary.contains(name), "\(name) is not a part's parameter")
        }
    }

    @Test("Vocabulary: texture gains none; part, subject_box and physics are defined; hair is the registered part")
    func vocabulary() {
        #expect(MeshProfile.vocabulary["$defs"]?["texture"]?["enum"] == .array(MeshProfile.textures.map { .string($0) }))
        #expect(MeshProfile.textures == ["atlas", "vertex_colors", "none"] && MeshProfile.noTexture == "none")
        #expect(MeshProfile.parts == ["hair"] && MeshProfile.Part.hair == "hair")
        #expect(MeshProfile.humanoidBone(part: "hair") == "head" && MeshProfile.humanoidBone(part: "garment") == nil)
        let box = MeshProfile.vocabularySchema("subject_box", operation: "mesh.generate_part")
        #expect(box?["required"] == ["x", "y", "width", "height"] && box?["additionalProperties"] == false)
        #expect(MeshProfile.vocabularySchema("physics", operation: "mesh.generate_part")?["type"] == "boolean")
        #expect(MeshProfile.SubjectBoxSupport(rawValue: "required") == .required && MeshProfile.SubjectBoxSupport(rawValue: "yes") == nil)
        #expect(MeshProfile.Param.subjectBox == "subject_box" && MeshProfile.SupportsKey.subjectBox == "subject_box")
        #expect(MeshProfile.Input.body == "body" && MeshProfile.springBoneExtension == "VRMC_springBone")
    }

    @Test("SubjectBox: four numbers and nothing else; some area; inside the image; its pixels round outwards")
    func subjectBox() throws {
        let box = try #require(SubjectBox(["x": 0.25, "y": 0.1, "width": 0.5, "height": 0.4]))
        #expect(box == SubjectBox(x: 0.25, y: 0.1, width: 0.5, height: 0.4) && box.problem == nil)
        #expect(SubjectBox(box.json) == box)
        // Gaea's example (AB-A-0278): on 640 × 960 this box is [160, 96, 480, 480].
        let px = box.pixels(width: 640, height: 960)
        #expect(px.x0 == 160 && px.y0 == 96 && px.x1 == 480 && px.y1 == 480)
        let odd = SubjectBox(x: 0.333, y: 0.333, width: 0.334, height: 0.667).pixels(width: 10, height: 10)
        #expect(odd.x0 == 3 && odd.y0 == 3 && odd.x1 == 7 && odd.y1 == 10)
        let sliver = SubjectBox(x: 0.999, y: 0.999, width: 0.001, height: 0.001).pixels(width: 8, height: 8)
        #expect(sliver.x0 == 7 && sliver.x1 == 8 && sliver.y0 == 7 && sliver.y1 == 8)
        #expect(SubjectBox(x: 0, y: 0, width: 1, height: 1).problem == nil)
        #expect(SubjectBox(x: 0.6, y: 0.1, width: 0.6, height: 0.4).problem != nil)
        #expect(SubjectBox(x: 0.1, y: 0.7, width: 0.4, height: 0.4).problem != nil)
        #expect(SubjectBox(x: 0.2, y: 0.2, width: 0, height: 0.4).problem != nil)
        #expect(SubjectBox(x: -0.1, y: 0.2, width: 0.4, height: 0.4).problem != nil)
        #expect(SubjectBox(x: 0.7, y: 0.7, width: 0.3, height: 0.3 + 1e-12).problem == nil)
        #expect(SubjectBox([0.25, 0.1, 0.75, 0.5]) == nil && SubjectBox(["x": 0, "y": 0, "width": 1]) == nil)
        #expect(SubjectBox(["x": 0, "y": 0, "width": 1, "height": 1, "unit": "px"]) == nil && SubjectBox(nil) == nil)
        #expect(SubjectBox(["x": "0", "y": 0, "width": 1, "height": 1]) == nil)
        #expect(SubjectBox.problem([0.1, 0.2]) != nil && SubjectBox.problem(box.json) == nil)
    }

    /// A three-node body: a root moved up 1 m, hips under it, and a head 0.5 m above the hips, turned a quarter about Y.
    func body(_ extensions: JSONValue?, headName: String = "J_Bip_C_Head") -> GLB {
        var g = GLB()
        g.append("nodes", ["name": "Root", "translation": [0, 1, 0], "children": [1]])
        g.append("nodes", ["name": "J_Bip_C_Hips", "children": [2]])
        g.append("nodes", ["name": .string(headName), "translation": [0, 0.5, 0], "rotation": [0, 0.7071067811865476, 0, 0.7071067811865476]])
        g.append("scenes", ["nodes": [0]])
        if let extensions { g.json["extensions"] = extensions }
        return g
    }

    @Test("The body's bone for hair: VRM 1.0's humanoid head, VRM 0.x's, else a node whose name ends in head; its place at rest")
    func bodyBone() throws {
        let v1 = body(["VRMC_vrm": ["humanoid": ["humanBones": ["head": ["node": 2], "hips": ["node": 1]]]]], headName: "Atama")
        #expect(v1.humanoidBone("head") == 2 && v1.humanoidBone("hips") == 1 && v1.humanoidBone("jaw") == nil)
        let bone = try #require(v1.bodyBone(for: "hair"))
        #expect(bone.node == 2 && bone.name == "Atama")
        #expect(abs(bone.world[12]) < 1e-9 && abs(bone.world[13] - 1.5) < 1e-9 && abs(bone.world[14]) < 1e-9)
        // A quarter turn about Y takes +X to −Z.
        #expect(abs(bone.world[0]) < 1e-9 && abs(bone.world[2] + 1) < 1e-9)

        let v0 = body(["VRM": ["humanoid": ["humanBones": [["bone": "hips", "node": 1], ["bone": "head", "node": 2]]]]], headName: "Atama")
        #expect(v0.bodyBone(for: "hair")?.node == 2)
        #expect(body(nil).bodyBone(for: "hair")?.name == "J_Bip_C_Head")
        #expect(body(nil, headName: "mixamorig:Head").bodyBone(for: "hair")?.node == 2)
        #expect(body(nil, headName: "Atama").bodyBone(for: "hair") == nil)
        // A part the profile doesn't register hangs from no bone it knows.
        #expect(v1.bodyBone(for: "garment") == nil)
        #expect(v1.worldMatrix(node: 0)[13] == 1 && v1.worldMatrix(node: 9) == Matrix.identity)
    }
}
