import Foundation
@testable import MESConformance
import MESCore
import MESEngineCore
import MESEngineKit
@testable import MockEngineCore
import Testing

// RFC 0009 in the conformance suite: MESH-013 to MESH-018 run and pass on the mock's two part offers, with every branch
// taken; and an engine that places a part as it would a `mesh.generate` result (centred, scaled to 1 m under a root
// node) fails exactly the tests that say a part stays on its body.

/// A part engine that treats its result as an object: it centres the part on the origin and scales its longest extent to
/// 1 m with a root node over the scene, as an engine does for `mesh.generate` (Mesh §1.4). MESH-013 and MESH-014 must
/// catch it.
struct PlacedPartEngine: MediaEngine {
    let mock = MockMeshEngine()
    func descriptors() async -> [Descriptor] { [MockMeshEngine.descriptor("mesh.generate_part")] }

    func run(_ context: RunContext) async throws -> RunOutput {
        var output = try await mock.run(context)
        for (i, produced) in output.outputs.enumerated() where produced.kind == .mesh {
            guard let file = produced.file else { continue }
            var glb = try GLB(data: Data(contentsOf: file))
            let (scale, offset) = MeshProfile.placement(try glb.facts().bounds, grounded: false, size: 1)
            let sceneIndex = glb.json["scene"]?.intValue ?? 0
            guard var scene = glb.object("scenes", sceneIndex) else { continue }
            let root = glb.append("nodes", ["name": "mes_placement", "children": scene["nodes"] ?? [],
                                            "scale": .array([scale, scale, scale].map { .number($0) }),
                                            "translation": .array(offset.map { .number($0) })])
            scene["nodes"] = [.number(Double(root))]
            glb.set("scenes", sceneIndex, scene)
            try glb.data().write(to: file)
            output.outputs[i] = .mesh(file)                      // the kit reads the placed file's facts
        }
        return output
    }
}

@Suite("RFC 0009 in the conformance suite: a part made to fit a body", .serialized)
struct MeshPartConformanceTests {
    static let mesh = Set((1...18).map { String(format: "MESH-%03d", $0) })

    @Test("The mock passes MESH-013 to MESH-018, with both offers and every branch")
    func mockPasses() async throws {
        try await serve(mockConfig(), engine: MockMeshEngine()) { port in
            let probe = try await Probe.connect(Wire(baseURL: URL(string: "http://127.0.0.1:\(port)/mes/v0")!))
            #expect(probe.bodyFixture != nil && probe.meshFixture != nil)
            let report = await ConformanceRunner.run(probe, only: Self.mesh)
            #expect(report.failed == 0, "\(failures(report))")
            #expect(report.results.filter { $0.status != .pass }.isEmpty, "\(report.results.filter { $0.status != .pass }.map(\.id))")
            #expect(report.results.count == 18 && report.conformsToMesh == true)
            let notes = Dictionary(uniqueKeysWithValues: report.results.map { ($0.id, $0.detail ?? "") })
            #expect(notes["MESH-013"]?.contains("mock-hairdeck: y 1.48 to 1.64 m") == true, "\(notes["MESH-013"] ?? "")")
            #expect(notes["MESH-014"] == "mock-hairdeck: 4 joints under J_Bip_C_Head; mock-part-finder: 1 joints under J_Bip_C_Head")
            #expect(notes["MESH-015"] == "mock-hairdeck: springs on and off; mock-part-finder refused physics")
            #expect(notes["MESH-016"] == "mock-hairdeck: untextured; mock-hairdeck refused vertex_colors; mock-part-finder refused none"
                    || notes["MESH-016"]?.contains("mock-hairdeck: untextured") == true, "\(notes["MESH-016"] ?? "")")
            #expect(notes["MESH-017"] == "mock-hairdeck: box required, echoed, five bad boxes 400; mock-part-finder refused a box")
            #expect(notes["MESH-018"] == "mock-hairdeck cut out an opaque picture; mock-part-finder refused an opaque picture")
            // The shared tests reach the new operation too.
            #expect(notes["MESH-003"]?.contains("mock-hairdeck: 6 vertices, 4 faces, 8 px texture, 4 joints") == true, "\(notes["MESH-003"] ?? "")")
            #expect(notes["MESH-009"]?.contains("mock-hairdeck: \"Built with Mock DINOv3\"") == true, "\(notes["MESH-009"] ?? "")")
        }
    }

    @Test("The minimal request for a part: the cut-out ball, the body, and the ball's box; Base's picture carrier prefers another operation")
    func minimalRequest() async throws {
        try await serve(mockConfig(), engine: MockMeshEngine()) { port in
            let probe = try await Probe.connect(Wire(baseURL: URL(string: "http://127.0.0.1:\(port)/mes/v0")!))
            let d = try #require(probe.descriptor("mesh.generate_part"))
            let request = try #require(probe.minimalRequest(d))
            #expect(Set(request.inputs?.keys.map { $0 } ?? []) == ["image", "body"])
            #expect(SubjectBox(request.params?["subject_box"]) == Fixtures.ballBox)
            let job = try await probe.succeed(request)
            #expect(job.plan?.model.id == "mock-hairdeck" && job.result?.effective["background"] == "alpha")
            await probe.confirm(job)
            #expect(probe.imageCarrier?.descriptor.operation == "mesh.generate")
            let body = try GLB(data: try Fixtures.body())
            let facts = try body.facts()
            #expect(abs(facts.bounds.max[1] - 1.57) < 1e-6 && abs(facts.bounds.min[1]) < 1e-6 && facts.joints == 52)
            #expect(body.bodyBone(for: "hair")?.name == "J_Bip_C_Head" && body.humanoidBone("leftIndexIntermediate") != nil)
            #expect(body.array("meshes").compactMap { $0["name"]?.stringValue } == ["Body", "Face"])
        }
        // With a part alone on offer, it carries Base's picture tests, with the cut-out ball.
        try await serve(mockConfig(), engine: PlacedPartEngine()) { port in
            let probe = try await Probe.connect(Wire(baseURL: URL(string: "http://127.0.0.1:\(port)/mes/v0")!))
            let carrier = try #require(probe.imageCarrier)
            #expect(carrier.descriptor.operation == "mesh.generate_part" && carrier.input == "image" && carrier.image == Fixtures.ball(transparent: true))
        }
    }

    @Test("An engine that centres and scales a part fails MESH-013 and MESH-014, and nothing else")
    func catchesAPlacedPart() async throws {
        try await serve(mockConfig(), engine: PlacedPartEngine()) { port in
            let probe = try await Probe.connect(Wire(baseURL: URL(string: "http://127.0.0.1:\(port)/mes/v0")!))
            let report = await ConformanceRunner.run(probe, only: Self.mesh)
            let failed = Set(report.results.filter { $0.status == .fail }.map(\.id))
            #expect(failed == ["MESH-013", "MESH-014"], "\(failures(report))")
            #expect(report.conformsToMesh == false)
            let detail = Dictionary(uniqueKeysWithValues: report.results.map { ($0.id, $0.detail ?? "") })
            #expect(detail["MESH-013"]?.contains("moved or scaled") == true, "\(detail["MESH-013"] ?? "")")
            #expect(detail["MESH-014"]?.contains("from the body's head bone") == true, "\(detail["MESH-014"] ?? "")")
        }
    }
}
