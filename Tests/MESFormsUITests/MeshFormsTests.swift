import AppKit
import Foundation
import MESCore
@testable import MESFormsUI
@testable import MockEngineCore
import SceneKit
import SwiftUI
import Testing

// MESFormsUI for Mesh 0.1: the mesh viewer (SceneKit from MESCore's GLB reader, the preview as its fallback), its facts
// line, the mesh input well, and the form for each mock mesh descriptor, rendered offscreen.

@Suite("MESFormsUI: meshes", .serialized)
@MainActor
struct MeshFormsTests {
    func file(_ data: Data, _ ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mesh-forms-\(UUID().uuidString).\(ext)")
        try data.write(to: url)
        return url
    }

    @Test("MeshScene builds a node per primitive with its texture, and a camera")
    func scene() throws {
        let glb = try GLB(data: MockMeshEngine.sphereGLB(faces: 320))
        let scene = try MeshScene.make(glb)
        let nodes = scene.rootNode.childNodes(passingTest: { node, _ in node.geometry != nil })
        #expect(nodes.count == 1)
        #expect(nodes[0].geometry?.elements.first?.primitiveCount == 320)
        #expect(nodes[0].geometry?.materials.first?.diffuse.contents != nil)
        #expect(scene.rootNode.childNodes(passingTest: { node, _ in node.camera != nil }).count == 1)
    }

    @Test("MeshFacts: read from a file, or from an output, in one line")
    func facts() throws {
        let url = try file(MockMeshEngine.sphereGLB(faces: 320), "glb")
        defer { try? FileManager.default.removeItem(at: url) }
        let f = try MeshFacts.read(url)
        #expect(f.faces == 320 && f.vertices == 162 && f.textureSize == 64)
        #expect(f.line.hasPrefix("162 vertices · 320 faces · ") && f.line.contains("64 px texture"))
        let out = Output(index: 0, name: "mesh", kind: .mesh, mediaType: "model/gltf-binary", bytes: 1, sha256: "", href: "",
                         vertices: 8, faces: 12, bounds: MeshBounds(min: [0, 0, 0], max: [1, 2, 1]), joints: 22)
        #expect(MeshFacts(out)?.line == "8 vertices · 12 faces · 1 × 2 × 1 m · vertex colours · 22 joints")
    }

    @Test("MeshView, its preview fallback, and the mesh input well render offscreen")
    func views() async throws {
        let glb = try file(MockMeshEngine.sphereGLB(faces: 320), "glb")
        let broken = try file(Data("not a glb".utf8), "glb")
        let preview = try file(try Raster(width: 8, height: 8, fill: (200, 0, 0, 255)).pngData(), "png")
        defer { for u in [glb, broken, preview] { try? FileManager.default.removeItem(at: u) } }
        #expect(render(MeshView(file: glb, title: "Ball", attribution: "Built with Mock DINOv3")).height > 300)
        #expect(render(MeshView(file: broken, preview: preview)).height > 300)
        let spec = InputSpec(name: "mesh", kind: .mesh, required: true, max: 1, mediaTypes: ["model/gltf-binary"])
        #expect(render(MeshInputWell(spec: spec, file: .constant(glb))).height > 300)
        #expect(render(MeshInputWell(spec: spec, file: .constant(nil))).height > 20)
    }

    @Test("Forms render for both mock mesh descriptors, with the attribution on the licence line")
    func forms() async throws {
        for d in await MockMeshEngine().descriptors() {
            let form = OperationFormModel(descriptor: d)
            form.showsAdvanced = true
            #expect(render(OperationForm(form: form)).height > 100, "\(d.operation)")
        }
        #expect(render(LicenseLine(license: MockMeshEngine.attributedLicense)).height > 10)
    }
}
