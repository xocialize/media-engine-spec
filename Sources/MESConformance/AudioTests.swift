import Foundation
import MESCore

/// The Audio profile 0.1 tests (AUDIO-nnn, spec/profiles/audio.md §6), for the operations the engine offers.
enum AudioTests {
    typealias P = AudioProfile.Param
    typealias I = AudioProfile.Input
    typealias K = AudioProfile.SupportsKey

    static func offers(_ ops: String...) -> @Sendable (Probe) -> String? {
        { p in
            guard p.info.profiles.contains(where: { $0.id == AudioProfile.id }) else { return "the engine doesn't offer the Audio profile" }
            return ops.contains { p.descriptor($0) != nil } ? nil : "the engine offers none of \(ops.joined(separator: ", "))"
        }
    }

    static var audioOps: [String] { AudioProfile.operations.operations.keys.sorted() }

    static let sentence = "Hello from the conformance suite."

    /// The offer the engine chooses for a request that names none: the default, else the first that isn't `named_only`.
    static func defaultOffer(_ d: Descriptor) -> ModelOffer? {
        d.models.first { $0.isDefault == true } ?? d.models.first { $0.namedOnly != true }
    }

    static func list(_ m: ModelOffer, _ key: String) -> [String] { m.supports(key)?.arrayValue?.compactMap(\.stringValue) ?? [] }
    static func flag(_ m: ModelOffer, _ key: String) -> Bool { m.supports(key)?.boolValue ?? false }

    /// The cheapest tier an offer serves: `draft` where it has one (a probe needs the shape of a result, not its finish).
    static func tier(_ m: ModelOffer) -> QualityTier { m.qualityTiers.contains(.draft) ? .draft : (m.qualityTiers.first ?? .standard) }

    /// A length an offer admits, near `wanted`: within its own and the operation's `min_duration_s` and `max_duration_s`.
    static func duration(_ d: Descriptor, _ m: ModelOffer, wanted: Double) -> Double {
        let lo = max(m.limits?.value(AudioProfile.LimitField.minDuration) ?? 0, d.limits?.value(AudioProfile.LimitField.minDuration) ?? 0)
        let hi = min(m.limits?.maxDurationSeconds ?? .infinity, d.limits?.maxDurationSeconds ?? .infinity)
        return min(max(wanted, lo), hi)
    }

    /// A request that offer `m` of `d` can serve, built from what it supports (a voice from its list, a clip to clone,
    /// an edit kind it lists). It names the model when `named`, and asks for the offer's cheapest tier.
    static func request(_ p: Probe, _ d: Descriptor, _ m: ModelOffer, named: Bool = true) async throws -> JobRequest {
        var inputs: [String: RequestInput] = [:]
        var params: [String: JSONValue] = [:]
        let clip = RequestInput.one(.inline(mediaType: "audio/wav", data: Fixtures.wav()))
        switch d.operation {
        case "audio.design_voice":
            inputs[I.description] = .text("A warm, low voice of a woman in her forties, unhurried, with a slight rasp.")
            if d.params["properties"]?[P.count] != nil { params[P.count] = 1 }
        case "audio.speak":
            inputs[I.text] = .text(sentence)
            if m.voiceCount > 0, let voice = try await voices(p, d, m).first {
                params[P.voice] = .string(voice.id)
            } else if flag(m, K.voiceRef) {
                inputs[I.voiceRef] = clip
                if (m.supports(K.voiceRefText)?.stringValue ?? "unused") != "unused" { inputs[I.voiceRefText] = .text("Hello from the reference clip.") }
            }
        case "audio.edit_speech":
            inputs[I.audio] = clip
            if m.supports(K.transcript)?.stringValue != "unused" { inputs[I.transcript] = .text(sentence) }
            params[P.edit] = edit(m)
        case "audio.generate":
            inputs[I.prompt] = .text("Rain on a tin roof, steady, with distant thunder.")
            params[P.duration] = .number(duration(d, m, wanted: 1.5))
        case "audio.compose":
            inputs[I.caption] = .text("Upbeat synth-pop with a bright female vocal and a driving beat.")
            inputs[I.lyrics] = .text("[verse]\nLights on the water\nWe follow the line\n[chorus]\nRun all night\n")
            params[P.duration] = .number(duration(d, m, wanted: 5))
            if let langs = m.supports(K.languages)?.arrayValue?.compactMap(\.stringValue), langs.contains(where: { $0.hasPrefix("en") }) {
                params[P.language] = "en"
            }
        default: break
        }
        if d.params["properties"]?[P.quality] != nil { params[P.quality] = .string(tier(m).rawValue) }
        return JobRequest(operation: d.operation, inputs: inputs, params: params, model: named ? m.id : nil)
    }

    /// The first edit an editor lists, with the fields its kind needs.
    static func edit(_ m: ModelOffer, kind: String? = nil) -> JSONValue {
        let kind = kind ?? list(m, "edits").first ?? "denoise"
        var e: [String: JSONValue] = ["kind": .string(kind)]
        switch kind {
        case "emotion": e["emotion"] = .string(list(m, K.emotions).first ?? "happy")
        case "style": e["style"] = .string(list(m, K.styles).first ?? "whisper")
        case "add_cue": e["cue"] = .string(list(m, K.cues).first ?? "laugh"); e["at"] = "end"
        case "replace_text": e["text"] = "Hello"; e["with"] = "Hi"
        case "insert_text": e["text"] = "warmly"; e["anchor"] = "Hello"; e["position"] = "after"
        case "remove_text": e["text"] = "Hello"
        case "speed": e["factor"] = 1.5
        case "pitch": e["semitones"] = 2
        case "volume": e["gain_db"] = 5
        case "timbre": e["description"] = "brighter"
        default: break
        }
        return .object(e)
    }

    static func voices(_ p: Probe, _ d: Descriptor, _ m: ModelOffer) async throws -> [Voice] {
        let reply = try await p.wire.send("GET", "operations/\(d.operation)/models/\(m.id)/voices")
        try expect(reply, 200, "GET voices of \(m.id)", schemas: p.schemas)
        return try reply.decode(VoiceList.self).voices
    }

    /// An audio output's file, parsed, after checking it reports `sample_rate`, `channels` and `duration_s` and that a
    /// WAV agrees to within a frame.
    static func audio(_ p: Probe, _ job: Job, _ output: Output) async throws -> WAVFile? {
        try check(output.sampleRate != nil && output.channels != nil && output.durationSeconds != nil,
                  "\(job.operation) output \(output.name) doesn't report sample_rate, channels and duration_s (Base §10.1)")
        let (_, data) = try await p.output(job, output.index)
        guard output.mediaType == "audio/wav" else { return nil }
        let wav = try WAVFile(data)
        try check(wav.sampleRate == output.sampleRate, "\(output.name): the file is \(wav.sampleRate) Hz, the output says \(output.sampleRate!)")
        try check(wav.channels == output.channels, "\(output.name): the file has \(wav.channels) channels, the output says \(output.channels!)")
        try check(abs(wav.durationSeconds - output.durationSeconds!) <= 1.5 / Double(wav.sampleRate) + 0.001,
                  "\(output.name): the file is \(wav.durationSeconds) s, the output says \(output.durationSeconds!)")
        return wav
    }

    static func audioOutputs(_ job: Job) -> [Output] { job.result?.outputs.filter { $0.kind == .audio } ?? [] }

    /// The first offer of an offered operation that satisfies `test`.
    static func find(_ p: Probe, _ op: String, _ test: (ModelOffer) -> Bool) -> (Descriptor, ModelOffer)? {
        guard let d = p.descriptor(op), let m = d.models.first(where: test) else { return nil }
        return (d, m)
    }

    static func refuse(_ p: Probe, _ request: JobRequest, _ status: Int, _ code: String, _ what: String) async throws {
        let reply = try await p.wire.json("POST", "jobs", request)
        if reply.status == 201, let job = try? reply.decode(Job.self) { _ = try? await p.wire.send("DELETE", "jobs/\(job.id)") }
        try expect(reply, status, code: code, what, schemas: p.schemas)
    }

    /// The longest run of near-silence in a take, in seconds.
    static func longestSilence(_ wav: WAVFile, threshold: Double = 0.01) -> Double {
        let window = max(1, wav.sampleRate / 100)
        var longest = 0, current = 0
        var i = 0
        while i < wav.frames {
            if wav.rms(from: i, to: i + window) < threshold { current += window; longest = max(longest, current) } else { current = 0 }
            i += window
        }
        return Double(longest) / Double(wav.sampleRate)
    }

    static let all: [ConformanceTest] = [
        ConformanceTest("AUDIO-001", "Descriptors match the profile table: required inputs and outputs of the right kinds, only vocabulary parameters",
                        spec: "Audio §3, §6", applies: { p in offers(contentsOf: audioOps)(p) }) { p in
            for d in p.operations where d.profile == AudioProfile.id {
                guard let spec = AudioProfile.operations.operations[d.operation] else {
                    throw Failure("\(d.operation) isn't an Audio 0.1 operation (Base §6 rule 6)")
                }
                let inputs = Dictionary(d.inputs.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
                for (name, io) in spec.inputs {
                    if io.required == true { try check(inputs[name]?.required == true, "\(d.operation) doesn't require input '\(name)'") }
                    if let input = inputs[name] { try check(input.kind == io.kind, "\(d.operation) input '\(name)' is \(input.kind.rawValue), not \(io.kind.rawValue)") }
                }
                for name in inputs.keys { try check(spec.inputs[name] != nil, "\(d.operation) has input '\(name)', which the profile doesn't define") }
                let outputs = Dictionary(d.outputs.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
                for (name, io) in spec.outputs {
                    guard let output = outputs[name] else { throw Failure("\(d.operation) lacks output '\(name)'") }
                    try check(output.kind == io.kind, "\(d.operation) output '\(name)' is \(output.kind.rawValue), not \(io.kind.rawValue)")
                    if output.stream != nil { try check(io.streamable == true, "\(d.operation) output '\(name)' declares stream; the profile doesn't let it") }
                }
                for name in (d.params["properties"]?.objectValue ?? [:]).keys {
                    try check(spec.vocabulary.contains(name), "\(d.operation) parameter '\(name)' isn't in its vocabulary (model knobs are extensions)")
                }
                for name in spec.requiredParams ?? [] {
                    try check(d.params["properties"]?[name] != nil, "\(d.operation) lacks the parameter '\(name)', which every request carries")
                }
            }
            return nil
        },
        ConformanceTest("AUDIO-002", "Offers' supports keys have the profile's types, offer limits are the profile's fields, and streaming offers state their format",
                        spec: "Audio §4", applies: { p in offers(contentsOf: audioOps)(p) }) { p in
            for d in p.operations where d.profile == AudioProfile.id {
                let name = d.operation.split(separator: ".")[1]
                for m in d.models {
                    try p.schemas.require(.object(m.supports ?? [:]), "profiles/audio/supports.schema.json#/$defs/\(name)_supports", "\(d.operation) / \(m.id) supports")
                    if let limits = m.limits {
                        let profileLimits = try JSONValue(encoding: Descriptor.Limits(profile: limits.profile))
                        try p.schemas.require(profileLimits, "profiles/audio/supports.schema.json#/$defs/\(name)_limits", "\(d.operation) / \(m.id) limits")
                    }
                    if m.streams {
                        try check(m.supports(K.sampleRate)?.intValue != nil, "\(d.operation) / \(m.id) streams but doesn't declare sample_rate (Audio §4.1)")
                    }
                }
            }
            return nil
        },
        ConformanceTest("AUDIO-003", "Audio outputs report sample_rate, channels and duration_s, and the file agrees",
                        spec: "Audio §1.1, Base §10.1", applies: { p in offers(contentsOf: audioOps)(p) }) { p in
            for d in p.operations where d.profile == AudioProfile.id {
                guard let m = defaultOffer(d) else { continue }
                let job = try await p.succeed(try await request(p, d, m, named: false))
                let outs = audioOutputs(job)
                try check(!outs.isEmpty, "\(d.operation) returned no audio output")
                for output in outs { _ = try await audio(p, job, output) }
                await p.confirm(job)
            }
            return nil
        },
        ConformanceTest("AUDIO-004", "Every MUST input format is accepted: WAV at 16 and 24 bits and in float, and FLAC",
                        spec: "Audio §1.1", applies: offers("audio.edit_speech", "audio.speak")) { p in
            let carrier: (Descriptor, ModelOffer, String)? = find(p, "audio.edit_speech") { $0.namedOnly != true }.map { ($0.0, $0.1, I.audio) }
                ?? find(p, "audio.speak") { flag($0, K.voiceRef) }.map { ($0.0, $0.1, I.voiceRef) }
            guard let (d, m, input) = carrier else { return Note("no offer takes an audio input") }
            let formats: [(String, String, Data)] = [("16-bit WAV", "audio/wav", Fixtures.wav()), ("24-bit WAV", "audio/wav", Fixtures.wav(bits: 24)),
                                                     ("float WAV", "audio/wav", Fixtures.wav(bits: 32)), ("FLAC", "audio/flac", try Fixtures.flac())]
            for (label, mediaType, data) in formats {
                var r = try await request(p, d, m)
                r.inputs?[input] = .one(.inline(mediaType: mediaType, data: data))
                let job = try await p.run(r)
                try check(job.outcome == .succeeded, "\(d.operation) / \(m.id) refused a \(label) \(input): \(job.error?.message ?? job.state.rawValue)")
                await p.confirm(job)
            }
            return nil
        },
        ConformanceTest("AUDIO-005", "speak: a voice, a voice_ref and neither each route to an offer that supports them; voice with voice_ref is 400",
                        spec: "Audio §3.2, Base §6.4, §6.5", applies: offers("audio.speak")) { p in
            let d = p.descriptor("audio.speak")!
            var routed: [String] = []
            if let m = d.models.first(where: { $0.voiceCount > 0 && $0.namedOnly != true }), let voice = try await voices(p, d, m).first {
                var r = try await request(p, d, m, named: false)
                r.params?[P.voice] = .string(voice.id)
                let job = try await p.succeed(r)
                let model = d.models.first { $0.id == job.plan?.model.id }
                try check(model?.voiceCount ?? 0 > 0, "a voice routed to \(job.plan?.model.id ?? "?"), which lists no voices")
                try check(job.result?.provenance.voice?.id == voice.id, "provenance doesn't name the voice \(voice.id)")
                routed.append("voice → \(job.plan!.model.id)")
                await p.confirm(job)
            }
            if let m = d.models.first(where: { flag($0, K.voiceRef) && $0.namedOnly != true }) {
                let job = try await p.succeed(try await request(p, d, m, named: false))
                let model = d.models.first { $0.id == job.plan?.model.id }
                try check(model.map { flag($0, K.voiceRef) } == true, "a voice_ref routed to \(job.plan?.model.id ?? "?"), which doesn't clone")
                routed.append("voice_ref → \(job.plan!.model.id)")
                await p.confirm(job)
            }
            let bare = JobRequest(operation: d.operation, inputs: [I.text: .text(sentence)])
            if d.models.contains(where: { flag($0, K.defaultVoice) && $0.namedOnly != true }) {
                let job = try await p.succeed(bare)
                let model = d.models.first { $0.id == job.plan?.model.id }
                try check(model.map { flag($0, K.defaultVoice) } == true, "neither routed to \(job.plan?.model.id ?? "?"), which has no default voice")
                routed.append("neither → \(job.plan!.model.id)")
                await p.confirm(job)
            } else {
                try await refuse(p, bare, 422, "unsupported_parameter", "speak with neither voice nor voice_ref, and no default voice")
            }
            var both = bare
            both.inputs?[I.voiceRef] = .one(.inline(mediaType: "audio/wav", data: Fixtures.wav()))
            both.params = [P.voice: "any-voice"]
            try await refuse(p, both, 400, "invalid_request", "voice with voice_ref")
            return Note(routed.joined(separator: "; "))
        },
        ConformanceTest("AUDIO-006", "Labels: an emotion the named model doesn't list is 422; an alias is resolved by the engine",
                        spec: "Audio §2.1, Base §6.4 rule 3", applies: offers("audio.speak")) { p in
            let d = p.descriptor("audio.speak")!
            if let m = d.models.first(where: { !list($0, K.emotions).contains("disgusted") }) {
                var r = try await request(p, d, m)
                r.params?[P.emotion] = ["label": "disgusted"]
                try await refuse(p, r, 422, "unsupported_parameter", "an emotion \(m.id) doesn't list")
            }
            guard let m = d.models.first(where: { list($0, K.emotions).contains("afraid") }) else { return Note("no offer lists afraid, so the alias isn't run") }
            var r = try await request(p, d, m)
            r.params?[P.emotion] = ["label": "fearful"]
            let job = try await p.succeed(r)
            try check(job.result?.effective[P.emotion]?["label"]?.stringValue == "afraid",
                      "the alias fearful wasn't reported as afraid: \(job.result?.effective[P.emotion].map { "\($0)" } ?? "no effective.emotion")")
            await p.confirm(job)
            return nil
        },
        ConformanceTest("AUDIO-007", "Cues: one the model can't perform is removed with cue_unsupported; [pause 1s] is about a second of silence",
                        spec: "Audio §2.2", applies: offers("audio.speak")) { p in
            let d = p.descriptor("audio.speak")!
            guard let m = defaultOffer(d) else { return nil }
            let unperformed = AudioProfile.cues.first { $0 != "pause" && !list(m, K.cues).contains($0) }
            var r = try await request(p, d, m)
            r.inputs?[I.text] = .text("One moment. [pause 1s] Thank you." + (unperformed.map { " [\($0)]" } ?? ""))
            let job = try await p.succeed(r)
            if let unperformed {
                try check(job.warnings.contains { $0.code == AudioProfile.WarningCode.cueUnsupported },
                          "[\(unperformed)], which \(m.id) doesn't list, was neither performed nor warned cue_unsupported")
            }
            guard let output = audioOutputs(job).first, let wav = try await audio(p, job, output) else { return Note("not WAV, so the pause isn't measured") }
            let silence = longestSilence(wav)
            try check(silence >= 0.8, "[pause 1s] gave at most \(String(format: "%.2f", silence)) s of silence")
            await p.confirm(job)
            return Note(String(format: "longest silence %.2f s", silence))
        },
        ConformanceTest("AUDIO-008", "design_voice returns count samples with a seed and the sample text; the same seed reproduces; a sample clones",
                        spec: "Audio §3.1", applies: offers("audio.design_voice")) { p in
            let d = p.descriptor("audio.design_voice")!
            guard let m = defaultOffer(d) else { return nil }
            var r = try await request(p, d, m)
            let count = min(2, d.params["properties"]?[P.count]?["maximum"]?.intValue ?? 1)
            if count > 1 { r.params?[P.count] = .number(Double(count)) }
            r.params?[P.seed] = 7
            let job = try await p.succeed(r)
            try check(job.result!.outputs.filter { $0.name == "samples" }.count == count, "asked for \(count) samples")
            guard let text = job.result?.effective["text"]?.stringValue else { throw Failure("effective.text (what the samples say) is missing") }
            if m.usesSeed {
                try check(job.result?.effective[P.seed]?.intValue == 7, "effective.seed isn't the seed asked for")
                let again = try await p.succeed(r)
                try check(again.result!.outputs[0].sha256 == job.result!.outputs[0].sha256, "the same seed designed a different sample")
                await p.confirm(again)
            }
            if let (sd, clone) = find(p, "audio.speak", { flag($0, K.voiceRef) }) {
                let (_, sample) = try await p.output(job, job.result!.outputs[0].index)
                var speak = try await request(p, sd, clone)
                speak.inputs?[I.voiceRef] = .one(.inline(mediaType: job.result!.outputs[0].mediaType, data: sample))
                speak.inputs?[I.voiceRefText] = (clone.supports(K.voiceRefText)?.stringValue ?? "unused") == "unused" ? nil : .text(text)
                let spoke = try await p.succeed(speak)
                await p.confirm(spoke)
            }
            await p.confirm(job)
            return nil
        },
        ConformanceTest("AUDIO-009", "edit_speech: an edit an offer lists runs; one it doesn't is 422; one missing its fields is 400; keeps_length keeps it",
                        spec: "Audio §3.3", applies: offers("audio.edit_speech")) { p in
            let d = p.descriptor("audio.edit_speech")!
            guard let m = d.models.first(where: { !list($0, "edits").isEmpty }) else { throw Failure("no editor lists an edit kind") }
            let job = try await p.succeed(try await request(p, d, m))
            if let out = audioOutputs(job).first, let wav = try await audio(p, job, out), flag(m, K.keepsLength),
               let source = try? WAVFile(Fixtures.wav()) {
                try check(abs(wav.durationSeconds - source.durationSeconds) <= 1.5 / Double(wav.sampleRate) + 0.001,
                          "\(m.id) says keeps_length, but \(source.durationSeconds) s became \(wav.durationSeconds) s")
            }
            await p.confirm(job)
            if let missing = AudioProfile.editKinds.first(where: { !list(m, "edits").contains($0) }) {
                var r = try await request(p, d, m)
                r.params?[P.edit] = edit(m, kind: missing)
                try await refuse(p, r, 422, "unsupported_parameter", "a \(missing) edit \(m.id) doesn't list")
            }
            var r = try await request(p, d, m)
            r.params?[P.edit] = ["kind": "replace_text", "text": "Hello"]
            try await refuse(p, r, 400, "invalid_request", "a replace_text edit without 'with'")
            return nil
        },
        ConformanceTest("AUDIO-010", "generate: count sounds, each duration_s long to the frame, each seeded; the same seed reproduces; an unseeded request reports one",
                        spec: "Audio §3.4", applies: offers("audio.generate")) { p in
            let d = p.descriptor("audio.generate")!
            guard let m = defaultOffer(d) else { return nil }
            var r = try await request(p, d, m)
            let seconds = r.params?[P.duration]?.numberValue ?? 1.5
            let count = min(2, d.params["properties"]?[P.count]?["maximum"]?.intValue ?? 1)
            r.params?[P.count] = .number(Double(count))
            r.params?[P.seed] = 11
            let job = try await p.succeed(r)
            let sounds = job.result!.outputs.filter { $0.name == "sounds" }
            try check(sounds.count == count, "asked for \(count) sounds, got \(sounds.count)")
            for s in sounds {
                if let wav = try await audio(p, job, s) {
                    try check(wav.frames == Int((seconds * Double(wav.sampleRate)).rounded()),
                              "a \(seconds) s sound has \(wav.frames) frames at \(wav.sampleRate) Hz")
                }
            }
            try check(job.result?.effective[P.duration]?.numberValue == seconds, "effective.duration_s isn't \(seconds)")
            if m.usesSeed {
                try check(job.result?.effective[P.seed]?.intValue == 11, "effective.seed isn't the seed asked for")
                let again = try await p.succeed(r)
                try check(again.result!.outputs.map(\.sha256) == job.result!.outputs.map(\.sha256), "the same seed made different sounds")
                await p.confirm(again)
                var unseeded = r
                unseeded.params?[P.seed] = nil
                unseeded.params?[P.count] = 1
                let u = try await p.succeed(unseeded)
                try check(u.result?.effective[P.seed]?.intValue != nil, "an unseeded request didn't report the seed it used")
                await p.confirm(u)
            }
            await p.confirm(job)
            return nil
        },
        ConformanceTest("AUDIO-011", "compose: one song with its facts, duration and seed; the same seed reproduces; malformed edits and scores are 400; no named_only offer by default",
                        spec: "Audio §3.5", applies: offers("audio.compose")) { p in
            let d = p.descriptor("audio.compose")!
            guard let m = defaultOffer(d) else { return nil }
            var r = try await request(p, d, m, named: false)
            r.params?[P.seed] = 5
            let job = try await p.succeed(r)
            let chosen = d.models.first { $0.id == job.plan?.model.id }
            try check(chosen?.namedOnly != true, "a request naming no model got \(job.plan?.model.id ?? "?"), which is named_only")
            let songs = job.result!.outputs.filter { $0.name == "song" }
            try check(songs.count == 1, "a song job returned \(songs.count) songs")
            _ = try await audio(p, job, songs[0])
            try check(job.result?.effective[P.duration]?.numberValue != nil, "effective.duration_s is missing")
            if chosen?.usesSeed ?? true {
                try check(job.result?.effective[P.seed]?.intValue == 5, "effective.seed isn't the seed asked for")
                let again = try await p.succeed(r)
                try check(again.result!.outputs[songs[0].index].sha256 == songs[0].sha256, "the same seed composed a different song")
                await p.confirm(again)
            }
            await p.confirm(job)
            var editless = r
            editless.params?[P.edit] = ["kind": "cover"]
            try await refuse(p, editless, 400, "invalid_request", "an edit without a source")
            var scoreless = r
            scoreless.inputs?[I.lyrics] = nil
            scoreless.inputs?[I.score] = .text("X:1\nK:C\nCDEF|")
            try await refuse(p, scoreless, 400, "invalid_request", "a score without lyrics")
            let notices = d.models.filter { $0.license.notice != nil }.map(\.id)
            return notices.isEmpty ? nil : Note("offers with a licence notice to show with results: \(notices.joined(separator: ", "))")
        },
        ConformanceTest("AUDIO-012", "compose extend: the song is before_s + the source + after_s long, to the frame",
                        spec: "Audio §3.5", applies: { p in
                            find(p, "audio.compose") { list($0, "edits").contains("extend") } == nil ? "no compose offer lists extend" : nil
                        }) { p in
            let (d, m) = find(p, "audio.compose") { list($0, "edits").contains("extend") }!
            var r = try await request(p, d, m)
            let source = Fixtures.wav(seconds: 2, rate: m.supports(K.sampleRate)?.intValue ?? 48000)
            r.inputs?[I.source] = .one(.inline(mediaType: "audio/wav", data: source))
            r.params?[P.edit] = ["kind": "extend", "before_s": 1, "after_s": 1.5]
            r.params?[P.duration] = nil
            let job = try await p.succeed(r)
            let song = job.result!.outputs.first { $0.name == "song" }!
            guard let wav = try await audio(p, job, song) else { return Note("not WAV, so frames aren't counted") }
            let expected = Int((4.5 * Double(wav.sampleRate)).rounded())
            try check(abs(wav.frames - expected) <= 1, "an extend of 1 + 2 + 1.5 s has \(wav.frames) frames, not \(expected)")
            await p.confirm(job)
            return nil
        },
        ConformanceTest("AUDIO-013", "compose: a score, reference or edit sent to an offer without the key is 422 unsupported_parameter",
                        spec: "Audio §3.5, §4.1", applies: offers("audio.compose")) { p in
            let d = p.descriptor("audio.compose")!
            var checked: [String] = []
            let clip = RequestInput.one(.inline(mediaType: "audio/wav", data: Fixtures.wav()))
            if let m = d.models.first(where: { ($0.supports(K.score)?.stringValue ?? "unused") == "unused" }) {
                var r = try await request(p, d, m)
                r.inputs?[I.score] = .text("X:1\nK:C\nCDEF|")
                try await refuse(p, r, 422, "unsupported_parameter", "a score to \(m.id)")
                checked.append("score")
            }
            if let m = d.models.first(where: { !flag($0, K.reference) }) {
                var r = try await request(p, d, m)
                r.inputs?[I.reference] = clip
                try await refuse(p, r, 422, "unsupported_parameter", "a reference to \(m.id)")
                checked.append("reference")
            }
            if let m = d.models.first(where: { list($0, "edits").isEmpty }) {
                var r = try await request(p, d, m)
                r.inputs?[I.source] = clip
                r.params?[P.edit] = ["kind": "cover"]
                r.params?[P.duration] = nil
                try await refuse(p, r, 422, "unsupported_parameter", "an edit to \(m.id)")
                checked.append("edit")
            }
            return Note(checked.isEmpty ? "every offer supports score, reference and edits" : "refused: \(checked.joined(separator: ", "))")
        },
        ConformanceTest("AUDIO-014", "Output format: output.sample_rate is honoured; an un-offered media type is 422; a seed above 2³²−1 is 422",
                        spec: "Audio §1.2, §1.8", applies: { p in offers(contentsOf: audioOps)(p) }) { p in
            guard let d = p.operations.first(where: { $0.profile == AudioProfile.id && $0.params["properties"]?[P.output] != nil }),
                  let m = defaultOffer(d) else { return Note("no audio operation takes output") }
            var r = try await request(p, d, m)
            let rate = (m.supports(K.sampleRate)?.intValue ?? 24000) == 16000 ? 22050 : 16000
            r.params?[P.output] = ["sample_rate": .number(Double(rate))]
            let job = try await p.run(r)
            if job.outcome == .succeeded {
                for o in audioOutputs(job) {
                    try check(o.sampleRate == rate, "asked for \(rate) Hz, \(o.name) is \(o.sampleRate ?? 0) Hz")
                    _ = try await audio(p, job, o)
                }
                await p.confirm(job)
            } else {
                try check(job.error?.code == "unsupported_parameter", "a sample rate the engine can't give should be 422 unsupported_parameter")
            }
            let offered = d.params["properties"]?[P.output]?["properties"]?["media_type"]?["enum"]?.arrayValue?.compactMap(\.stringValue) ?? []
            if let missing = ["audio/wav", "audio/flac", "audio/mpeg", "audio/mp4", "audio/ogg"].first(where: { !offered.isEmpty && !offered.contains($0) }) {
                var bad = try await request(p, d, m)
                bad.params?[P.output] = ["media_type": .string(missing)]
                try await refuse(p, bad, 422, "unsupported_parameter", "an output media type \(d.operation) doesn't offer (\(missing))")
            }
            var seed = try await request(p, d, m)
            seed.params?[P.seed] = .number(4_294_967_296)
            try await refuse(p, seed, 422, "out_of_limits", "a seed of 2³²")
            return nil
        },
    ]

    static func offers(contentsOf ops: [String]) -> @Sendable (Probe) -> String? {
        { p in ops.contains { p.descriptor($0) != nil } ? nil : "the engine offers no Audio operations" }
    }
}
