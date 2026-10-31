import Foundation
@testable import MESCore
import Testing

/// The repo root, found from this file (Tests/MESCoreTests/MESCoreTests.swift).
let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let schemas = repo.appendingPathComponent("schemas/v0")
let examples = repo.appendingPathComponent("examples/v0")

func json(_ url: URL) throws -> JSONValue { try MESJSON.decoder.decode(JSONValue.self, from: Data(contentsOf: url)) }

/// example → (schema path#pointer, Swift type)
let manifest: [(String, String, any (Codable & Sendable).Type)] = [
    ("engine-info.json", "base/engine-info.schema.json", EngineInfo.self),
    ("pairing-request.json", "base/pairing.schema.json#/$defs/Request", PairingRequest.self),
    ("pairing-created.json", "base/pairing.schema.json#/$defs/Created", PairingCreated.self),
    ("pairing-approved.json", "base/pairing.schema.json#/$defs/Approved", PairingApproved.self),
    ("operations-image-fill.json", "base/operations-list.schema.json", OperationsList.self),
    ("job-request-generate.json", "base/job-request.schema.json", JobRequest.self),
    ("job-request-fill-upload.json", "base/job-request.schema.json", JobRequest.self),
    ("job-request-fill-grant.json", "base/job-request.schema.json", JobRequest.self),
    ("job-request-segment-points.json", "base/job-request.schema.json", JobRequest.self),
    ("upload.json", "base/upload.schema.json", Upload.self),
    ("job-holding-generate.json", "base/job.schema.json", Job.self),
    ("job-holding-describe.json", "base/job.schema.json", Job.self),
    ("job-failed.json", "base/job.schema.json", Job.self),
    ("event-progress.json", "base/event.schema.json", Event.self),
    ("event-output-ready.json", "base/event.schema.json", Event.self),
    ("event-ended.json", "base/event.schema.json", Event.self),
    ("error-policy-unmet.json", "base/error.schema.json", ErrorBody.self),
    ("health.json", "base/health.schema.json", Health.self),
    ("model-offer-research.json", "base/descriptor.schema.json#/$defs/ModelOffer", ModelOffer.self),
    ("model-offer-adapters.json", "base/descriptor.schema.json#/$defs/ModelOffer", ModelOffer.self),
    ("job-request-edit-adapters.json", "base/job-request.schema.json", JobRequest.self),
    ("job-holding-generate-enhanced.json", "base/job.schema.json", Job.self),
    ("job-holding-enhance-prompt.json", "base/job.schema.json", Job.self),
    ("job-holding-edit-adapters.json", "base/job.schema.json", Job.self),
    ("operations-image-decompose.json", "base/operations-list.schema.json", OperationsList.self),
    ("job-holding-decompose.json", "base/job.schema.json", Job.self),
    ("operations-audio-speak.json", "base/operations-list.schema.json", OperationsList.self),
    ("operations-audio-edit-generate.json", "base/operations-list.schema.json", OperationsList.self),
    ("operations-audio-compose.json", "base/operations-list.schema.json", OperationsList.self),
    ("voices-kokoro.json", "base/voices.schema.json", VoiceList.self),
    ("asset.json", "base/asset.schema.json", Asset.self),
    ("job-request-speak-stream.json", "profiles/audio/job-request.schema.json", JobRequest.self),
    ("job-request-edit-speech.json", "profiles/audio/job-request.schema.json", JobRequest.self),
    ("job-request-compose.json", "profiles/audio/job-request.schema.json", JobRequest.self),
    ("event-output-chunk.json", "base/event.schema.json", Event.self),
    ("job-holding-speak.json", "base/job.schema.json", Job.self),
    ("job-holding-compose.json", "base/job.schema.json", Job.self),
]

func schema(_ target: String, loader: SchemaLoader) throws -> (JSONValue, URL, JSONValue) {
    let parts = target.split(separator: "#", maxSplits: 1).map(String.init)
    let url = schemas.appendingPathComponent(parts[0])
    let document = try #require(loader.load(url))
    var node = document
    if parts.count > 1 {
        for key in parts[1].split(separator: "/") where !key.isEmpty { node = try #require(node[String(key)]) }
    }
    return (node, url, document)
}

@Suite("MESCore: types and schemas agree with the spec")
struct MESCoreTests {
    @Test("Every example decodes into its Swift type and re-encodes to the same JSON")
    func roundTrip() throws {
        for (file, _, type) in manifest {
            let data = try Data(contentsOf: examples.appendingPathComponent(file))
            let decoded = try MESJSON.decoder.decode(type, from: data)
            let reencoded = try MESJSON.decoder.decode(JSONValue.self, from: MESJSON.encoder.encode(decoded))
            let original = try MESJSON.decoder.decode(JSONValue.self, from: data)
            #expect(reencoded == original, "\(file) changed in a round trip")
        }
    }

    @Test("The Swift validator accepts every example against its schema, like tools/validate.py")
    func examplesValidate() throws {
        let loader = SchemaLoader()
        let validator = SchemaValidator(loader: loader)
        for (file, target, _) in manifest {
            let (s, url, document) = try schema(target, loader: loader)
            let issues = validator.validate(try json(examples.appendingPathComponent(file)), against: s, in: document, base: url)
            #expect(issues.isEmpty, "\(file): \(issues.prefix(3))")
        }
    }

    @Test("The Swift validator rejects what the spec forbids")
    func validatorRejects() throws {
        let loader = SchemaLoader()
        let validator = SchemaValidator(loader: loader)
        let (jobSchema, jobURL, _) = try schema("base/job.schema.json", loader: loader)
        guard case .object(var job) = try json(examples.appendingPathComponent("job-holding-generate.json")) else {
            Issue.record("not an object"); return
        }
        job["state"] = "done"
        #expect(!validator.validate(.object(job), against: jobSchema, base: jobURL).isEmpty)

        let (reqSchema, reqURL, _) = try schema("base/job-request.schema.json", loader: loader)
        let twoForms: JSONValue = ["operation": "image.fill",
                                   "inputs": ["image": ["upload": "u1", "inline": ["media_type": "image/png", "data": "AA=="]]]]
        #expect(!validator.validate(twoForms, against: reqSchema, base: reqURL).isEmpty)

        // A descriptor's params schema validates request params (no refs needed).
        let params: JSONValue = ["type": "object", "additionalProperties": false,
                                 "properties": ["strength": ["type": "number", "minimum": 0, "maximum": 1]]]
        #expect(validator.validate(["strength": 0.5], against: params).isEmpty)
        #expect(!validator.validate(["strength": 2], against: params).isEmpty)
        #expect(!validator.validate(["guidance": 3], against: params).isEmpty)
        #expect(!validator.validate(["x": 1], against: ["typo": true]).isEmpty, "unknown keywords are reported")
    }

    @Test("The bundled operations table is identical to schemas/v0/profiles/image/operations.json")
    func operationsTable() throws {
        let canonical = try MESJSON.decoder.decode(ImageProfile.Table.self, from: Data(contentsOf:
            schemas.appendingPathComponent("profiles/image/operations.json")))
        #expect(ImageProfile.operations == canonical)
        #expect(ImageProfile.operations.operations.count == 15)
        #expect(ImageProfile.operations.operations["image.fill"]?.preservesUnmasked == true)
    }

    @Test("The bundled Audio table and vocabulary are identical to schemas/v0/profiles/audio")
    func audioTable() throws {
        let canonical = try MESJSON.decoder.decode(ProfileTable.self, from: Data(contentsOf:
            schemas.appendingPathComponent("profiles/audio/operations.json")))
        #expect(AudioProfile.operations == canonical)
        #expect(AudioProfile.operations.operations.keys.sorted() == ["audio.compose", "audio.design_voice", "audio.edit_speech",
                                                                    "audio.generate", "audio.speak"])
        #expect(AudioProfile.vocabulary == (try json(schemas.appendingPathComponent("profiles/audio/vocabulary.schema.json"))))
        // The label lists are the vocabulary's enums.
        #expect(AudioProfile.vocabulary["$defs"]?["emotion_label"]?["enum"] == .array(AudioProfile.emotions.map { .string($0) }))
        #expect(AudioProfile.vocabulary["$defs"]?["style"]?["enum"] == .array(AudioProfile.styles.map { .string($0) }))
        #expect(AudioProfile.vocabulary["$defs"]?["cue"]?["enum"] == .array(AudioProfile.cues.map { .string($0) }))
        #expect(AudioProfile.vocabulary["$defs"]?["edit"]?["properties"]?["kind"]?["enum"] == .array(AudioProfile.editKinds.map { .string($0) }))
        #expect(AudioProfile.vocabulary["$defs"]?["section"]?["enum"] == .array(AudioProfile.sections.map { .string($0) }))
    }

    @Test("Cues: one syntax, [name] and [pause Ns], with \\[ for a literal bracket")
    func cues() {
        let s = AudioProfile.segments("Well [laugh] that's it. [pause 1.5s] See \\[S1] and [a long aside].")
        #expect(s == [.text("Well "), .cue("laugh", seconds: nil), .text(" that's it. "), .cue("pause", seconds: 1.5),
                      .text(" See [S1] and [a long aside].")])
        #expect(AudioProfile.segments(AudioProfile.text(s)) == s)
        #expect(AudioProfile.canonicalEmotion("Fearful") == "afraid" && AudioProfile.canonicalEmotion("anger") == "angry")
        #expect(AudioProfile.canonicalEmotion("smug") == nil)
        #expect(AudioProfile.sectionTags("[Verse]\nla\n[chorus - anthemic, full band]\nla") == ["verse", "chorus"])
        #expect(AudioProfile.sectionTags("just words") == ["verse"])
    }

    @Test("WAV: written and read back, integer and float")
    func wav() throws {
        let int16 = WAVFile(sampleRate: 24000, channels: 2, samples: [0, 1000, -1000, 32767])
        let back = try WAVFile(int16.data)
        #expect(back == int16 && back.frames == 2 && back.durationSeconds == 2.0 / 24000)
        let plan = StreamPlan(output: "audio", encoding: .pcmF32LE, sampleRate: 48000, channels: 1)
        var pcm = Data()
        for x: Float in [0.5, -0.25] { withUnsafeBytes(of: x.bitPattern.littleEndian) { pcm.append(contentsOf: $0) } }
        let float = try WAVFile(WAVFile(stream: plan, pcm: pcm).data)
        #expect(float.format == .float && float.bitsPerSample == 32 && float.floatSamples == [0.5, -0.25])
    }

    @Test("Pairing code matches the independent Python computation")
    func pairingCode() {
        let code = PairingCode.code(clientNonce: Data(0..<32), engineNonce: Data(32..<64),
                                    engineFingerprint: PairingCode.fingerprint(Data("engine-cert".utf8)),
                                    clientFingerprint: PairingCode.fingerprint(Data("client-key".utf8)))
        #expect(code == "020002")
        #expect(Base64URL.decode(Base64URL.encode(Data(0..<33))) == Data(0..<33))
    }

    @Test("Input values: exactly one form; text is a plain string")
    func inputValues() throws {
        let req = try MESJSON.decoder.decode(JobRequest.self, from: Data(#"""
            {"operation":"image.fill","inputs":{"image":{"upload":"u1"},"prompt":"red","refs":[{"upload":"u2"},{"upload":"u3"}]}}
            """#.utf8))
        #expect(req.inputs?["prompt"] == .text("red"))
        #expect(req.inputs?["image"] == .one(.upload("u1")))
        #expect(req.inputs?["refs"]?.values.count == 2)
        #expect(throws: (any Error).self) {
            try MESJSON.decoder.decode(InputValue.self, from: Data(#"{"upload":"a","grant":{}}"#.utf8))
        }
    }
}
