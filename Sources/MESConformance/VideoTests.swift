import Foundation
import MESCore
import MockEngineCore

/// The Video profile 0.1 tests (VIDEO-nnn, spec/profiles/video.md §6), for the operations the engine offers. Each asks
/// for an offer's cheapest tier and a small clip, so the slowest models fit `--job-timeout`.
enum VideoTests {
    typealias P = VideoProfile.Param
    typealias I = VideoProfile.Input
    typealias K = VideoProfile.SupportsKey
    typealias L = VideoProfile.LimitField

    static func offers(_ ops: String...) -> @Sendable (Probe) -> String? { offers(contentsOf: ops) }

    static func offers(contentsOf ops: [String]) -> @Sendable (Probe) -> String? {
        { p in
            guard p.info.profiles.contains(where: { $0.id == VideoProfile.id }) else { return "the engine doesn't offer the Video profile" }
            return ops.contains { p.descriptor($0) != nil } ? nil : "the engine offers none of \(ops.joined(separator: ", "))"
        }
    }

    /// Applies when some offer of `op` satisfies `test`.
    static func offering(_ op: String, _ what: String, _ test: @escaping @Sendable (ModelOffer) -> Bool) -> @Sendable (Probe) -> String? {
        { p in
            if let reason = offers(op)(p) { return reason }
            return p.descriptor(op)!.models.contains(where: test) ? nil : "no \(op) offer \(what)"
        }
    }

    static var videoOps: [String] { VideoProfile.operations.operations.keys.sorted() }
    static let prompt = "A red kite over green hills, grass moving in the wind, birdsong."

    static func defaultOffer(_ d: Descriptor) -> ModelOffer? {
        d.models.first { $0.isDefault == true } ?? d.models.first { $0.namedOnly != true }
    }
    static func flag(_ m: ModelOffer, _ key: String) -> Bool { m.supports(key)?.boolValue ?? false }
    static func list(_ m: ModelOffer, _ key: String) -> [String] { m.supports(key)?.arrayValue?.compactMap(\.stringValue) ?? [] }
    static func tier(_ m: ModelOffer) -> QualityTier { m.qualityTiers.contains(.draft) ? .draft : (m.qualityTiers.first ?? .standard) }

    /// The fixture's facts (Video §6): 128×96, 17 frames at 24 fps.
    static let fixtureFrames = 17, fixtureFPS = 24.0

    /// A small size an offer admits: 256×256 where it can, else within its limits and on its grid.
    static func size(_ d: Descriptor, _ m: ModelOffer) -> (Int, Int) {
        let step = max(1, m.supports(K.sizeStep)?.intValue ?? 1)
        func bound(_ v: Int, min lo: Double?, max hi: Int?) -> Int {
            var x = Double(v)
            if let lo { x = Swift.max(x, lo) }
            if let hi { x = Swift.min(x, Double(hi)) }
            return Swift.max(step, Int(x) / step * step)
        }
        let lim = m.limits, dl = d.limits
        return (bound(256, min: lim?.value(L.minWidth) ?? dl?.value(L.minWidth), max: lim?.maxWidth ?? dl?.maxWidth),
                bound(256, min: lim?.value(L.minHeight) ?? dl?.value(L.minHeight), max: lim?.maxHeight ?? dl?.maxHeight))
    }

    /// A frame rate an offer admits: 24 unless its `frame_rates` lacks it.
    static func fps(_ m: ModelOffer) -> Double {
        let rates = m.supports(K.frameRates)?.arrayValue?.compactMap(\.numberValue) ?? []
        return rates.isEmpty || rates.contains(24) ? 24 : rates[0]
    }

    /// 9 frames at the offer's rate, or its `min_duration_s` where longer.
    static func duration(_ d: Descriptor, _ m: ModelOffer) -> Double {
        max(9 / fps(m), m.limits?.value(L.minDuration) ?? d.limits?.value(L.minDuration) ?? 0)
    }

    static func clipInput(_ p: Probe, _ data: Data? = nil) -> RequestInput {
        .one(.inline(mediaType: "video/mp4", data: data ?? p.clip ?? Data()))
    }

    /// A request offer `m` of `d` can serve, at its cheapest tier and smallest useful size, with every licence its
    /// users must accept accepted. Names the model when `named`.
    static func request(_ p: Probe, _ d: Descriptor, _ m: ModelOffer, named: Bool = true) -> JobRequest {
        var inputs: [String: RequestInput] = [:]
        var params: [String: JSONValue] = [:]
        let has = { (name: String) in d.params["properties"]?[name] != nil }
        switch d.operation {
        case "video.generate":
            inputs[I.prompt] = .text(prompt)
            let (w, h) = size(d, m)
            if has(P.size) { params[P.size] = ["width": .number(Double(w)), "height": .number(Double(h))] }
            if has(P.fps) { params[P.fps] = .number(fps(m)) }
            if has(P.duration) { params[P.duration] = .number(duration(d, m)) }
        case "video.extend":
            inputs[I.video] = clipInput(p)
            inputs[I.prompt] = .text("The kite climbs higher.")
            let grid = VideoProfile.FrameStep(m)
            if has(P.after) { params[P.after] = .number(Double(max(grid.multiple, 8)) / fixtureFPS) }
        case "video.retake":
            inputs[I.video] = clipInput(p)
            inputs[I.prompt] = .text("A blue kite instead.")
            // Late in the 17-frame fixture, so frames before the span stay to compare even on an 8k + 1 grid.
            params[P.start] = 0.4
            params[P.end] = 0.7
        case "video.upscale":
            inputs[I.video] = clipInput(p)
            let contents = list(m, K.content)
            params[P.content] = .string(contents.isEmpty || contents.contains("live_action") ? "live_action" : contents[0])
            let scales = m.supports(K.scales)?.arrayValue?.compactMap(\.intValue) ?? [2, 4]
            if has(P.scale) { params[P.scale] = .number(Double(scales.contains(2) ? 2 : scales.first ?? 2)) }
        case "video.interpolate":
            inputs[I.video] = clipInput(p)
            if has(P.factor) { params[P.factor] = 2 }
        default: break
        }
        if has(P.quality) { params[P.quality] = .string(tier(m).rawValue) }
        return JobRequest(operation: d.operation, inputs: inputs, params: params, model: named ? m.id : nil,
                          policy: Probe.acceptance(d))
    }

    /// A video output's facts, checked against its file (Base §10.1, Video §1.3): `width`, `height`, `fps`, `frames` and
    /// `duration_s` reported and agreeing, and `sample_rate`/`channels` exactly when the file has a track. Returns the
    /// file's frames and facts.
    static func video(_ p: Probe, _ job: Job, _ output: Output) async throws -> (Clip, ClipFacts) {
        let what = "\(job.operation) output \(output.name)"
        try check(output.kind == .video, "\(what) is \(output.kind.rawValue), not video")
        guard let w = output.width, let h = output.height, let fps = output.fps, let frames = output.frames, let duration = output.durationSeconds else {
            throw Failure("\(what) doesn't report width, height, fps, frames and duration_s (Base §10.1, Video §1.3)")
        }
        let (_, data) = try await p.output(job, output.index)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mes-conformance-\(UUID().uuidString).\(output.mediaType == "video/quicktime" ? "mov" : "mp4")")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        let (clip, facts) = try await Clips.read(url)
        try check(facts.width == w && facts.height == h, "\(what): the file is \(facts.width)×\(facts.height), the output says \(w)×\(h)")
        try check(facts.frames == frames, "\(what): the file has \(facts.frames) frames, the output says \(frames)")
        try check(abs(facts.fps - fps) < 0.01, "\(what): the file is \(facts.fps) fps, the output says \(fps)")
        try check(abs(duration - Double(frames) / fps) < 0.5 / fps, "\(what): duration_s \(duration) isn't frames / fps (\(Double(frames) / fps))")
        if facts.hasAudio {
            try check(output.sampleRate == facts.sampleRate && output.channels == facts.channels,
                      "\(what): the file's track is \(facts.sampleRate!) Hz × \(facts.channels!), the output says \(output.sampleRate.map(String.init) ?? "none") × \(output.channels.map(String.init) ?? "none")")
        } else {
            try check(output.sampleRate == nil && output.channels == nil, "\(what) reports sample_rate or channels, but the file has no audio track")
        }
        return (clip, facts)
    }

    static func videoOutput(_ job: Job) throws -> Output {
        guard let o = job.result?.outputs.first(where: { $0.kind == .video }) else { throw Failure("\(job.operation) returned no video output") }
        return o
    }

    static func refuse(_ p: Probe, _ request: JobRequest, _ status: Int, _ code: String, _ what: String) async throws {
        let reply = try await p.wire.json("POST", "jobs", request)
        if reply.status == 201, let job = try? reply.decode(Job.self) { _ = try? await p.wire.send("DELETE", "jobs/\(job.id)") }
        try expect(reply, status, code: code, what, schemas: p.schemas)
    }

    static func find(_ p: Probe, _ op: String, _ test: (ModelOffer) -> Bool) -> (Descriptor, ModelOffer)? {
        guard let d = p.descriptor(op), let m = d.models.first(where: test) else { return nil }
        return (d, m)
    }

    static func effectiveNumber(_ job: Job, _ name: String) -> Double? { job.result?.effective[name]?.numberValue }

    /// The mean error of an output's kept frames against the fixture's, and the worst.
    static func keptError(_ out: Clip, offset: Int, sourceRange: Range<Int>, step: Int = 1) -> (mean: Double, worst: Double) {
        let fixture = Fixtures.clip()
        var errors: [Double] = []
        for i in sourceRange {
            let j = offset + i * step
            guard j < out.frames.count, i < fixture.frames.count, out.width == fixture.width else { continue }
            errors.append(Clips.meanError(out.frames[j], fixture.frames[i]))
        }
        guard !errors.isEmpty else { return (255, 255) }
        return (errors.reduce(0, +) / Double(errors.count), errors.max()!)
    }

    /// A kept frame further than this from the source's (0–255, mean per channel) was regenerated, not re-encoded.
    static let keptTolerance = 16.0

    static let all: [ConformanceTest] = [
        ConformanceTest("VIDEO-001", "Descriptors match the profile table: required inputs and outputs of the right kinds, only vocabulary parameters",
                        spec: "Video §3, §6", applies: { p in offers(contentsOf: videoOps)(p) }) { p in
            for d in p.operations where d.profile == VideoProfile.id {
                guard let spec = VideoProfile.operations.operations[d.operation] else {
                    throw Failure("\(d.operation) isn't a Video 0.1 operation (Base §6 rule 6)")
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
                    try check(output.stream == nil, "\(d.operation) output '\(name)' declares stream; video outputs don't stream in 0.1")
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
        ConformanceTest("VIDEO-002", "Offers' supports keys have the profile's types, offer limits are the profile's fields, and offers with sound state its format",
                        spec: "Video §4", applies: { p in offers(contentsOf: videoOps)(p) }) { p in
            for d in p.operations where d.profile == VideoProfile.id {
                let name = d.operation.split(separator: ".")[1]
                if let limits = d.limits {
                    try p.schemas.require(try JSONValue(encoding: limits), "profiles/video/supports.schema.json#/$defs/\(name)_limits", "\(d.operation) limits")
                }
                for m in d.models {
                    try p.schemas.require(.object(m.supports ?? [:]), "profiles/video/supports.schema.json#/$defs/\(name)_supports", "\(d.operation) / \(m.id) supports")
                    if let limits = m.limits {
                        try p.schemas.require(try JSONValue(encoding: limits), "profiles/video/supports.schema.json#/$defs/\(name)_limits", "\(d.operation) / \(m.id) limits")
                    }
                    if flag(m, K.audio) {
                        try check(m.supports(K.sampleRate)?.intValue != nil && m.supports(K.channels)?.intValue != nil,
                                  "\(d.operation) / \(m.id) makes sound but doesn't state sample_rate and channels (Video §4.1)")
                    }
                }
            }
            return nil
        },
        ConformanceTest("VIDEO-003", "Video outputs report width, height, fps, frames and duration_s, the file agrees, and audio facts appear exactly with a track",
                        spec: "Video §1.3, §1.7, Base §10.1", applies: { p in offers(contentsOf: videoOps)(p) }) { p in
            for d in p.operations where d.profile == VideoProfile.id {
                guard let m = defaultOffer(d) else { continue }
                let job = try await p.succeed(request(p, d, m, named: false))
                _ = try await video(p, job, try videoOutput(job))
                await p.confirm(job)
            }
            return nil
        },
        ConformanceTest("VIDEO-004", "Every MUST input format is accepted: MP4 with H.264 and with HEVC, each with AAC",
                        spec: "Video §1.1", applies: { p in offers("video.interpolate", "video.upscale", "video.retake", "video.extend")(p) }) { p in
            let op = ["video.interpolate", "video.upscale", "video.retake", "video.extend"].first { p.descriptor($0) != nil }!
            let d = p.descriptor(op)!
            guard let m = defaultOffer(d) else { throw Failure("\(op) has no offer to run") }
            for codec in [Clips.Codec.h264, .hevc] {
                var r = request(p, d, m)
                r.inputs?[I.video] = clipInput(p, try await Fixtures.mp4(codec: codec))
                let job = try await p.succeed(r)
                await p.confirm(job)
            }
            return Note("on \(op) / \(m.id)")
        },
        ConformanceTest("VIDEO-005", "generate: frames on the offer's grid, effective duration_s, fps, size and frames as made; size with aspect is 400; an off-grid size snaps",
                        spec: "Video §1.3, §1.4, §2", applies: { p in offers("video.generate")(p) }) { p in
            let d = p.descriptor("video.generate")!
            guard let m = defaultOffer(d) else { throw Failure("video.generate has no offer to run") }
            var r = request(p, d, m)
            let step = m.supports(K.sizeStep)?.intValue ?? 1
            let (w, h) = size(d, m)
            if step > 2 { r.params?[P.size] = ["width": .number(Double(w - step / 4)), "height": .number(Double(h))] }
            r.params?[P.seed] = nil
            let job = try await p.succeed(r)
            let (_, facts) = try await video(p, job, try videoOutput(job))
            try check(VideoProfile.FrameStep(m).admits(facts.frames), "\(m.id) made \(facts.frames) frames, off its frame_step grid")
            if step > 1 {
                try check(facts.width % step == 0 && facts.height % step == 0, "\(m.id) made \(facts.width)×\(facts.height), off its size_step \(step)")
            }
            if step > 2 {
                try check(job.warnings.contains { $0.code == VideoProfile.WarningCode.sizeSnapped },
                          "a \(w - step / 4)×\(h) request on a /\(step) grid ran without size_snapped")
            }
            let e = job.result?.effective ?? [:]
            try check(e[P.fps]?.numberValue.map { abs($0 - facts.fps) < 0.01 } == true, "effective.fps doesn't match the output (\(facts.fps))")
            try check(e["frames"]?.intValue == facts.frames, "effective.frames doesn't match the output's \(facts.frames)")
            try check(e[P.duration]?.numberValue.map { abs($0 - facts.durationSeconds) < 0.5 / facts.fps } == true,
                      "effective.duration_s doesn't match the output's \(facts.durationSeconds) s")
            try check(e[P.size]?["width"]?.intValue == facts.width && e[P.size]?["height"]?.intValue == facts.height,
                      "effective.size doesn't match the output's \(facts.width)×\(facts.height)")
            if m.usesSeed { try check(e[P.seed]?.numberValue != nil, "an unseeded request doesn't report the seed it got") }
            if flag(m, K.audio) {
                try check(facts.sampleRate == m.supports(K.sampleRate)?.intValue && facts.channels == m.supports(K.channels)?.intValue,
                          "\(m.id) declares sound at \(m.supports(K.sampleRate)?.intValue ?? 0) Hz × \(m.supports(K.channels)?.intValue ?? 0); the clip's track is \(facts.sampleRate.map(String.init) ?? "missing")")
            }
            await p.confirm(job)
            if d.params["properties"]?[P.aspect] != nil, d.params["properties"]?[P.size] != nil {
                var both = request(p, d, m)
                both.params?[P.aspect] = "16:9"
                try await refuse(p, both, 400, "invalid_request", "size with aspect")
            }
            return nil
        },
        ConformanceTest("VIDEO-006", "generate: fixed frames route to offers that support them; a named offer that doesn't is 422; keyframes without a time each is 400",
                        spec: "Video §3.1, §4.1", applies: { p in offers("video.generate")(p) }) { p in
            let d = p.descriptor("video.generate")!
            let png = RequestInput.one(.inline(mediaType: "image/png", data: Fixtures.png()))
            var ran: [String] = []
            if let m = d.models.first(where: { flag($0, K.firstFrame) && $0.namedOnly != true }) {
                var r = request(p, d, m)
                r.inputs?[I.firstFrame] = png
                let job = try await p.succeed(r)
                _ = try await video(p, job, try videoOutput(job))
                await p.confirm(job)
                ran.append("first_frame on \(m.id)")
            }
            for (input, key) in [(I.firstFrame, K.firstFrame), (I.lastFrame, K.lastFrame), (I.keyframes, K.keyframes), (I.soundtrack, K.soundtrack)]
                where d.inputs.contains(where: { $0.name == input }) {
                guard let m = d.models.first(where: { !flag($0, key) }) else { continue }
                var r = request(p, d, m)
                r.inputs?[input] = input == I.soundtrack ? .one(.inline(mediaType: "audio/wav", data: Fixtures.wav())) : png
                if input == I.keyframes { r.params?[P.keyframeTimes] = [0.1] }
                try await refuse(p, r, 422, "unsupported_parameter", "\(input) to \(m.id), which lacks supports.\(key)")
            }
            if d.inputs.contains(where: { $0.name == I.keyframes }), let m = d.models.first(where: { flag($0, K.keyframes) }) ?? defaultOffer(d) {
                var r = request(p, d, m)
                r.inputs?[I.keyframes] = png
                try await refuse(p, r, 400, "invalid_request", "keyframes without keyframe_times")
                r.params?[P.keyframeTimes] = [.number(duration(d, m) + 1)]
                try await refuse(p, r, 400, "invalid_request", "a keyframe time past the clip's end")
            }
            return ran.isEmpty ? Note("no offer takes a first frame") : nil
        },
        ConformanceTest("VIDEO-007", "audio: false gives a silent clip; audio: true to an offer without sound is 422",
                        spec: "Video §1.7, §4.1", applies: { p in offers("video.generate")(p) }) { p in
            let d = p.descriptor("video.generate")!
            guard d.params["properties"]?[P.audio] != nil else { return Note("video.generate takes no audio parameter") }
            if let m = d.models.first(where: { flag($0, K.audio) && $0.namedOnly != true }) {
                var r = request(p, d, m)
                r.params?[P.audio] = false
                let job = try await p.succeed(r)
                let (_, facts) = try await video(p, job, try videoOutput(job))
                try check(!facts.hasAudio, "audio: false on \(m.id) gave a clip with an audio track")
                await p.confirm(job)
            }
            if let m = d.models.first(where: { !flag($0, K.audio) }) {
                var r = request(p, d, m)
                r.params?[P.audio] = true
                try await refuse(p, r, 422, "unsupported_parameter", "audio: true to \(m.id), which makes no sound")
            }
            return nil
        },
        ConformanceTest("VIDEO-008", "soundtrack: the output's track lasts as long as the clip; a named offer without soundtrack is 422",
                        spec: "Video §3.1", applies: offering("video.generate", "takes a soundtrack") { flag($0, K.soundtrack) }) { p in
            let (d, m) = find(p, "video.generate") { flag($0, K.soundtrack) && $0.namedOnly != true } ?? find(p, "video.generate") { flag($0, K.soundtrack) }!
            var r = request(p, d, m)
            r.inputs?[I.soundtrack] = .one(.inline(mediaType: "audio/wav", data: Fixtures.wav(seconds: 1)))
            let job = try await p.succeed(r)
            let (_, facts) = try await video(p, job, try videoOutput(job))
            try check(facts.hasAudio, "a clip with a soundtrack has no audio track")
            try check(abs((facts.audioSeconds ?? 0) - facts.durationSeconds) <= 1 / facts.fps + 0.05,
                      "the track is \(facts.audioSeconds ?? 0) s; the clip is \(facts.durationSeconds) s")
            await p.confirm(job)
            return nil
        },
        ConformanceTest("VIDEO-009", "extend: the source plus the added frames on the grid, the source's frames kept; before_s to an offer without extend_before is 422",
                        spec: "Video §1.8, §3.2", applies: { p in offers("video.extend")(p) }) { p in
            let d = p.descriptor("video.extend")!
            guard let m = defaultOffer(d) else { throw Failure("video.extend has no offer to run") }
            let job = try await p.succeed(request(p, d, m))
            let (clip, facts) = try await video(p, job, try videoOutput(job))
            let grid = VideoProfile.FrameStep(m)
            let added = facts.frames - fixtureFrames
            try check(added > 0, "the extended clip has \(facts.frames) frames; the source has \(fixtureFrames)")
            try check(added % grid.multiple == 0, "\(added) frames were added, not whole steps of \(m.id)'s grid (\(grid.multiple))")
            let before = Int(((effectiveNumber(job, P.before) ?? 0) * facts.fps).rounded())
            let overlap = Int(((m.supports(K.overlap)?.numberValue ?? 0) * facts.fps).rounded())
            let kept = keptError(clip, offset: before, sourceRange: 0..<max(1, fixtureFrames - overlap))
            try check(kept.worst <= keptTolerance, "the source's frames weren't kept: a mean error of \(String(format: "%.1f", kept.worst))/255 on one")
            await p.confirm(job)
            if d.params["properties"]?[P.before] != nil, let n = d.models.first(where: { !flag($0, K.extendBefore) }) {
                var r = request(p, d, n)
                r.params?[P.before] = 0.5
                try await refuse(p, r, 422, "unsupported_parameter", "before_s to \(n.id), which extends forward only")
            }
            return Note("source frames kept within \(String(format: "%.1f", kept.mean))/255 on average")
        },
        ConformanceTest("VIDEO-010", "retake: the source's frame count, frames outside the span kept; end_s before start_s is 400; an unlisted retake is 422",
                        spec: "Video §1.8, §3.3", applies: { p in offers("video.retake")(p) }) { p in
            let d = p.descriptor("video.retake")!
            guard let m = defaultOffer(d) else { throw Failure("video.retake has no offer to run") }
            let job = try await p.succeed(request(p, d, m))
            let (clip, facts) = try await video(p, job, try videoOutput(job))
            try check(facts.frames == fixtureFrames, "the retake has \(facts.frames) frames; the source has \(fixtureFrames)")
            let start = Int(((effectiveNumber(job, P.start) ?? 0.25) * facts.fps).rounded())
            let end = Int(((effectiveNumber(job, P.end) ?? 0.5) * facts.fps).rounded())
            let overlap = Int(((m.supports(K.overlap)?.numberValue ?? 0) * facts.fps).rounded())
            let outside = (0..<fixtureFrames).filter { $0 < start - overlap || $0 >= end + overlap }
            var note = "the span covers the clip; nothing outside it to compare"
            if let first = outside.first {
                var worst = 0.0
                for i in outside { worst = max(worst, keptError(clip, offset: 0, sourceRange: i..<(i + 1)).worst) }
                try check(worst <= keptTolerance, "frames outside the span weren't kept: a mean error of \(String(format: "%.1f", worst))/255 on one")
                note = "\(outside.count) frames outside the span kept (from frame \(first))"
            }
            await p.confirm(job)
            var bad = request(p, d, m)
            bad.params?[P.start] = 0.5
            bad.params?[P.end] = 0.25
            try await refuse(p, bad, 400, "invalid_request", "end_s before start_s")
            if d.params["properties"]?[P.retake] != nil,
               let (n, mode) = d.models.lazy.compactMap({ o -> (ModelOffer, String)? in
                   let listed = list(o, K.retake).isEmpty ? ["picture"] : list(o, K.retake)
                   return VideoProfile.retakeModes.first { !listed.contains($0) }.map { (o, $0) }
               }).first {
                var r = request(p, d, n)
                r.params?[P.retake] = .string(mode)
                try await refuse(p, r, 422, "unsupported_parameter", "retake \(mode) to \(n.id), which doesn't list it")
            }
            return Note(note)
        },
        ConformanceTest("VIDEO-011", "upscale: exactly size × scale, the same frames and fps, audio kept; no content is 400; an unlisted content is 422",
                        spec: "Video §1.7, §3.4", applies: { p in offers("video.upscale")(p) }) { p in
            let d = p.descriptor("video.upscale")!
            guard let m = defaultOffer(d) else { throw Failure("video.upscale has no offer to run") }
            let r = request(p, d, m)
            let job = try await p.succeed(r)
            let (_, facts) = try await video(p, job, try videoOutput(job))
            let scale = r.params?[P.scale]?.intValue ?? effectiveNumber(job, P.scale).map { Int($0) } ?? 0
            try check(scale == 2 || scale == 4, "the upscale doesn't report the scale it used (effective.scale)")
            try check(facts.width == 128 * scale && facts.height == 96 * scale, "×\(scale) of 128×96 gave \(facts.width)×\(facts.height)")
            try check(facts.frames == fixtureFrames && abs(facts.fps - fixtureFPS) < 0.01, "the upscale has \(facts.frames) frames at \(facts.fps) fps; the source \(fixtureFrames) at 24")
            try check(facts.hasAudio && abs((facts.audioSeconds ?? 0) - Double(fixtureFrames) / fixtureFPS) <= 0.1,
                      "the source's audio wasn't kept (Video §1.7): the output's track is \(facts.audioSeconds.map { "\($0) s" } ?? "missing")")
            await p.confirm(job)
            var none = request(p, d, m)
            none.params?[P.content] = nil
            try await refuse(p, none, 400, "invalid_request", "an upscale without content")
            if let n = d.models.first(where: { o in !list(o, K.content).isEmpty && list(o, K.content).count < VideoProfile.contents.count }) {
                var other = request(p, d, n)
                other.params?[P.content] = .string(VideoProfile.contents.first { !list(n, K.content).contains($0) }!)
                try await refuse(p, other, 422, "unsupported_parameter", "content \(other.params![P.content]!.stringValue!) to \(n.id), which doesn't list it")
            }
            return nil
        },
        ConformanceTest("VIDEO-012", "interpolate: (N − 1) × factor + 1 frames at fps × factor, source frames kept, audio kept; factor with fps is 400",
                        spec: "Video §1.7, §3.5", applies: { p in offers("video.interpolate")(p) }) { p in
            let d = p.descriptor("video.interpolate")!
            guard let m = defaultOffer(d) else { throw Failure("video.interpolate has no offer to run") }
            let job = try await p.succeed(request(p, d, m))
            let (clip, facts) = try await video(p, job, try videoOutput(job))
            let factor = 2
            try check(facts.frames == (fixtureFrames - 1) * factor + 1, "×\(factor) of \(fixtureFrames) frames gave \(facts.frames), not \((fixtureFrames - 1) * factor + 1)")
            try check(abs(facts.fps - fixtureFPS * Double(factor)) < 0.01, "×\(factor) of 24 fps gave \(facts.fps) fps")
            let kept = keptError(clip, offset: 0, sourceRange: 0..<fixtureFrames, step: factor)
            try check(kept.worst <= keptTolerance, "source frames weren't kept: a mean error of \(String(format: "%.1f", kept.worst))/255 on one")
            try check(facts.hasAudio, "the source's audio wasn't kept (Video §1.7)")
            await p.confirm(job)
            if d.params["properties"]?[P.fps] != nil {
                var both = request(p, d, m)
                both.params?[P.fps] = 48
                try await refuse(p, both, 400, "invalid_request", "factor with fps")
            }
            return Note("source frames kept within \(String(format: "%.1f", kept.mean))/255 on average")
        },
        ConformanceTest("VIDEO-013", "Disclosure: a generated clip says AI-generated in its comment item; upscale and interpolate keep an input's marking",
                        spec: "Video §1.9, Base §10.2", applies: { p in offers("video.generate", "video.upscale", "video.interpolate")(p) }) { p in
            var checked: [String] = []
            if let d = p.descriptor("video.generate"), let m = defaultOffer(d) {
                let job = try await p.succeed(request(p, d, m))
                let (_, facts) = try await video(p, job, try videoOutput(job))
                try check(facts.comment.map(VideoProfile.isDisclosure) == true,
                          "a video.generate clip's comment item doesn't say AI-generated (it is \(facts.comment.map { "\"\($0)\"" } ?? "absent"))")
                await p.confirm(job)
                checked.append("generate")
            }
            let marked = try await Fixtures.mp4(marked: true)
            for op in ["video.upscale", "video.interpolate"] {
                guard let d = p.descriptor(op), let m = defaultOffer(d) else { continue }
                var r = request(p, d, m)
                r.inputs?[I.video] = clipInput(p, marked)
                let job = try await p.succeed(r)
                let (_, facts) = try await video(p, job, try videoOutput(job))
                try check(facts.comment.map(VideoProfile.isDisclosure) == true, "\(op) dropped the input's AI-content marking")
                await p.confirm(job)
                checked.append(op.replacingOccurrences(of: "video.", with: ""))
            }
            return Note("checked \(checked.joined(separator: ", "))")
        },
        ConformanceTest("VIDEO-014", "Previews from an offer with supports.previews are images with at_s inside the clip",
                        spec: "Video §1.14, Base §11", applies: { p in
                            let ops = videoOps.filter { op in p.descriptor(op)?.models.contains { flag($0, K.previews) } == true }
                            return offers(contentsOf: videoOps)(p) ?? (ops.isEmpty ? "no Video offer declares previews" : nil)
                        }) { p in
            let op = videoOps.first { op in p.descriptor(op)?.models.contains { flag($0, K.previews) } == true }!
            let d = p.descriptor(op)!
            let m = d.models.first { flag($0, K.previews) }!
            let job = try await p.succeed(request(p, d, m))
            let output = try videoOutput(job)
            let duration = output.durationSeconds ?? 0
            let (_, frames, _) = try await p.wire.frames("jobs/\(job.id)/events", timeout: 30) { $0.event == "job.output_ready" }
            await p.confirm(job)
            let previews = frames.filter { $0.event == "job.preview" }
            try check(!previews.isEmpty, "\(m.id) declares previews and sent none")
            for f in previews {
                let event = try MESJSON.decoder.decode(JSONValue.self, from: Data(f.data.utf8))
                try p.schemas.require(event, "base/event.schema.json", "a job.preview event")
                let data = event["data"]
                try check(data?["media_type"]?.stringValue?.hasPrefix("image/") == true, "a video preview is \(data?["media_type"]?.stringValue ?? "untyped"), not an image")
                guard let at = data?["at_s"]?.numberValue else { throw Failure("a video preview has no at_s") }
                try check(at >= 0 && at <= duration, "a preview at \(at) s is outside the \(duration) s clip")
            }
            return Note("\(previews.count) preview\(previews.count == 1 ? "" : "s") from \(m.id)")
        },
        ConformanceTest("VIDEO-015", "seed is reported; the same seed reproduces where the offer is deterministic; an output media type not offered is 422",
                        spec: "Video §1.2, §1.13", applies: { p in offers(contentsOf: videoOps)(p) }) { p in
            let op = ["video.generate", "video.upscale", "video.extend", "video.retake", "video.interpolate"]
                .first { op in p.descriptor(op).flatMap(defaultOffer)?.usesSeed == true }
            var note = "no Video offer takes a seed"
            if let op, let d = p.descriptor(op), let m = defaultOffer(d) {
                var r = request(p, d, m)
                r.params?[P.seed] = 7
                let a = try await p.succeed(r)
                try check(a.result?.effective[P.seed]?.intValue == 7, "\(op) doesn't report the seed it was given")
                let b = try await p.succeed(r)
                let (ca, _) = try await video(p, a, try videoOutput(a))
                let (cb, _) = try await video(p, b, try videoOutput(b))
                await p.confirm(a)
                await p.confirm(b)
                try check(ca.frames.count == cb.frames.count && ca.width == cb.width, "the same seed gave clips of different shapes")
                let diff = zip(ca.frames, cb.frames).map { Clips.meanError($0, $1) }.max() ?? 0
                if m.supports(K.deterministic)?.boolValue ?? true {
                    try check(diff < 1, "\(m.id) is deterministic, but the same seed differed by \(String(format: "%.2f", diff))/255 on a frame")
                }
                note = "\(op) / \(m.id): the same seed differed by at most \(String(format: "%.2f", diff))/255\(m.supports(K.deterministic)?.boolValue == false ? " (not deterministic)" : "")"
            }
            for d in p.operations where d.profile == VideoProfile.id {
                guard let offered = d.params["properties"]?[P.output]?["properties"]?["media_type"]?["enum"]?.arrayValue?.compactMap(\.stringValue),
                      let other = ["video/mp4", "video/quicktime"].first(where: { !offered.contains($0) }), let m = defaultOffer(d) else { continue }
                var r = request(p, d, m)
                r.params?[P.output] = ["media_type": .string(other)]
                try await refuse(p, r, 422, "unsupported_parameter", "\(d.operation) output \(other), which the descriptor doesn't offer")
                break
            }
            return Note(note)
        },
    ]
}
