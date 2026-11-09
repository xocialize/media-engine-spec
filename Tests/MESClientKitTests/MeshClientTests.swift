import Foundation
import MESClientKit
import MESCore
import MESInProcess
import MockEngineCore
import Testing

// Mesh 0.1 for clients: a mesh job's GLB and preview downloaded together, the facts on the output, and the attribution
// in provenance (RFC 0007).

@Suite("MESClientKit: meshes", .serialized)
struct MeshClientTests {
    @Test("downloadMesh fetches the GLB and its preview; the file's facts agree with the output's")
    func downloadMesh() async throws {
        let engine = try await InProcessEngine.start(engine: MockMediaEngine(), configuration: freshConfig())
        let image = FileManager.default.temporaryDirectory.appendingPathComponent("mesh-client-\(UUID().uuidString).png")
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAQAAAACCAYAAAB/qH1jAAAAEUlEQVR4nGP4z8DwHwyZGBgAP/0D/fVg4DkAAAAASUVORK5CYII=")!
        try png.write(to: image)
        defer { try? FileManager.default.removeItem(at: image) }
        let job = try await engine.run(JobRequest(operation: "mesh.generate", inputs: ["image": .one(.inline(mediaType: "image/png", data: png))],
                                                  params: ["max_faces": 320, "texture": "vertex_colors"]))
        #expect(job.outcome == .succeeded)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mesh-client-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try #require(try await engine.downloadMesh(job, to: dir))
        #expect(files.mesh.pathExtension == "glb" && files.preview?.pathExtension == "png")
        let facts = try GLB(data: Data(contentsOf: files.mesh)).facts()
        let out = try #require(job.result?.meshes.first)
        #expect(out.faces == facts.faces && out.vertices == facts.vertices && out.textureSize == nil && facts.hasVertexColors)
        #expect(job.result?.provenance.model.license.attribution == "Built with Mock DINOv3")
        #expect(MediaType.infer(files.mesh) == "model/gltf-binary")
        let noMesh = Job(id: "j", operation: "image.generate", state: .holding, retention: .init(recordExpiresAt: Date()), createdAt: Date(), updatedAt: Date())
        #expect(try await engine.downloadMesh(noMesh, to: dir) == nil)
        await engine.stop()
    }
}
