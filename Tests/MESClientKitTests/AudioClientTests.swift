import Foundation
@testable import MESClientKit
import MESCore
import MESEngineKit
import MESInProcess
@testable import MockEngineCore
import Testing

// What v0.7.0 added to Base, from the client side: assets (§8.1), voice lists (§6.5) and streamed outputs (§11),
// against the mock engine's `audio.speak` (a streaming offer `mock-clone`, three preset voices on `mock-presets`),
// over HTTP, over the WebSocket and in process.

/// A reference clip for cloning: a few seconds of tone.
func referenceClip(seconds: Double = 4) throws -> URL {
    let url = tempFile("wav")
    _ = try Tones.writeWAV(Tones.tone(196, seconds: seconds, rate: 24_000), rate: 24_000, channels: 1, to: url)
    return url
}

func speakStreaming(_ voiceRef: InputValue, text: String = "Streaming arrives a quarter second at a time.",
                    encoding: StreamEncoding? = nil) -> JobRequest {
    JobRequest(operation: "audio.speak", inputs: ["text": .text(text), "voice_ref": .one(voiceRef)],
               stream: [StreamRequest(output: "audio", encoding: encoding)])
}

/// The chunks' samples, joined, after checking their order and format.
func joined(_ chunks: [OutputChunk], format: StreamPlan) -> Data {
    #expect(chunks.map(\.index) == Array(0..<chunks.count), "in order, each once")
    #expect(chunks.last?.final == true && chunks.dropLast().allSatisfy { !$0.final }, "only the last is final")
    #expect(chunks.allSatisfy { $0.format == format })
    #expect(chunks.allSatisfy { ($0.samples?.count ?? 0) % format.frameBytes == 0 }, "whole frames")
    return chunks.reduce(into: Data()) { $0.append($1.samples ?? Data()) }
}

/// The PCM of a held job's WAV output.
func outputPCM(_ engine: any EngineConnection, _ job: Job) async throws -> WAVFile {
    let output = try #require(job.result?.outputs.first)
    #expect(output.mediaType == "audio/wav")
    return try WAVFile(Data(contentsOf: try await engine.download(job: job.id, output: output, to: tempFile("wav"))))
}

@Suite("MESClientKit: assets, voices and streamed outputs over HTTP", .serialized)
struct AudioHTTPClientTests {
    @Test("Assets: create with Content-Digest, list, get, use in several jobs, delete; ttl_s below 60 is 400")
    func assets() async throws {
        try await withEngine(freshConfig(), engine: MockMediaEngine()) { port in
            let engine = HTTPEngineConnection(baseURL: openURL(port))
            #expect(try await engine.engineInfo().features.contains(.assets))
            let clip = try referenceClip()
            let asset = try await engine.createAsset(contentsOf: clip, ttl: .seconds(3600))
            let size = try Data(contentsOf: clip).count
            #expect(asset.mediaType == "audio/wav" && asset.bytes == size)
            #expect(asset.expiresAt.timeIntervalSince(asset.createdAt) <= 3601)
            #expect(try await engine.assets() == [asset])
            #expect(try await engine.asset(asset.assetID) == asset)
            for text in ["One.", "Two."] {
                let job = try await engine.run(JobRequest(operation: "audio.speak", inputs: ["text": .text(text),
                                                                                          "voice_ref": .one(.asset(asset.assetID))]))
                #expect(job.outcome == .succeeded, "an asset serves any number of jobs: \(String(describing: job.error))")
                _ = try await engine.confirm(job.id)
            }
            try await engine.deleteAsset(asset.assetID)
            #expect(try await engine.assets().isEmpty)
            await expectEngineError("not_found", status: 404) { try await engine.deleteAsset(asset.assetID) }
            await expectEngineError("invalid_request", status: 400) {
                _ = try await engine.createAsset(contentsOf: clip, mediaType: "audio/wav", ttlSeconds: 10)
            }
        }
    }

    @Test("AssetLibrary reuses an asset by content, and creates it again when a job answers 422 input_invalid")
    func assetLibrary() async throws {
        try await withEngine(freshConfig(), engine: MockMediaEngine()) { port in
            let engine = HTTPEngineConnection(baseURL: openURL(port))
            let library = AssetLibrary(engine: engine, ttlSeconds: 600)
            let clip = try referenceClip()
            let copy = tempFile("wav")
            try FileManager.default.copyItem(at: clip, to: copy)
            let first = try await library.asset(for: clip)
            #expect(try await library.asset(for: copy) == first, "the same bytes are one asset")
            #expect(try await engine.assets().count == 1)

            // The engine drops it (a restart, §8.1): the job's 422 makes the library send the file again.
            try await engine.deleteAsset(first.assetID)
            let request = JobRequest(operation: "audio.speak", inputs: ["text": .text("Again."), "voice_ref": .one(.asset(first.assetID))])
            await expectEngineError("input_invalid", status: 422) { _ = try await engine.submit(request, idempotencyKey: nil) }
            let job = try await library.run(request)
            #expect(job.outcome == .succeeded)
            let renewed = try #require(await library.held.first)
            #expect(renewed.assetID != first.assetID && renewed.sha256 == first.sha256)
            #expect(try await engine.assets().map(\.assetID) == [renewed.assetID])

            // An asset the library doesn't hold isn't its to replace.
            let stranger = JobRequest(operation: "audio.speak", inputs: ["text": .text("No."), "voice_ref": .one(.asset("ast_unknown"))])
            await expectEngineError("input_invalid", status: 422) { _ = try await library.submit(stranger) }

            try await library.removeAll()
            #expect(try await engine.assets().isEmpty)
            let held = await library.held
            #expect(held.isEmpty)
        }
    }

    @Test("Voice lists: three presets on mock-presets, revalidated by ETag; 404 for a model without voices")
    func voices() async throws {
        try await withEngine(freshConfig(), engine: MockMediaEngine()) { port in
            let engine = HTTPEngineConnection(baseURL: openURL(port))
            let list = try await engine.voices(operation: "audio.speak", model: "mock-presets")
            #expect(list.voices.map(\.id) == ["mock-alto", "mock-tenor", "mock-bass"])
            #expect(list.voices[2].license?.commercialUse == .no, "a voice's own terms")
            #expect(!list.etag.isEmpty)
            #expect(try await engine.voices(operation: "audio.speak", model: "mock-presets") == list, "a 304 answers from the cache")
            let offers = try await engine.operations().operations.first { $0.operation == "audio.speak" }?.models ?? []
            #expect(offers.first { $0.id == "mock-presets" }?.voiceCount == 3)
            await expectEngineError("not_found", status: 404) { _ = try await engine.voices(operation: "audio.speak", model: "mock-clone") }
            await expectEngineError("not_found", status: 404) { _ = try await engine.sample(of: list.voices[0]) }

            let job = try await engine.run(JobRequest(operation: "audio.speak", inputs: ["text": .text("Hello.")],
                                                      params: ["voice": "mock-tenor"]))
            #expect(job.result?.provenance.voice?.id == "mock-tenor")
        }
    }

    @Test("Streaming over SSE: the plan's format, chunks in order, a final one, and the same samples as the output")
    func streamingSSE() async throws {
        try await withEngine(freshConfig(), engine: MockMediaEngine()) { port in
            let engine = HTTPEngineConnection(baseURL: openURL(port))
            let clip = try await engine.createAsset(contentsOf: try referenceClip(), ttl: .seconds(600))
            let submitted = try await engine.submit(speakStreaming(.asset(clip.assetID)), idempotencyKey: nil)
            var chunks: [OutputChunk] = []
            for try await chunk in engine.outputChunks(job: submitted.id, output: "audio") { chunks.append(chunk) }
            let job = try await engine.job(submitted.id, wait: 0)
            let format = try #require(job.plan?.streams?.first)
            #expect(format == StreamPlan(output: "audio", encoding: .pcmS16LE, sampleRate: 22_050, channels: 1))
            #expect(job.plan?.model.id == "mock-clone", "streaming implies its model")
            #expect(chunks.count > 2)
            let pcm = joined(chunks, format: format)
            let wav = try await outputPCM(engine, job)
            #expect(wav.pcm == pcm && wav.sampleRate == 22_050 && wav.bitsPerSample == 16)

            // Resuming past the plan: the formats come from the snapshot, and the chunks pick up where they were.
            let late = chunks[2]
            let resumedFrom = try await engine.events(job: job.id, after: 0).first { $0.type == .outputChunk && $0.data["index"]?.intValue == 1 }
            var resumed: [OutputChunk] = []
            for try await chunk in engine.outputChunks(job: job.id, after: try #require(resumedFrom).seq) { resumed.append(chunk) }
            #expect(resumed.first == late && resumed.count == chunks.count - 2)
            _ = try await engine.confirm(job.id)
        }
    }

    @Test("runStreaming passes every chunk then returns the held job; f32 streams as 32-bit float")
    func runStreaming() async throws {
        try await withEngine(freshConfig(), engine: MockMediaEngine()) { port in
            let engine = HTTPEngineConnection(baseURL: openURL(port))
            let clip = try referenceClip()
            let voice = try await engine.input(contentsOf: clip, inlineLimit: 1 << 20)
            let chunks = Recorder<OutputChunk>()
            let job = try await engine.runStreaming(speakStreaming(voice, encoding: .pcmF32LE)) { await chunks.add($0) }
            #expect(job.state == .holding && job.outcome == .succeeded)
            let format = StreamPlan(output: "audio", encoding: .pcmF32LE, sampleRate: 22_050, channels: 1)
            let pcm = joined(await chunks.items, format: format)
            let wav = try await outputPCM(engine, job)
            #expect(wav.format == .float && wav.bitsPerSample == 32 && wav.pcm == pcm)

            // The chunks written as they arrive make the same file's samples.
            var writer = try WAVStreamWriter(url: tempFile("wav"), format: format)
            for chunk in await chunks.items { try writer.append(chunk.samples ?? Data()) }
            let written = try WAVFile(Data(contentsOf: try writer.finish()))
            #expect(written == wav)

            // After purge, replayed chunks keep their place without their samples (§11 rule 4).
            _ = try await engine.confirm(job.id)
            let replay = try await engine.events(job: job.id, after: 0).compactMap(OutputChunk.init).reduce(into: [OutputChunk]()) { $0.append($1) }
            #expect(replay.count == (await chunks.items).count && replay.allSatisfy { $0.samples == nil })
        }
    }

    @Test("A job cancelled while it streams ends its chunks with StreamIncomplete; a refused stream is 422")
    func incomplete() async throws {
        try await withEngine(freshConfig(), engine: MockMediaEngine(chunkDelay: .milliseconds(150))) { port in
            let engine = HTTPEngineConnection(baseURL: openURL(port))
            let voice = try await engine.input(contentsOf: try referenceClip(), inlineLimit: 1 << 20)
            let job = try await engine.submit(speakStreaming(voice, text: String(repeating: "A long line to say. ", count: 6)),
                                              idempotencyKey: nil)
            var count = 0
            do {
                for try await _ in engine.outputChunks(job: job.id) {
                    count += 1
                    if count == 1 { _ = try await engine.release(job.id) }
                }
                Issue.record("expected StreamIncomplete")
            } catch let error as StreamIncomplete {
                #expect(error.output == "audio" && error.outcome == .cancelled && error.chunks >= 1)
            }
            let after = try await engine.runStreaming(speakStreaming(voice, text: String(repeating: "Again and again. ", count: 6))) { chunk in
                if chunk.index == 0, let id = chunk.job { _ = try await engine.release(id) }
            }
            #expect(after.outcome == .cancelled, "runStreaming returns the cancelled job")

            await expectEngineError("unsupported_parameter", status: 422) {
                _ = try await engine.submit(JobRequest(operation: "audio.speak", inputs: ["text": .text("x")], model: "mock-presets",
                                                       stream: [StreamRequest(output: "audio")]), idempotencyKey: nil)
            }
        }
    }

    @Test("Streaming over the WebSocket: the same chunks, each once even with overlapping subscriptions")
    func streamingWebSocket() async throws {
        try await withEngine(freshConfig(), engine: MockMediaEngine()) { port in
            let engine = HTTPEngineConnection(baseURL: openURL(port))
            let voice = try await engine.input(contentsOf: try referenceClip(), inlineLimit: 1 << 20)
            let job = try await engine.submit(speakStreaming(voice), idempotencyKey: nil)
            let channel = engine.eventChannel()
            defer { channel.close() }
            try await channel.subscribeAll()
            try await channel.subscribe([job.id])                       // overlapping: events can arrive twice
            var chunks: [OutputChunk] = []
            for try await chunk in channel.outputChunks(job: job.id, output: "audio") { chunks.append(chunk) }
            let held = try await engine.job(job.id, wait: 0)
            let format = try #require(held.plan?.streams?.first)
            #expect(try await outputPCM(engine, held).pcm == joined(chunks, format: format))
        }
    }
}

@Suite("ChunkReader")
struct ChunkReaderTests {
    func event(_ type: EventType, seq: Int, job: String = "job_a", _ data: JSONValue) -> Event {
        Event(type: type, job: job, seq: seq, time: Date(), data: data)
    }
    func chunk(_ index: Int, seq: Int, final: Bool = false, job: String = "job_a") -> Event {
        event(.outputChunk, seq: seq, job: job, ["output": "audio", "index": .number(Double(index)), "offset_s": 0, "final": .bool(final),
                                                  "data": .string(Data([1, 0, 2, 0]).base64EncodedString())])
    }

    @Test("Duplicates and other jobs are skipped; a gap throws; the plan's format rides on each chunk")
    func ordering() throws {
        var reader = ChunkReader(job: "job_a")
        let plan: JSONValue = ["model": ["id": "m"], "effective": [:],
                               "streams": [["output": "audio", "encoding": "pcm_s16le", "sample_rate": 8000, "channels": 1]]]
        #expect(try reader.read(event(.plan, seq: 1, plan)) == nil)
        let first = try #require(try reader.read(chunk(0, seq: 2)))
        #expect(first.format?.sampleRate == 8000 && first.frames == 2 && first.samples == Data([1, 0, 2, 0]))
        #expect(try reader.read(chunk(0, seq: 2)) == nil, "the same event twice")
        #expect(try reader.read(chunk(1, seq: 3, job: "job_b")) == nil, "another job's")
        #expect(throws: MESClientError.self) { try reader.read(chunk(2, seq: 4)) }
        #expect(try reader.read(chunk(1, seq: 3, final: true))?.final == true)
        #expect(reader.isComplete)
        #expect(try reader.read(event(.outputReady, seq: 5, ["outputs": []])) == nil)
    }

    @Test("A job that fails before the final chunk is StreamIncomplete, with its error")
    func failure() throws {
        var reader = ChunkReader(job: "job_a", plans: [StreamPlan(output: "audio", encoding: .pcmS16LE, sampleRate: 8000, channels: 1)])
        _ = try reader.read(chunk(0, seq: 1))
        #expect(throws: StreamIncomplete(output: "audio", chunks: 1, outcome: .failed,
                                         error: MESError(code: "internal", message: "boom"))) {
            try reader.read(event(.ended, seq: 2, ["outcome": "failed", "error": ["code": "internal", "message": "boom"]]))
        }
    }
}

@Suite("MESInProcess: assets, voices and chunks with no sockets", .serialized)
struct AudioInProcessTests {
    @Test("The same chunks, assets and voice lists as over HTTP")
    func inProcess() async throws {
        let engine = try await InProcessEngine.start(engine: MockMediaEngine(), configuration: freshConfig())
        let voices = try await engine.voices(operation: "audio.speak", model: "mock-presets")
        #expect(voices.voices.count == 3)
        await expectEngineError("not_found", status: 404) { _ = try await engine.voices(operation: "audio.speak", model: "mock-clone") }

        let library = AssetLibrary(engine: engine)
        let clip = try referenceClip()
        let voice = try await library.input(for: clip)
        #expect(try await engine.assets().count == 1)
        let chunks = Recorder<OutputChunk>()
        let job = try await library.runStreaming(speakStreaming(voice)) { await chunks.add($0) }
        #expect(job.outcome == .succeeded)
        let format = try #require(job.plan?.streams?.first)
        #expect(try await outputPCM(engine, job).pcm == joined(await chunks.items, format: format))

        // And as a sequence, replayed while the outputs exist.
        var replayed: [OutputChunk] = []
        for try await chunk in engine.outputChunks(job: job.id, output: "audio") { replayed.append(chunk) }
        #expect(replayed == (await chunks.items))

        guard case .asset(let id) = voice else { Issue.record("expected an asset"); return }
        try await engine.deleteAsset(id)
        let again = try await library.run(speakStreaming(voice))
        #expect(again.outcome == .succeeded, "re-created in process too")
        await expectEngineError("invalid_request", status: 400) {
            _ = try await engine.createAsset(contentsOf: clip, mediaType: "audio/wav", ttlSeconds: 5)
        }
        await engine.stop()
    }
}
