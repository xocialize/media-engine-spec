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

    @Test("A part for a body (RFC 0009): the body sent from a .vrm file as an asset, the part downloaded with its preview")
    func partFromAVRM() async throws {
        let engine = try await InProcessEngine.start(engine: MockMediaEngine(), configuration: freshConfig())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("part-client-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let avatar = dir.appendingPathComponent("avatar.vrm")
        try MockMeshEngine.bodyGLB().write(to: avatar)
        // The system has no type for .vrm; a VRM is a GLB (Mesh §3.3).
        #expect(MediaType.infer(avatar) == "model/gltf-binary" && MediaType.infer(URL(fileURLWithPath: "/x/Avatar.VRM")) == "model/gltf-binary")
        // Uploaded once as an asset, the body serves every part made for it (Base §8.1).
        let body = try await engine.createAsset(contentsOf: avatar, mediaType: nil, ttl: .seconds(600))
        #expect(body.mediaType == "model/gltf-binary")
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAQAAAACCAYAAAB/qH1jAAAAEUlEQVR4nGP4z8DwHwyZGBgAP/0D/fVg4DkAAAAASUVORK5CYII=")!
        var jobs: [Job] = []
        for seed in [1, 2] {
            jobs.append(try await engine.run(JobRequest(
                operation: "mesh.generate_part",
                inputs: ["image": .one(.inline(mediaType: "image/png", data: png)), "body": .one(.asset(body.assetID))],
                params: ["subject_box": SubjectBox(x: 0.25, y: 0, width: 0.5, height: 1).json, "seed": .number(Double(seed))])))
        }
        #expect(jobs.allSatisfy { $0.outcome == .succeeded }, "\(jobs.compactMap { $0.error?.message })")
        let job = jobs[0]
        #expect(job.plan?.model.id == "mock-hairdeck" && job.result?.effective["part"] == "hair")
        let out = try #require(job.result?.meshes.first)
        #expect(out.joints == 4 && job.result?.preview(for: out) != nil)
        let files = try #require(try await engine.downloadMesh(job, to: dir))
        let glb = try GLB(data: Data(contentsOf: files.mesh))
        #expect(try glb.facts().joints == 4 && glb.json["extensionsUsed"] == ["VRMC_springBone"])
        #expect(glb.asset["copyright"]?.stringValue?.contains("Built with Mock DINOv3") == true)
        // The two seeds lean the card differently: two parts for one body.
        #expect(jobs[0].result?.meshes.first?.sha256 != jobs[1].result?.meshes.first?.sha256)
        await engine.stop()
    }
}
