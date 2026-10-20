import Foundation
import Hummingbird
import HummingbirdTesting
import MCP
@testable import MESCore
@testable import MESEngineKit
@testable import MockEngineCore
import Testing

// Adapters (Base §6.3, §10), prompt enhancement (Image §1.9) and its preview, image.enhance_prompt (Image §3.1),
// against the mock engine over HTTP and MCP.

@Suite("Adapters and prompt enhancement")
struct PromptsAndAdaptersTests {
    func app(_ config: EngineConfiguration = freshConfig()) async throws -> some ApplicationProtocol {
        try await MESEngineServer(engine: MockImageEngine(), configuration: config).makeApplication()
    }

    static let small: [String: JSONValue] = ["size": ["width": 16, "height": 16], "seed": 5]
    static func reference() throws -> RequestInput {
        .one(.inline(mediaType: "image/png", data: try pngData(width: 8, height: 8) { _, _ in (40, 80, 120, 255) }))
    }

    @Test("An adapter implies its model; provenance lists it with its licence and the strength it ran at")
    func adapterRuns() async throws {
        try await app().test(.live) { client in
            let generate = try decode(Descriptor.self, try await client.get("/operations/image.generate").body)
            let mock = try #require(generate.models.first { $0.id == "mock" })
            #expect(mock.adapters?.map(\.id) == ["mock-style", "mock-research-style", "mock-pose"] && mock.adapterLimit == 2)

            let byDefault = try await client.run(JobRequest(operation: "image.generate", inputs: ["prompt": .text("x")],
                                                            params: Self.small, adapters: [AdapterRequest(id: "mock-style")]))
            #expect(byDefault.outcome == .succeeded && byDefault.plan?.model.id == "mock")
            #expect(byDefault.result?.provenance.adapters == [AdapterRef(id: "mock-style", title: "Mock style",
                                                                         revision: MockImageEngine.adapterRevision, license: .apache2,
                                                                         strength: 1)])
            #expect(byDefault.result?.provenance.model.revision == nil, "the mock pins no model revision")
            let held = try await client.get("/jobs/\(byDefault.id)")
            #expect(conforms(held.body, to: "base/job.schema.json").isEmpty)

            let weaker = try await client.run(JobRequest(operation: "image.generate", inputs: ["prompt": .text("x")], params: Self.small,
                                                         adapters: [AdapterRequest(id: "mock-style", strength: 0.5)]))
            #expect(weaker.result?.provenance.adapters?.first?.strength == 0.5)
            #expect(weaker.result?.outputs.first?.sha256 != byDefault.result?.outputs.first?.sha256, "the strength reached the model")

            let plain = try await client.run(JobRequest(operation: "image.generate", inputs: ["prompt": .text("x")], params: Self.small))
            #expect(plain.result?.provenance.adapters == nil, "no adapters, no field")

            let posed = try await client.run(JobRequest(operation: "image.generate",
                                                        inputs: ["prompt": .text("x"), "references": try Self.reference()],
                                                        params: Self.small, adapters: [AdapterRequest(id: "mock-pose"),
                                                                                       AdapterRequest(id: "mock-style", strength: 2)]))
            #expect(posed.result?.provenance.adapters?.map(\.id) == ["mock-pose", "mock-style"], "in the request's order")
        }
    }

    @Test("Adapter refusals: unknown, on the wrong model, out of range, too many, twice, short of slots, against the policy")
    func adapterRefusals() async throws {
        try await app().test(.live) { client in
            func refused(_ adapters: [AdapterRequest], model: String? = nil, operation: String = "image.generate",
                         inputs: [String: RequestInput] = ["prompt": .text("x")], policy: Policy? = nil) async throws -> (Int, String) {
                let r = try await client.post("/jobs", JobRequest(operation: operation, inputs: inputs, params: operation == "image.generate" ? Self.small : nil,
                                                                  model: model, policy: policy, adapters: adapters))
                #expect(conforms(r.body, to: "base/error.schema.json").isEmpty)
                return (Int(r.status.code), try client.errorCode(r))
            }
            let unknown = try await refused([AdapterRequest(id: "nope")])
            #expect(unknown == (422, "unsupported_parameter"))
            let wrongModel = try await refused([AdapterRequest(id: "mock-style")], model: "mock-research")
            #expect(wrongModel == (422, "unsupported_parameter"), "the named model doesn't list it")
            let elsewhere = try await refused([AdapterRequest(id: "mock-style")], operation: "image.colorize",
                                              inputs: ["image": try Self.reference()])
            #expect(elsewhere == (422, "unsupported_parameter"), "an operation whose offers list no adapters")
            let strong = try await refused([AdapterRequest(id: "mock-style", strength: 2.5)])
            #expect(strong == (422, "out_of_limits"))
            let twice = try await refused([AdapterRequest(id: "mock-style"), AdapterRequest(id: "mock-style", strength: 0.2)])
            #expect(twice == (400, "invalid_request"))
            let tooMany = try await refused([AdapterRequest(id: "mock-style"), AdapterRequest(id: "mock-research-style"),
                                             AdapterRequest(id: "mock-pose")],
                                            inputs: ["prompt": .text("x"), "references": try Self.reference()])
            #expect(tooMany == (422, "out_of_limits"), "max_adapters is 2")
            let unposed = try await refused([AdapterRequest(id: "mock-pose")])
            #expect(unposed == (400, "invalid_request"), "mock-pose's slot is filled from references (Image §1.10)")
            let research = try await refused([AdapterRequest(id: "mock-research-style")], policy: Policy(license: .commercialUse))
            #expect(research == (422, "policy_unmet"), "a non-commercial adapter under commercial-use")
            let allowed = try await client.run(JobRequest(operation: "image.generate", inputs: ["prompt": .text("x")], params: Self.small,
                                                          adapters: [AdapterRequest(id: "mock-research-style")]))
            #expect(allowed.result?.provenance.adapters?.first?.license.commercialUse == .no, "under policy any it runs")
        }
    }

    @Test("Prompt enhancement: auto leaves the mock's prompts alone; on rewrites, warns and names the helper; off sends as typed")
    func promptEnhance() async throws {
        try await app().test(.live) { client in
            let generate = try decode(Descriptor.self, try await client.get("/operations/image.generate").body)
            #expect(generate.params["properties"]?["prompt_enhance"]?["enum"] == ["auto", "on", "off"])

            func run(_ mode: String?, operation: String = "image.generate") async throws -> Job {
                var params: [String: JSONValue] = operation == "image.generate" ? Self.small : ["seed": 5]
                if let mode { params["prompt_enhance"] = .string(mode) }
                let inputs: [String: RequestInput] = operation == "image.generate"
                    ? ["prompt": .text("a lighthouse")] : ["images": try Self.reference(), "instruction": .text("make it dusk")]
                return try await client.run(JobRequest(operation: operation, inputs: inputs, params: params))
            }
            let auto = try await run(nil)
            #expect(auto.warnings.isEmpty && auto.result?.effective["prompt_enhance"] == "auto" && auto.result?.effective["prompt"] == nil)
            #expect(auto.result?.provenance.helpers == nil)

            let on = try await run("on")
            let rewrite = MockImageEngine.enhance("a lighthouse", seed: 5)
            #expect(on.warnings.map(\.code) == ["prompt_rewritten"] && on.warnings.first?.param == "prompt")
            #expect(on.result?.effective["prompt"]?.stringValue == rewrite && on.result?.effective["prompt_enhance"] == "on")
            #expect(on.result?.provenance.helpers == [HelperRef(id: "mock-enhancer", title: "Mock prompt enhancer", license: .apache2,
                                                                  role: "prompt_enhance")])
            #expect(conforms(try await client.get("/jobs/\(on.id)").body, to: "base/job.schema.json").isEmpty)

            let off = try await run("off")
            #expect(off.warnings.isEmpty && off.result?.effective["prompt"] == nil && off.result?.effective["prompt_enhance"] == "off")
            #expect(off.result?.outputs.first?.sha256 == auto.result?.outputs.first?.sha256, "off and auto both ran the prompt as typed")

            let edit = try await run("on", operation: "image.edit")
            #expect(edit.warnings.first?.param == "instruction" && edit.result?.effective["instruction"] != nil)
        }
    }

    @Test("image.enhance_prompt previews the rewrite as data; the rewrite then runs as typed with prompt_enhance off")
    func enhancePromptPreview() async throws {
        try await app().test(.live) { client in
            let d = try decode(Descriptor.self, try await client.get("/operations/image.enhance_prompt").body)
            #expect(d.models.map(\.id) == ["mock-enhancer"] && d.outputs.map(\.name) == ["enhanced"])
            #expect(d.params["properties"]?["target_operation"]?["enum"]?.arrayValue?.contains("image.generate") == true)

            let preview = try await client.run(JobRequest(operation: "image.enhance_prompt", inputs: ["prompt": .text("a lighthouse")],
                                                          params: ["seed": 5]))
            let value = try #require(preview.result?.outputs.first?.value)
            #expect(value == ["prompt": .string(MockImageEngine.enhance("a lighthouse", seed: 5)), "applied": true])
            #expect(preview.result?.effective["target_operation"] == "image.generate" && preview.result?.effective["target_model"] == "mock")
            #expect(preview.result?.provenance.model.id == "mock-enhancer")
            let vocab = schemaRoot.appendingPathComponent("profiles/image/vocabulary.schema.json")
            let doc = try #require(loader.load(vocab))
            #expect(SchemaValidator(loader: loader).validate(value, against: doc["$defs"]!["enhanced_prompt"]!, in: doc, base: vocab).isEmpty)

            let again = try await client.run(JobRequest(operation: "image.enhance_prompt", inputs: ["prompt": .text("a lighthouse")],
                                                        params: ["seed": 5]))
            #expect(again.result?.outputs.first?.value == value, "the same seed reproduces the rewrite")

            let edited = (value["prompt"]?.stringValue ?? "") + ", with gulls"
            let run = try await client.run(JobRequest(operation: "image.generate", inputs: ["prompt": .text(edited)],
                                                      params: ["size": ["width": 16, "height": 16], "prompt_enhance": "off"], model: "mock"))
            #expect(run.warnings.isEmpty && run.result?.effective["prompt"] == nil)

            let badModel = try await client.post("/jobs", JobRequest(operation: "image.enhance_prompt", inputs: ["prompt": .text("x")],
                                                                     params: ["target_model": "nope"]))
            #expect(try client.errorCode(badModel) == "unsupported_parameter")
            let badTarget = try await client.post("/jobs", JobRequest(operation: "image.enhance_prompt", inputs: ["prompt": .text("x")],
                                                                      params: ["target_operation": "image.upscale"]))
            #expect(badTarget.status.code == 422, "the descriptor narrows target_operation to what the engine enhances")
        }
    }

}

// In the serialized MCP suite: MCP clients hold a standalone event stream each, and progress tests need theirs.
extension MCPBindingTests {
    @Test("MCP: the generate tool takes adapters, lists each under its model, and the result names them")
    func mcpAdapters() async throws {
        try await withEngine(freshConfig()) { port in
            let client = try await mcpClient(port: port)
            let (tools, _) = try await client.listTools()
            let generate = try #require(tools.first { $0.name == "image_generate" })
            let adapters = generate.inputSchema.objectValue?["properties"]?.objectValue?["adapters"]
            #expect(adapters?.objectValue?["items"]?.objectValue?["properties"]?.objectValue?["id"]?.objectValue?["enum"]
                    == ["mock-style", "mock-research-style", "mock-pose"])
            let lines = generate.description?.split(separator: "\n").map(String.init) ?? []
            #expect(lines.contains { $0.hasPrefix("mock:") && $0.hasSuffix("· up to 2 adapters") }, "\(lines)")
            #expect(lines.contains("  - adapter mock-pose: Mock pose · ic [pose (image)] · Apache-2.0 · commercial use yes · strength 0–1.5, "
                                   + "default 1 · Notes: Put the pose first in references."), "\(lines)")
            let upscale = try #require(tools.first { $0.name == "image_upscale" })
            #expect(upscale.inputSchema.objectValue?["properties"]?.objectValue?["adapters"] == nil, "only where an offer lists adapters")

            let result = try await callTool(client, "image_generate",
                                            ["prompt": "a red fox", "size": ["width": 16, "height": 16], "prompt_enhance": "on",
                                             "adapters": [["id": "mock-style", "strength": 0.5]]])
            #expect(result.isError != true, "\(text(result))")
            let summary = text(result)
            #expect(summary.contains("Adapter: mock-style at 0.5 · Apache-2.0 · commercial use yes"), "\(summary)")
            #expect(summary.contains("Helper (prompt_enhance): mock-enhancer · Apache-2.0"), "\(summary)")
            #expect(summary.contains("Warning [prompt_rewritten]"), "\(summary)")
            let bad = try await callTool(client, "image_generate", ["prompt": "x", "adapters": "mock-style"])
            #expect(bad.isError == true && text(bad).contains("invalid_request"))
            await client.disconnect()
        }
    }
}
