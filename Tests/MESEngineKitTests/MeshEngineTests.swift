import Foundation
import Hummingbird
import HummingbirdTesting
@testable import MESCore
@testable import MESEngineKit
@testable import MockEngineCore
import Testing

// Mesh 0.1 and RFC 0007 in the kit: MeshProfileRules (400s, gates, limits), the facts the kit reads from a GLB, the
// flatness check (warning, or 422 degenerate_result), the mock's warnings, and attribution on MCP model lines, against the
// mock mesh engine over HTTP.

@Suite("Mesh 0.1 in the kit")
struct MeshEngineTests {
    func app(_ engine: some MediaEngine = MockMeshEngine()) async throws -> some ApplicationProtocol {
        try await MESEngineServer(engine: engine, configuration: freshConfig()).makeApplication()
    }

    static func image(transparent: Bool = false) -> RequestInput {
        let size = 64
        var px = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0..<size { for x in 0..<size {
            let i = (y * size + x) * 4, inside = (x - 32) * (x - 32) + (y - 32) * (y - 32) < 400
            if inside { px[i] = 200; px[i + 1] = 30; px[i + 2] = 30 } else if transparent { px[i] = 0; px[i + 1] = 0; px[i + 2] = 0; px[i + 3] = 0 }
        } }
        return .one(.inline(mediaType: "image/png", data: try! Raster(width: size, height: size, pixels: px).pngData()))
    }

    static func generate(_ params: [String: JSONValue] = [:], model: String? = nil, extensions: [String: JSONValue]? = nil,
                         transparent: Bool = false) -> JobRequest {
        JobRequest(operation: "mesh.generate", inputs: ["image": image(transparent: transparent)], params: params, model: model,
                   extensions: extensions)
    }

    @Test("generate: outputs a GLB whose facts the kit reports, a preview, placement and effective as asked; the job validates")
    func generate() async throws {
        try await app().test(.live) { client in
            let job = try await client.run(Self.generate(["max_faces": 1280, "placement": "grounded", "size_m": 1.8, "texture_size": 512, "seed": 4]))
            #expect(job.outcome == .succeeded && job.plan?.model.id == "mock-trellis", "\(job.error?.message ?? "")")
            let mesh = try #require(job.result?.meshes.first)
            #expect(mesh.mediaType == "model/gltf-binary" && mesh.faces == 1280 && mesh.vertices == 642 && mesh.textureSize == 512 && mesh.joints == nil)
            let b = try #require(mesh.bounds)
            #expect(abs(b.min[1]) < 1e-4 && abs((b.extents.max() ?? 0) - 1.8) < 1e-3)
            #expect(job.result?.preview(for: mesh)?.width == 512)
            let eff = job.result?.effective ?? [:]
            #expect(eff["placement"] == "grounded" && eff["size_m"] == 1.8 && eff["texture"] == "atlas" && eff["texture_size"] == 512
                    && eff["max_faces"] == 1280 && eff["resolution"] == 1024 && eff["seed"] == 4 && eff["background"] == "remove")
            #expect(job.result?.provenance.model.license.attribution == "Built with Mock DINOv3")
            #expect(conforms(try await client.get("/jobs/\(job.id)").body, to: "base/job.schema.json").isEmpty)
            let file = try await client.get("/jobs/\(job.id)/outputs/\(mesh.index)")
            let glb = try GLB(data: Data(buffer: file.body))
            #expect(glb.problems().isEmpty && glb.mesExtras["ai_generated"] == true && glb.asset["copyright"]?.stringValue?.contains("Built with Mock DINOv3") == true)
        }
    }

    @Test("Rules: 400 for texture_size with vertex colours; 422 for gates (background, resolution, texture, texture_size) and limits (faces)")
    func rules() async throws {
        try await app().test(.live) { client in
            func code(_ r: JobRequest) async throws -> String { try client.errorCode(try await client.post("/jobs", r)) }
            #expect(try await code(Self.generate(["texture": "vertex_colors", "texture_size": 512])) == "invalid_request")
            #expect(try await code(Self.generate(["background": "remove"], model: "mock-mesh-open")) == "unsupported_parameter")
            #expect(try await code(Self.generate(["resolution": 512], model: "mock-mesh-open")) == "unsupported_parameter")
            #expect(try await code(Self.generate(["texture": "atlas"], model: "mock-mesh-open")) == "unsupported_parameter")
            #expect(try await code(Self.generate(["texture_size": 512], model: "mock-mesh-open")) == "unsupported_parameter")
            #expect(try await code(Self.generate(["max_faces": 150], model: "mock-mesh-open")) == "out_of_limits")
            #expect(try await code(Self.generate(["max_faces": 5000], model: "mock-mesh-open")) == "out_of_limits")
            // Unnamed, the request implies the offer that admits it (Base §6.4 rule 2).
            let open = try await client.run(Self.generate(["max_faces": 150, "quality": "draft"]))
            #expect(open.plan?.model.id == "mock-trellis")
            let rig = JobRequest(operation: "mesh.rig", inputs: ["mesh": .one(.inline(mediaType: "model/gltf-binary", data: try MockMeshEngine.sphereGLB()))],
                                 model: "mock-template-rigger")
            #expect(try await code(rig) == "unsupported_parameter")
        }
    }

    @Test("Flat results: warned flat_result by default; with on_flat fail the job fails input_invalid, reason degenerate_result")
    func flat() async throws {
        try await app().test(.live) { client in
            let warned = try await client.run(Self.generate(["max_faces": 320], extensions: ["x-mock.flat": true]))
            #expect(warned.outcome == .succeeded && warned.warnings.map(\.code).contains("flat_result"))
            #expect((warned.result?.meshes.first?.bounds?.thinness ?? 1) < MeshProfile.flatRatio)
            let failed = try await client.run(Self.generate(["max_faces": 320, "on_flat": "fail"], extensions: ["x-mock.flat": true]))
            #expect(failed.outcome == .failed && failed.error?.code == "input_invalid" && failed.error?.reason == "degenerate_result")
            #expect(failed.error?.message.contains("flat") == true)
            let fine = try await client.run(Self.generate(["max_faces": 320, "on_flat": "fail"]))
            #expect(fine.outcome == .succeeded && !fine.warnings.map(\.code).contains("flat_result"))
        }
    }

    @Test("The mock's warnings: faces_reduced and background_kept on the open offer; a cut-out image is alpha")
    func warnings() async throws {
        try await app().test(.live) { client in
            let open = try await client.run(Self.generate(["quality": "draft"], model: "mock-mesh-open"))
            #expect(Set(open.warnings.map(\.code)) == ["faces_reduced", "background_kept"], "\(open.warnings)")
            #expect((open.result?.meshes.first?.faces ?? 0) <= 1280 && open.result?.meshes.first?.textureSize == nil)
            let cut = try await client.run(Self.generate(["max_faces": 320], transparent: true))
            #expect(cut.result?.effective["background"] == "alpha" && cut.warnings.isEmpty)
        }
    }

    @Test("rig: the geometry kept, a vrm_humanoid skin (fingers dropped by one offer), joints reported; a skinned input is replaced")
    func rig() async throws {
        try await app().test(.live) { client in
            let sphere = try MockMeshEngine.sphereGLB()
            let input = try GLB(data: sphere).facts()
            let job = try await client.run(JobRequest(operation: "mesh.rig", inputs: ["mesh": .one(.inline(mediaType: "model/gltf-binary", data: sphere))],
                                                      params: ["skeleton": "vrm_humanoid"]))
            #expect(job.outcome == .succeeded, "\(job.error?.message ?? "")")
            let mesh = try #require(job.result?.meshes.first)
            #expect(mesh.vertices == input.vertices && mesh.faces == input.faces && mesh.joints == 22 && mesh.textureSize == 64)
            #expect(job.warnings.map(\.code) == ["joints_dropped"])
            let out = try GLB(data: Data(buffer: try await client.get("/jobs/\(job.id)/outputs/\(mesh.index)").body))
            #expect(out.problems().isEmpty && out.mesExtras["rigged_with"] == "Mock SkinTokens")
            let all = try await client.run(JobRequest(operation: "mesh.rig", inputs: ["mesh": .one(.inline(mediaType: "model/gltf-binary",
                                                                                                          data: try out.data()))],
                                                      params: ["skeleton": "vrm_humanoid"], model: "mock-template-rigger"))
            #expect(all.result?.meshes.first?.joints == 52 && all.warnings.map(\.code) == ["skin_replaced"], "\(all.warnings)")
            let auto = try await client.run(JobRequest(operation: "mesh.rig", inputs: ["mesh": .one(.inline(mediaType: "model/gltf-binary", data: sphere))]))
            #expect(auto.result?.meshes.first?.joints == 3)
            let broken = try await client.run(JobRequest(operation: "mesh.rig", inputs: ["mesh": .one(.inline(mediaType: "model/gltf-binary", data: Data("nope".utf8)))]))
            #expect(broken.outcome == .failed && broken.error?.code == "input_invalid")
        }
    }

    @Test("The kit reads a mesh's facts from the GLB when the engine leaves them out, and refuses an unreadable one")
    func kitFacts() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mesh-kit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("m.glb")
        try MockMeshEngine.sphereGLB(faces: 320).write(to: file)
        let request = JobRequest(operation: "mesh.rig")
        let model = MockMeshEngine.models("mesh.rig")[0]
        let (outs, warnings) = try MeshProfileRules.finish([.mesh(file)], request: request, model: model)
        #expect(outs[0].faces == 320 && outs[0].vertices == 162 && outs[0].textureSize == 64 && warnings.isEmpty)
        try Data("x".utf8).write(to: file)
        #expect(throws: MESError.self) { try MeshProfileRules.finish([.mesh(file)], request: request, model: model) }
    }

    @Test("MCP: a model line carries its licence's attribution, verbatim")
    func mcpAttribution() {
        let line = MCPToolbox.modelLine(MockMeshEngine.models("mesh.generate")[0], notes: true)
        #expect(line.contains("attribution: Built with Mock DINOv3"))
    }
}
