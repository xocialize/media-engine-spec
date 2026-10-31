import CryptoKit
import Foundation
import MESCore

/// The Base tests for what each offer supports and its voices (§6.4, §6.5), assets (§8.1) and streamed output (§11).
extension BaseTests {
    typealias K = AudioProfile.SupportsKey

    static let declaresSupports: @Sendable (Probe) -> String? = {
        $0.operations.contains { d in d.models.contains { $0.supports != nil || $0.limits != nil } } ? nil : "no offer declares supports or limits"
    }
    static let offersVoices: @Sendable (Probe) -> String? = {
        $0.operations.contains { d in d.models.contains { $0.voiceCount > 0 } } ? nil : "no offer has preset voices"
    }

    /// An operation with a streamable output, an offer that streams it, and one that doesn't (BASE-015, BASE-056).
    static func streamGate(_ p: Probe) -> (Descriptor, OutputSpec, streams: ModelOffer, still: ModelOffer?)? {
        for d in p.operations {
            guard let out = d.outputs.first(where: { $0.stream != nil }), let s = d.models.first(where: { $0.streams && $0.namedOnly != true })
            else { continue }
            return (d, out, s, d.models.first { !$0.streams })
        }
        return nil
    }

    /// A request for a streaming offer, without naming it.
    static func streamRequest(_ p: Probe) async throws -> (JobRequest, OutputSpec, ModelOffer)? {
        guard let (d, out, m, _) = streamGate(p) else { return nil }
        var r = try await AudioTests.request(p, d, m, named: false)
        r.stream = [StreamRequest(output: out.name)]
        return (r, out, m)
    }

    static func events(_ frames: [Wire.Frame]) throws -> [Event] {
        try frames.map { f in
            guard let e = try? MESJSON.decoder.decode(Event.self, from: Data(f.data.utf8)) else {
                throw Failure("an event doesn't decode: \(f.data.prefix(200))")
            }
            return e
        }
    }

    // MARK: - §6.4, §6.5

    static let supports: [ConformanceTest] = [
        ConformanceTest("BASE-014", "Offers' declarations are consistent: Base supports keys typed, offer limits within the operation's", spec: "§6.4",
                        applies: declaresSupports) { p in
            for d in p.operations {
                let opLimits = (try? JSONValue(encoding: d.limits))?.objectValue ?? [:]
                for m in d.models {
                    for (key, value) in m.supports ?? [:] {
                        try check(key.wholeMatch(of: /[a-z][a-z0-9_]*|x-[a-z0-9]+\.[a-z0-9_]+/) != nil, "\(d.operation) / \(m.id): supports key '\(key)' isn't a valid name")
                        switch key {
                        case "stream", "seed": try check(value.boolValue != nil, "\(d.operation) / \(m.id): supports.\(key) isn't a boolean")
                        case "voices": try check((value.intValue ?? -1) >= 0, "\(d.operation) / \(m.id): supports.voices isn't a count")
                        default: break
                        }
                    }
                    for (field, value) in (try? JSONValue(encoding: m.limits))?.objectValue ?? [:] {
                        guard let bound = opLimits[field]?.numberValue, let own = value.numberValue else { continue }
                        let ok = field.hasPrefix("min_") ? own >= bound : own <= bound
                        try check(ok, "\(d.operation) / \(m.id): limits.\(field) \(own) is outside the operation's \(bound)")
                    }
                }
            }
            return nil
        },
        ConformanceTest("BASE-015", "A gate the named model lacks is 422 unsupported_parameter; with no model named, the plan names an offer that has it",
                        spec: "§6.4 rules 2–3", applies: { p in
                            guard let (_, _, _, still) = streamGate(p) else { return "no operation has both a streaming offer and a gate to test it by" }
                            return still == nil ? "every offer of the streaming operation streams" : nil
                        }) { p in
            let (d, out, streaming, still) = streamGate(p)!
            guard let (r, _, _) = try await streamRequest(p) else { return nil }
            let job = try await p.succeed(r)
            try check(d.models.first { $0.id == job.plan?.model.id }?.streams == true,
                      "a stream request with no model named ran on \(job.plan?.model.id ?? "?"), which doesn't stream (\(streaming.id) does)")
            await p.confirm(job)
            var named = try await AudioTests.request(p, d, still!)
            named.stream = [StreamRequest(output: out.name)]
            try await AudioTests.refuse(p, named, 422, "unsupported_parameter", "stream to \(still!.id), which doesn't stream")
            return nil
        },
        ConformanceTest("BASE-016", "A voice implies its model: the plan lists it and provenance names it; an unlisted voice, or one the named model lacks, is 422",
                        spec: "§6.5, §10.1", applies: offersVoices) { p in
            guard let d = p.operations.first(where: { $0.models.contains { $0.voiceCount > 0 } && $0.profile == AudioProfile.id }) else {
                return Note("voices are tested where a profile names them (Audio: voice)")
            }
            let m = d.models.first { $0.voiceCount > 0 }!
            guard let voice = try await AudioTests.voices(p, d, m).first else { throw Failure("\(m.id) says it has voices and lists none") }
            var r = try await AudioTests.request(p, d, m, named: m.namedOnly == true)
            r.params?[AudioProfile.Param.voice] = .string(voice.id)
            let job = try await p.succeed(r)
            let lists = try await AudioTests.voices(p, d, d.models.first { $0.id == job.plan?.model.id } ?? m)
            try check(lists.contains { $0.id == voice.id }, "the voice \(voice.id) ran on \(job.plan?.model.id ?? "?"), which doesn't list it")
            try check(job.result?.provenance.voice?.id == voice.id, "provenance doesn't name the voice")
            await p.confirm(job)
            var unknown = r
            unknown.params?[AudioProfile.Param.voice] = "no-such-voice-mes-conformance"
            try await AudioTests.refuse(p, unknown, 422, "unsupported_parameter", "a voice no offer lists")
            if let other = d.models.first(where: { $0.voiceCount == 0 }) {
                var wrong = try await AudioTests.request(p, d, other)
                wrong.inputs?[AudioProfile.Input.voiceRef] = nil
                wrong.inputs?[AudioProfile.Input.voiceRefText] = nil
                wrong.params?[AudioProfile.Param.voice] = .string(voice.id)
                try await AudioTests.refuse(p, wrong, 422, "unsupported_parameter", "a voice \(other.id) doesn't list")
            }
            return nil
        },
        ConformanceTest("BASE-017", "supports.seed false: a request with a seed runs, and warns seed_ignored", spec: "§6.4",
                        applies: { p in
                            p.operations.contains { d in d.profile == AudioProfile.id && d.models.contains { !$0.usesSeed } } ? nil
                                : "no offer the suite can drive declares supports.seed false"
                        }) { p in
            let d = p.operations.first { d in d.profile == AudioProfile.id && d.models.contains { !$0.usesSeed } }!
            let m = d.models.first { !$0.usesSeed }!
            var r = try await AudioTests.request(p, d, m)
            r.params?["seed"] = 42
            let job = try await p.succeed(r)
            try check(job.warnings.contains { $0.code == BaseWarningCode.seedIgnored }, "\(m.id) ignores seeds and didn't warn seed_ignored")
            await p.confirm(job)
            return nil
        },
        ConformanceTest("BASE-018", "Voice lists: as many voices as supports.voices, with an ETag and 304; unique ids; a model without voices, or not offered, is 404",
                        spec: "§6.5", applies: offersVoices) { p in
            var seen: [String: Voice] = [:]
            for d in p.operations {
                for m in d.models where m.voiceCount > 0 {
                    let reply = try await p.wire.send("GET", "operations/\(d.operation)/models/\(m.id)/voices")
                    try expect(reply, 200, "GET voices of \(m.id)", schemas: p.schemas)
                    try p.schemas.require(reply.body, "base/voices.schema.json", "the voice list of \(m.id)")
                    let list = try reply.decode(VoiceList.self)
                    try check(list.voices.count == m.voiceCount, "\(m.id) says \(m.voiceCount) voices and lists \(list.voices.count)")
                    try check(Set(list.voices.map(\.id)).count == list.voices.count, "\(m.id) lists a voice twice")
                    try check(reply.header("ETag") == list.etag, "the ETag header isn't the list's etag")
                    let again = try await p.wire.send("GET", "operations/\(d.operation)/models/\(m.id)/voices", headers: ["If-None-Match": list.etag])
                    try check(again.status == 304, "If-None-Match answered \(again.status), not 304")
                    for v in list.voices {
                        if let first = seen[v.id] { try check(first.title == v.title && first.license == v.license, "voice \(v.id) is described differently in two lists") }
                        seen[v.id] = v
                    }
                }
                if let without = d.models.first(where: { $0.voiceCount == 0 }) {
                    try expect(try await p.wire.send("GET", "operations/\(d.operation)/models/\(without.id)/voices"), 404, code: "not_found",
                               "voices of \(without.id), which has none", schemas: p.schemas)
                }
            }
            let d = p.operations.first { $0.models.contains { $0.voiceCount > 0 } }!
            try expect(try await p.wire.send("GET", "operations/\(d.operation)/models/no-such-model/voices"), 404, code: "not_found",
                       "voices of a model the operation doesn't offer", schemas: p.schemas)
            return nil
        },
    ]

    // MARK: - §8.1

    /// An operation with a media input the suite can fill, the fixture for it, and a request with the asset in place.
    static func assetCarrier(_ p: Probe) async throws -> (mediaType: String, data: Data, request: @Sendable (String) -> JobRequest)? {
        if let (d, m) = AudioTests.find(p, "audio.edit_speech", { $0.namedOnly != true }) {
            let base = try await AudioTests.request(p, d, m)
            return ("audio/wav", Fixtures.wav(), { id in var r = base; r.inputs?[AudioProfile.Input.audio] = .one(.asset(id)); return r })
        }
        for d in p.operations {
            guard let base = p.minimalRequest(d), let spec = d.inputs.first(where: { $0.kind == .image && $0.required }) else { continue }
            return ("image/png", Fixtures.png(), { id in var r = base; r.inputs?[spec.name] = .one(.asset(id)); return r })
        }
        return nil
    }

    static func createAsset(_ p: Probe, _ data: Data, mediaType: String, ttl: Int, wire: Wire? = nil) async throws -> Asset {
        let digest = Data(SHA256.hash(data: data)).base64EncodedString()
        let reply = try await (wire ?? p.wire).send("POST", "assets?ttl_s=\(ttl)", headers: ["Content-Type": mediaType, "Content-Digest": "sha-256=:\(digest):"],
                                                     body: data)
        try expect(reply, 201, "POST assets", schemas: p.schemas)
        try p.schemas.require(reply.body, "base/asset.schema.json", "the asset")
        return try reply.decode(Asset.self)
    }

    static let assets: [ConformanceTest] = [
        ConformanceTest("BASE-032", "Assets: 201 with the right size and SHA-256 and an expiry within max_asset_ttl_s; listed; two jobs use it; DELETE, then 422 and 404",
                        spec: "§8.1, §13 rule 6", applies: feature(.assets)) { p in
            guard let carrier = try await assetCarrier(p) else { return Note("no operation the suite can drive takes media") }
            let asset = try await createAsset(p, carrier.data, mediaType: carrier.mediaType, ttl: 600)
            try check(asset.bytes == carrier.data.count && asset.sha256 == Hex.sha256(carrier.data), "the asset's size or SHA-256 is wrong")
            let maxTTL = Double(p.info.limits.maxAssetTTLSeconds ?? 604_800)
            try check(asset.expiresAt.timeIntervalSince(asset.createdAt) <= min(600, maxTTL) + 2, "expires_at is beyond what was asked for and allowed")
            try check(p.info.limits.maxAssetTTLSeconds != nil, "an engine with assets states limits.max_asset_ttl_s")
            let listed = try await p.wire.send("GET", "assets")
            try p.schemas.require(listed.body, "base/asset.schema.json#/$defs/List", "GET assets")
            try check(try listed.decode(AssetList.self).assets.contains { $0.assetID == asset.assetID }, "GET assets doesn't list it")
            for n in 1...2 {
                let job = try await p.succeed(carrier.request(asset.assetID))
                await p.confirm(job)
                _ = n
            }
            try expect(try await p.wire.send("GET", "assets/\(asset.assetID)"), 200, "GET the asset", schemas: p.schemas)
            try expect(try await p.wire.send("DELETE", "assets/\(asset.assetID)"), 204, "DELETE the asset", schemas: p.schemas)
            try await AudioTests.refuse(p, carrier.request(asset.assetID), 422, "input_invalid", "a job naming a deleted asset")
            try expect(try await p.wire.send("GET", "assets/\(asset.assetID)"), 404, code: "not_found", "GET a deleted asset", schemas: p.schemas)
            return nil
        },
        ConformanceTest("BASE-033", "An asset whose Content-Digest doesn't match is refused, and one without ttl_s is 400", spec: "§8.1",
                        applies: feature(.assets)) { p in
            let bad = try await p.wire.send("POST", "assets?ttl_s=600", headers: ["Content-Type": "image/png", "Content-Digest": "sha-256=:\(Data(repeating: 0, count: 32).base64EncodedString()):"],
                                            body: Fixtures.png())
            try check(bad.status == 400 || bad.status == 422, "a wrong Content-Digest answered \(bad.status)")
            try expect(try await p.wire.send("POST", "assets", headers: ["Content-Type": "image/png"], body: Fixtures.png()), 400,
                       code: "invalid_request", "an asset without ttl_s", schemas: p.schemas)
            return nil
        },
        ConformanceTest("BASE-034", "An asset expires: one created with ttl_s=60 is gone after its expires_at", spec: "§8.1, §13 rule 6",
                        applies: { p in
                            if let r = feature(.assets)(p) { return r }
                            return p.options.maxTTLWait >= 75 ? nil : "asset expiry takes 60 s; run with --max-ttl-wait 75 or more"
                        }) { p in
            let asset = try await createAsset(p, Fixtures.png(), mediaType: "image/png", ttl: 60)
            let wait = max(0, asset.expiresAt.timeIntervalSinceNow) + 6
            try await Task.sleep(for: .seconds(wait))
            try expect(try await p.wire.send("GET", "assets/\(asset.assetID)"), 404, code: "not_found", "GET an expired asset", schemas: p.schemas)
            return nil
        },
        ConformanceTest("BASE-035", "Paired mode, a second pairing: another client's asset isn't listed, can't be read, and is 422 in a job",
                        spec: "§8.1", applies: { p in
                            if let r = feature(.assets)(p) { return r }
                            if let r = paired(p) { return r }
                            return p.options.pairing == nil ? "run with --pair: the suite pairs a second client (the operator approves it too)" : nil
                        }) { p in
            guard let carrier = try await assetCarrier(p) else { return Note("no operation the suite can drive takes media") }
            let (other, _) = try await Probe.pair(baseURL: p.wire.baseURL)
            let theirs = try await createAsset(p, carrier.data, mediaType: carrier.mediaType, ttl: 600, wire: other)
            let listed = try await p.wire.send("GET", "assets")
            try check(!(try listed.decode(AssetList.self).assets.contains { $0.assetID == theirs.assetID }), "another client's asset is listed")
            try expect(try await p.wire.send("GET", "assets/\(theirs.assetID)"), 404, code: "not_found", "GET another client's asset", schemas: p.schemas)
            try await AudioTests.refuse(p, carrier.request(theirs.assetID), 422, "input_invalid", "a job naming another client's asset")
            try expect(try await other.send("DELETE", "pairings/self"), 204, "unpairing the second client", schemas: p.schemas)
            return nil
        },
    ]

    // MARK: - §11 streaming

    static let streams: @Sendable (Probe) -> String? = { p in
        if let r = feature(.streaming)(p) { return r }
        return streamGate(p) == nil ? "no offer streams an output the suite can drive" : nil
    }

    static let streaming: [ConformanceTest] = [
        ConformanceTest("BASE-053", "Stream declarations: only on audio outputs with max 1; streaming is claimed exactly when some offer streams",
                        spec: "§6, §6.4") { p in
            let anyStreams = p.operations.contains { $0.models.contains(where: \.streams) }
            try check(anyStreams == p.has(.streaming), anyStreams ? "an offer streams, but engine info doesn't claim streaming"
                                                                  : "engine info claims streaming, but no offer has supports.stream")
            for d in p.operations {
                for o in d.outputs where o.stream != nil {
                    try check(o.kind == .audio && o.max == 1, "\(d.operation) output \(o.name) declares stream but isn't one audio value")
                    try check(!(o.stream!.encodings.isEmpty), "\(d.operation) output \(o.name) lists no stream encodings")
                }
                if d.models.contains(where: \.streams) {
                    try check(d.outputs.contains { $0.stream != nil }, "\(d.operation) has a streaming offer and no output that streams")
                }
            }
            return nil
        },
        ConformanceTest("BASE-054", "A streamed job: plan.streams gives the format; chunks from 0 with no gaps, whole frames, one final, before output_ready; the output is the chunks",
                        spec: "§7.2, §10.1, §11", applies: streams) { p in
            guard let (r, out, _) = try await streamRequest(p) else { return nil }
            let reply = try await p.wire.json("POST", "jobs", r)
            try expect(reply, 201, "POST a streamed job", schemas: p.schemas)
            let job = try reply.decode(Job.self)
            let (_, frames, _) = try await p.wire.frames("jobs/\(job.id)/events", timeout: p.options.jobTimeout) { $0.event == "job.output_ready" || $0.event == "job.ended" }
            let events = try events(frames)
            for e in events { try p.schemas.require(try JSONValue(encoding: e), "base/event.schema.json", "event \(e.type.rawValue)") }
            guard let plan = events.first(where: { $0.type == .plan }), let stream = try plan.data["streams"]?.arrayValue?.first?.decode(as: StreamPlan.self) else {
                throw Failure("the plan doesn't state the stream")
            }
            try check(stream.output == out.name, "the plan streams \(stream.output), not \(out.name)")
            let chunks = events.filter { $0.type == .outputChunk && $0.data["output"]?.stringValue == out.name }
            try check(!chunks.isEmpty, "no chunks arrived")
            try check(chunks.map { $0.data["index"]?.intValue ?? -1 } == Array(0..<chunks.count), "chunk indices aren't 0, 1, 2, … without gaps")
            try check(chunks.filter { $0.data["final"]?.boolValue == true }.count == 1 && chunks.last?.data["final"]?.boolValue == true,
                      "there isn't exactly one final chunk, last")
            guard let ready = events.firstIndex(where: { $0.type == .outputReady }) else { throw Failure("no job.output_ready") }
            try check(events.lastIndex { $0.type == .outputChunk }! < ready, "a chunk came after job.output_ready")
            var pcm = Data()
            for c in chunks {
                guard let data = c.data["data"]?.stringValue.flatMap({ Data(base64Encoded: $0) }) else { throw Failure("chunk \(c.data["index"]!) has no data") }
                try check(data.count % stream.frameBytes == 0, "chunk \(c.data["index"]!) holds a partial frame")
                pcm.append(data)
            }
            let held = try await p.settle(job)
            guard let output = held.result?.outputs.first(where: { $0.name == out.name }) else { throw Failure("the streamed output is missing") }
            let (_, file) = try await p.output(held, output.index)
            if output.mediaType == "audio/wav" {
                let wav = try WAVFile(file)
                try check(wav.sampleRate == stream.sampleRate && wav.channels == stream.channels, "the output's format isn't the plan's stream")
                try check(wav.pcm == pcm, "the output's samples aren't the chunks' (\(wav.pcm.count) bytes vs \(pcm.count))")
            }
            await p.confirm(held)
            return Note("\(chunks.count) chunks, \(pcm.count / stream.frameBytes) frames at \(stream.sampleRate) Hz")
        },
        ConformanceTest("BASE-055", "Release mid-stream: the outcome is cancelled, no final chunk is sent, and none follows the cancelled state",
                        spec: "§7.3, §11 rule 5", applies: streams) { p in
            guard var (r, out, m) = try await streamRequest(p) else { return nil }
            // A take long enough to release while it streams.
            let long = String(repeating: "This sentence keeps the voice talking for a while longer. ", count: 30)
            r.inputs?[AudioProfile.Input.text] = .text(long)
            if let max = m.limits?.value(AudioProfile.LimitField.maxTextChars), Double(long.count) > max {
                r.inputs?[AudioProfile.Input.text] = .text(String(long.prefix(Int(max))))
            }
            let reply = try await p.wire.json("POST", "jobs", r)
            try expect(reply, 201, "POST a streamed job", schemas: p.schemas)
            let job = try reply.decode(Job.self)
            let (_, first, _) = try await p.wire.frames("jobs/\(job.id)/events", timeout: p.options.jobTimeout) { $0.event == "job.output_chunk" || $0.event == "job.ended" }
            guard first.last?.event == "job.output_chunk" else { throw Failure("the job ended before its first chunk") }
            try expect(try await p.wire.send("DELETE", "jobs/\(job.id)"), 200, "release mid-stream", schemas: p.schemas)
            let (_, rest, _) = try await p.wire.frames("jobs/\(job.id)/events", timeout: 30) { $0.event == "job.ended" }
            let events = try events(rest)
            let chunks = events.filter { $0.type == .outputChunk && $0.data["output"]?.stringValue == out.name }
            if chunks.contains(where: { $0.data["final"]?.boolValue == true }) {
                let ended = events.first { $0.type == .ended }?.data["outcome"]?.stringValue
                try check(ended == "succeeded", "a cancelled job sent a final chunk")
                return Note("the take finished before the release reached it")
            }
            guard let cancelled = events.firstIndex(where: { $0.type == .state && $0.data["outcome"]?.stringValue == "cancelled" }) else {
                throw Failure("no cancelled state after release")
            }
            try check(!events[cancelled...].contains { $0.type == .outputChunk }, "a chunk followed the cancelled state")
            return Note("\(chunks.count) chunks before the release")
        },
        ConformanceTest("BASE-056", "stream on an output that can't stream, or to a named model that doesn't stream, is 422 unsupported_parameter",
                        spec: "§7.1", applies: streams) { p in
            let (d, _, m, still) = streamGate(p)!
            if let other = d.outputs.first(where: { $0.stream == nil }) ?? p.operations.first(where: { $0.outputs.allSatisfy { $0.stream == nil } })?.outputs.first {
                var r = try await AudioTests.request(p, d, m)
                if d.outputs.contains(where: { $0.name == other.name }) {
                    r.stream = [StreamRequest(output: other.name)]
                } else {
                    r.stream = [StreamRequest(output: "no_such_output")]
                }
                try await AudioTests.refuse(p, r, 422, "unsupported_parameter", "stream on an output that doesn't stream")
            }
            if let still {
                var r = try await AudioTests.request(p, d, still)
                r.stream = [StreamRequest(output: d.outputs.first { $0.stream != nil }!.name)]
                try await AudioTests.refuse(p, r, 422, "unsupported_parameter", "stream to \(still.id)")
            }
            return nil
        },
        ConformanceTest("BASE-057", "After confirm, a replayed chunk carries no data", spec: "§11 rule 4, §13 rule 2", applies: streams) { p in
            guard let (r, _, _) = try await streamRequest(p) else { return nil }
            let job = try await p.succeed(r)
            await p.confirm(job)
            let (_, frames, _) = try await p.wire.frames("jobs/\(job.id)/events", timeout: 30) { $0.event == "job.ended" }
            let chunks = try events(frames).filter { $0.type == .outputChunk }
            try check(!chunks.isEmpty, "the replay has no chunk events")
            try check(chunks.allSatisfy { $0.data["data"] == nil }, "a chunk replayed after confirm still carries its samples")
            return nil
        },
    ]
}
