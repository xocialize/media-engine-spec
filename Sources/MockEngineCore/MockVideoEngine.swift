import Foundation
import MESCore
import MESEngineCore

/// A mock Video-profile engine: the five Video 0.1 operations, with synthetic clips that obey the profile's rules, and
/// offers shaped like the fleet's (docs/VIDEO-EVALUATION.md §6), so clients and the conformance suite can exercise
/// grids, routing, gates, audio, previews and users' acceptance. It runs no model: a clip is a coloured field with a bar
/// crossing it, fixed frames fade in and out, and sound is a tone.
///
/// - **generate:** `mock-ltx-compact` (the default; `draft`; one stage: a first frame and a soundtrack, sound at 48 kHz
///   stereo, the 8k + 1 grid, sizes on /32, not bit-deterministic), `mock-ltx-standard` (`standard` and `best`; two
///   stages: last frame and up to 5 keyframes, sizes on /64, previews, two adapters) — both under a licence whose users
///   must accept it — and `mock-video-open` (Apache-2.0, silent, 24/25/30 fps only), which a request without that
///   acceptance gets.
/// - **extend** and **retake:** the two LTX-shaped offers (extend forward only, blending 0.5 s back; retake picture,
///   sound or both, on whole latent frames),
///   and `mock-video-open` (extends both ways, retakes picture only).
/// - **upscale:** `mock-seedvr2` (the default; ×2 natively, ×2 or ×4, live action or drawn) and `mock-flashvsr` (×4
///   natively, live action only, outputs up to 1920×1152).
/// - **interpolate:** `mock-rife` (factors 2–8, no seed).
public struct MockVideoEngine: MediaEngine {
    /// Delay per progress step, as the other mocks'.
    public var stepDelay: Duration

    public init(stepDelay: Duration = .zero) { self.stepDelay = stepDelay }

    typealias P = VideoProfile.Param
    typealias I = VideoProfile.Input
    typealias K = VideoProfile.SupportsKey
    typealias L = VideoProfile.LimitField

    /// A stand-in for the LTX-2 Community Licence (Video §1.10): the operator accepts it at first enable, and each user
    /// accepts it at their client.
    public static let communityLicense = License(
        spdx: "LicenseRef-Mock-Video-Community", commercialUse: .yes, termsURL: "https://example.com/mock-video-community-license",
        notice: "Mock Video Community License: use restrictions apply; entities with $10M or more in annual revenue need a "
            + "commercial licence; say that what you publish is machine-generated.",
        acceptedRequired: true, userAcceptRequired: true)
    static let mit = License(spdx: "MIT", commercialUse: .yes, termsURL: "https://opensource.org/license/mit")
    static let imageTypes = ["image/png", "image/jpeg"]
    static let audioTypes = ["audio/wav", "audio/flac", "audio/mpeg", "audio/mp4"]
    static let videoTypes = ["video/mp4", "video/quicktime"]
    static let ltxGrid: JSONValue = ["multiple": 8, "offset": 1]
    /// The defaults a request without them gets: small, so mock jobs stay fast.
    static let defaultSize = (width: 256, height: 256), defaultFPS = 24.0, defaultFrames = 9

    // MARK: - Descriptors

    public func descriptors() async -> [Descriptor] {
        VideoProfile.operations.operations.keys.sorted().map(Self.descriptor)
    }

    static func offer(_ id: String, _ title: String, license: License = communityLicense, tiers: [QualityTier],
                      isDefault: Bool? = nil, notes: String? = nil, adapters: [AdapterOffer]? = nil,
                      supports: [String: JSONValue], limits: Descriptor.Limits? = nil) -> ModelOffer {
        ModelOffer(id: id, title: title, license: license, memoryClass: .medium, speedClass: .slow, qualityTiers: tiers,
                   isDefault: isDefault, notes: notes, adapters: adapters, supports: supports, limits: limits)
    }

    static let sound: [String: JSONValue] = ["audio": true, "sample_rate": 48_000, "channels": 2, "negative_prompt": false]

    static func models(_ operation: String) -> [ModelOffer] {
        let compactLimits = Descriptor.Limits(maxWidth: 704, maxHeight: 512, maxDurationSeconds: 10,
                                              profile: [L.maxFrames: 121, L.minWidth: 64, L.minHeight: 64, L.maxSoundtrackSeconds: 10])
        let standardLimits = Descriptor.Limits(maxWidth: 1280, maxHeight: 704, maxDurationSeconds: 20,
                                               profile: [L.maxFrames: 161, L.minWidth: 64, L.minHeight: 64, L.maxKeyframes: 5,
                                                         L.maxSoundtrackSeconds: 20])
        let adapters = [
            AdapterOffer(id: "mock-style-lora", title: "Mock style LoRA", strength: .init(min: 0, max: 2, defaultValue: 1),
                         license: .apache2, notes: "Paints everything in a warm tint."),
            AdapterOffer(id: "mock-union-control", title: "Mock union control", kind: .ic,
                         slots: [.init(role: "control", kind: .video, notes: "A pose, depth or edge clip")],
                         strength: .init(min: 0, max: 2, defaultValue: 1), license: .apache2),
        ]
        switch operation {
        case "video.generate":
            return [
                offer("mock-ltx-compact", "Mock LTX compact (one stage)", tiers: [.draft], isDefault: true,
                      notes: "Describe the shot, the motion and the sound. Keyframes need the standard offer.",
                      supports: sound.merging(["first_frame": true, "soundtrack": true, "size_step": 32, "frame_step": ltxGrid,
                                               "deterministic": false]) { $1 },
                      limits: compactLimits),
                offer("mock-ltx-standard", "Mock LTX standard (two stages)", tiers: [.standard, .best],
                      notes: "First and last frame, and up to 5 keyframes at times.", adapters: adapters,
                      supports: sound.merging(["first_frame": true, "last_frame": true, "keyframes": true, "soundtrack": true,
                                               "size_step": 64, "frame_step": ltxGrid, "previews": true]) { $1 },
                      limits: standardLimits),
                offer("mock-video-open", "Mock open video", license: .apache2, tiers: [.draft, .standard],
                      notes: "Silent clips at 24, 25 or 30 fps.",
                      supports: ["first_frame": true, "frame_rates": [24, 25, 30]],
                      limits: .init(maxWidth: 512, maxHeight: 512, maxDurationSeconds: 5, profile: [L.maxFrames: 150])),
            ]
        case "video.extend":
            let ext: [String: JSONValue] = sound.merging(["frame_step": ltxGrid, "overlap_s": 0.5]) { $1 }
            return [
                offer("mock-ltx-compact", "Mock LTX compact (one stage)", tiers: [.draft], isDefault: true,
                      supports: ext.merging(["deterministic": false]) { $1 },
                      limits: .init(maxWidth: 704, maxHeight: 512, maxDurationSeconds: 10,
                                    profile: [L.maxFrames: 121, L.maxSourceSeconds: 10, L.maxExtendSeconds: 5])),
                offer("mock-ltx-standard", "Mock LTX standard (two stages)", tiers: [.standard, .best], supports: ext,
                      limits: .init(maxWidth: 1280, maxHeight: 704, maxDurationSeconds: 20,
                                    profile: [L.maxFrames: 161, L.maxSourceSeconds: 20, L.maxExtendSeconds: 10])),
                offer("mock-video-open", "Mock open video", license: .apache2, tiers: [.draft, .standard],
                      notes: "Extends before and after; silent.", supports: ["extend_before": true],
                      limits: .init(maxDurationSeconds: 10, profile: [L.maxSourceSeconds: 5, L.maxExtendSeconds: 5])),
            ]
        case "video.retake":
            let re: [String: JSONValue] = sound.merging(["frame_step": ltxGrid, "retake": ["picture", "sound", "both"]]) { $1 }
            return [
                offer("mock-ltx-compact", "Mock LTX compact (one stage)", tiers: [.draft], isDefault: true,
                      supports: re.merging(["deterministic": false]) { $1 },
                      limits: .init(profile: [L.maxSourceSeconds: 10, L.maxRetakeSeconds: 5])),
                offer("mock-ltx-standard", "Mock LTX standard (two stages)", tiers: [.standard, .best], supports: re,
                      limits: .init(profile: [L.maxSourceSeconds: 20, L.maxRetakeSeconds: 10])),
                offer("mock-video-open", "Mock open video", license: .apache2, tiers: [.draft, .standard],
                      notes: "Retakes the picture only.", supports: ["retake": ["picture"]],
                      limits: .init(profile: [L.maxSourceSeconds: 5, L.maxRetakeSeconds: 2])),
            ]
        case "video.upscale":
            return [
                offer("mock-seedvr2", "Mock SeedVR2", license: .apache2, tiers: [.draft, .standard, .best], isDefault: true,
                      notes: "×2 natively; fine for drawn and live-action video.",
                      supports: ["scales": [2, 4], "content": ["live_action", "drawn"]],
                      limits: .init(maxWidth: 3840, maxHeight: 2160, profile: [L.maxSourceSeconds: 60])),
                offer("mock-flashvsr", "Mock FlashVSR", license: .apache2, tiers: [.standard],
                      notes: "×4 natively; live action only (it invents texture on drawings).",
                      supports: ["scales": [2, 4], "content": ["live_action"]],
                      limits: .init(maxWidth: 1920, maxHeight: 1152, profile: [L.maxSourceSeconds: 60])),
            ]
        case "video.interpolate":
            return [offer("mock-rife", "Mock RIFE", license: mit, tiers: [.draft, .standard, .best], isDefault: true,
                          notes: "Integer factors from 2 to 8.", supports: ["seed": false],
                          limits: .init(profile: [L.maxFactor: 8, L.maxFPS: 240, L.maxSourceSeconds: 60]))]
        default:
            return []
        }
    }

    static func descriptor(_ operation: String) -> Descriptor {
        let spec = VideoProfile.operations.operations[operation]!
        let inputs = spec.inputs.sorted { $0.key < $1.key }.map { name, io in
            let max: Int? = switch name {
            case I.keyframes: 5
            case I.references: 4
            case I.control: 2
            default: io.kind == .text ? nil : 1
            }
            let types: [String]? = switch io.kind {
            case .image: imageTypes
            case .audio: audioTypes
            case .video: videoTypes
            default: nil
            }
            return InputSpec(name: name, kind: io.kind, required: io.required ?? false, max: max, mediaTypes: types)
        }
        var properties: [String: JSONValue] = [:]
        for (order, name) in spec.vocabulary.enumerated() {
            guard case .object(var schema)? = VideoProfile.vocabularySchema(name, operation: operation) else { continue }
            if name == P.output, case .object(var fields)? = schema["properties"] {
                fields["media_type"] = ["enum": ["video/mp4"]]          // the mock writes MP4, in either codec
                schema["properties"] = .object(fields)
            }
            if name == P.keyframeTimes { schema["maxItems"] = 5 }
            schema["x-mes-ui"] = .object(ui(name, order: order))
            properties[name] = .object(schema)
        }
        let outputs = [OutputSpec(name: "video", kind: .video, mediaTypes: ["video/mp4"], min: 1, max: 1)]
        let limits: Descriptor.Limits = switch operation {
        case "video.generate": .init(maxWidth: 1280, maxHeight: 704, maxDurationSeconds: 20,
                                     profile: [L.maxFrames: 161, L.minWidth: 64, L.minHeight: 64, L.maxKeyframes: 5,
                                               L.maxSoundtrackSeconds: 20])
        case "video.extend": .init(maxWidth: 1280, maxHeight: 704, maxDurationSeconds: 20,
                                   profile: [L.maxFrames: 161, L.maxSourceSeconds: 20, L.maxExtendSeconds: 10])
        case "video.retake": .init(profile: [L.maxSourceSeconds: 20, L.maxRetakeSeconds: 10])
        case "video.upscale": .init(maxWidth: 3840, maxHeight: 2160, profile: [L.maxSourceSeconds: 60])
        default: .init(profile: [L.maxFactor: 8, L.maxFPS: 240, L.maxSourceSeconds: 60])
        }
        return Descriptor(
            operation: operation, profile: VideoProfile.id, profileVersion: VideoProfile.version, title: title(operation),
            summary: "Mock: synthetic clips that follow the Video profile's rules.", inputs: inputs,
            params: .object(["type": "object", "additionalProperties": false, "properties": .object(properties)]),
            outputs: outputs, limits: limits, qualityTiers: [.draft, .standard, .best], models: models(operation),
            remote: .init(possible: false))
    }

    static func title(_ op: String) -> String {
        ["video.generate": "Generate a clip", "video.extend": "Extend a clip", "video.retake": "Retake part of a clip",
         "video.upscale": "Upscale a video", "video.interpolate": "Interpolate frames"][op] ?? op
    }

    static func ui(_ name: String, order: Int) -> [String: JSONValue] {
        let widgets = ["seed": "seed", "quality": "picker", "size": "size", "aspect": "aspect", "audio": "toggle",
                       "negative_prompt": "textarea", "duration_s": "slider", "fps": "slider", "retake": "picker",
                       "scale": "picker", "content": "picker", "factor": "stepper", "prompt_enhance": "picker",
                       "resolution": "stepper", "after_s": "slider", "before_s": "slider", "start_s": "slider", "end_s": "slider"]
        let labels = ["duration_s": "Duration (s)", "fps": "Frame rate", "after_s": "Add after (s)", "before_s": "Add before (s)",
                      "start_s": "From (s)", "end_s": "To (s)", "keyframe_times": "Keyframe times (s)"]
        var hints: [String: JSONValue] = ["label": .string(labels[name] ?? name.replacingOccurrences(of: "_", with: " ").capitalized),
                                          "order": .number(Double(order))]
        if let w = widgets[name] { hints["widget"] = .string(w) }
        if ["seed", "output", "negative_prompt", "prompt_enhance", "keyframe_times", "resolution"].contains(name) { hints["advanced"] = true }
        return hints
    }

    public func validate(_ request: JobRequest, descriptor: Descriptor) throws {
        try VideoProfileRules.validate(request, descriptor: descriptor)
    }

    // MARK: - Running

    public func run(_ context: RunContext) async throws -> RunOutput {
        var job = Job(context: context, stepDelay: stepDelay)
        return try await job.run()
    }

    /// One run: the context, and what the run has said so far.
    struct Job {
        let context: RunContext
        let stepDelay: Duration
        var warnings: [Warning] = []
        var effective: [String: JSONValue] = ["model_params": ["mock": true]]

        init(context: RunContext, stepDelay: Duration) { self.context = context; self.stepDelay = stepDelay }

        var model: ModelOffer { context.model }
        var grid: VideoProfile.FrameStep { VideoProfile.FrameStep(model) }
        var makesSound: Bool { model.supports(K.audio)?.boolValue == true }
        var seed: Int { context.param(P.seed)?.intValue ?? Int(Tones.hash(context.jobID) % 1_000_000) }
        var prompt: String { context.input(I.prompt)?.text ?? "" }

        func step(_ phase: String, _ n: Int) async throws {
            for i in 1...max(1, n) {
                try Task.checkCancellation()
                if stepDelay > .zero { try await Task.sleep(for: stepDelay) }
                await context.reporter.progress(.running, phase: phase, step: i, steps: n)
            }
        }

        mutating func warn(_ code: String, _ message: String, param: String? = nil) {
            warnings.append(Warning(code: code, message: message, param: param))
        }

        mutating func run() async throws -> RunOutput {
            let clip: Clip
            switch context.operation {
            case "video.generate": clip = try await generate()
            case "video.extend": clip = try await extend()
            case "video.retake": clip = try await retake()
            case "video.upscale": clip = try await upscale()
            case "video.interpolate": clip = try await interpolate()
            default: throw MESError(.unknownOperation, "No operation \(context.operation).")
            }
            try await step(VideoProfile.Phase.mux, 1)
            let codec = Clips.Codec(rawValue: context.param(P.output)?["codec"]?.stringValue ?? "h264") ?? .h264
            let url = context.outputDirectory.appendingPathComponent("video.mp4")
            try await Clips.write(clip, to: url, codec: codec)
            effective[P.fps] = .number(clip.fps)
            effective[P.size] = ["width": .number(Double(clip.width)), "height": .number(Double(clip.height))]
            effective["frames"] = .number(Double(clip.frames.count))
            effective[P.duration] = .number(clip.durationSeconds)
            effective[P.audio] = .bool(clip.audio != nil)
            let output = ProducedOutput.video(url, width: clip.width, height: clip.height, fps: clip.fps, frames: clip.frames.count,
                                              sampleRate: clip.audio == nil ? nil : clip.sampleRate,
                                              channels: clip.audio == nil ? nil : clip.channels)
            return RunOutput(outputs: [output], effective: effective, seed: model.usesSeed ? seed : nil, warnings: warnings)
        }

        // MARK: Inputs

        mutating func source() async throws -> Clip {
            guard let url = context.input(I.video)?.fileURL else {
                throw MESError(.invalidRequest, "Input 'video' is missing.", param: I.video)
            }
            let clip: Clip
            do { clip = try await Clips.read(url).0 } catch {
                throw MESError(.inputInvalid, "The video can't be read: \(error).", param: I.video)
            }
            guard !clip.frames.isEmpty else { throw MESError(.inputInvalid, "The video has no frames.", param: I.video) }
            if let max = model.limits?.value(L.maxSourceSeconds) ?? context.descriptor.limits?.value(L.maxSourceSeconds),
               clip.durationSeconds > max + 0.001 {
                throw MESError(.outOfLimits, "The video is \(String(format: "%.2f", clip.durationSeconds)) s; \(model.title) takes at most \(max) s.",
                               param: I.video)
            }
            return clip
        }

        /// The audio input as interleaved stereo at 48 kHz (Audio §1.3), with the warnings that cost.
        mutating func soundtrack() throws -> [Float]? {
            guard let url = context.input(I.soundtrack)?.fileURL else { return nil }
            let (mono, rate, _) = try Tones.read(url)
            if rate != 48_000 {
                warn(VideoProfile.WarningCode.audioResampled, "The soundtrack was resampled from \(rate) Hz to 48 kHz.", param: I.soundtrack)
            }
            return Tones.resample(mono, from: rate, to: 48_000).flatMap { [$0, $0] }
        }

        func tone(seconds: Double, seed: Int) -> [Float] {
            let hz = 180 + Double(Tones.hash(prompt) % 300) + Double(seed % 40)
            return Tones.tone(hz, seconds: seconds, rate: 48_000, level: 0.2).flatMap { [$0, $0 * 0.8] }
        }

        func color(_ salt: Int = 0) -> (UInt8, UInt8, UInt8) { Palette.color(prompt, seed: seed &+ salt) }

        /// The frame count limit that applies: the offer's `max_frames`, else the operation's.
        var maxFrames: Int? { (model.limits?.value(L.maxFrames) ?? context.descriptor.limits?.value(L.maxFrames)).map { Int($0) } }

        func checkSize(_ w: Int, _ h: Int, param: String) throws {
            let limits = model.limits
            if let mw = limits?.maxWidth, w > mw { throw MESError(.outOfLimits, "\(model.title) makes at most \(mw) px wide; this is \(w).", param: param) }
            if let mh = limits?.maxHeight, h > mh { throw MESError(.outOfLimits, "\(model.title) makes at most \(mh) px high; this is \(h).", param: param) }
            if let minW = limits?.value(L.minWidth), Double(w) < minW { throw MESError(.outOfLimits, "\(model.title) makes at least \(Int(minW)) px wide.", param: param) }
            if let minH = limits?.value(L.minHeight), Double(h) < minH { throw MESError(.outOfLimits, "\(model.title) makes at least \(Int(minH)) px high.", param: param) }
        }

        // MARK: Operations

        mutating func generate() async throws -> Clip {
            let params = context.params
            try await step(VideoProfile.Phase.encode, 1)
            // Size: asked for, snapped to the grid (§1.4), within the limits.
            var (w, h) = VideoProfileRules.requestedSize(params) ?? MockVideoEngine.defaultSize
            let step = model.supports(K.sizeStep)?.intValue ?? 1
            let snapped = VideoProfile.snap(width: w, height: h, step: max(2, step))
            if snapped != (w, h) {
                warn(VideoProfile.WarningCode.sizeSnapped, "\(w)×\(h) was snapped to \(snapped.width)×\(snapped.height), \(model.title)'s grid.",
                     param: params[P.size] != nil ? P.size : P.resolution)
                (w, h) = snapped
            }
            try checkSize(w, h, param: params[P.size] != nil ? P.size : P.resolution)
            let fps = params[P.fps]?.numberValue ?? MockVideoEngine.defaultFPS
            // Length: asked for, or the soundtrack's, or the default; on the grid; within the limits.
            var track = try soundtrack()
            let wanted = params[P.duration]?.numberValue ?? track.map { Double($0.count / 2) / 48_000 }
            var frames = wanted.map { VideoProfile.frames(seconds: $0, fps: fps, grid: grid) } ?? grid.nearest(Double(MockVideoEngine.defaultFrames))
            if let max = maxFrames, frames > max, let fitted = grid.floor(max) {
                guard params[P.duration] == nil else {
                    throw MESError(.outOfLimits, "\(frames) frames is more than \(model.title)'s \(max).", param: P.duration)
                }
                frames = fitted
            }
            if let wanted, abs(Double(frames) / fps - wanted) > 0.5 / fps, params[P.duration] != nil {
                warn(VideoProfile.WarningCode.durationSnapped,
                     "\(wanted) s at \(fps) fps was snapped to \(frames) frames (\(String(format: "%.3f", Double(frames) / fps)) s), \(model.title)'s grid.",
                     param: P.duration)
            }
            let seconds = Double(frames) / fps
            // Fixed frames (§3.1): the first and last, and keyframes at their times.
            var anchors: [Int: [UInt8]] = [:]
            if let url = context.input(I.firstFrame)?.fileURL { anchors[0] = try Clips.frame(contentsOf: url, width: w, height: h) }
            if let url = context.input(I.lastFrame)?.fileURL { anchors[frames - 1] = try Clips.frame(contentsOf: url, width: w, height: h) }
            let times = params[P.keyframeTimes]?.arrayValue?.compactMap(\.numberValue) ?? []
            for (i, value) in (context.inputs[I.keyframes] ?? []).enumerated() where i < times.count {
                guard let url = value.fileURL else { continue }
                if times[i] >= seconds {
                    throw MESError(.invalidRequest, "A keyframe at \(times[i]) s isn't inside the \(String(format: "%.3f", seconds)) s clip.",
                                   param: P.keyframeTimes)
                }
                anchors[min(frames - 2, max(1, Int((times[i] * fps).rounded())))] = try Clips.frame(contentsOf: url, width: w, height: h)
            }
            try await self.step(VideoProfile.Phase.denoise, model.qualityTiers.contains(.draft) ? 4 : 8)
            let base = color(), tint = !context.adapters.isEmpty
            var out = (0..<frames).map { i -> [UInt8] in
                var frame = Clips.synthetic(width: w, height: h, color: base, t: frames > 1 ? Double(i) / Double(frames - 1) : 0)
                if tint { frame = Clips.blend(frame, [UInt8](repeating: 60, count: frame.count), 0.15) }
                return frame
            }
            for (index, image) in anchors {
                for i in 0..<frames {
                    let d = abs(i - index)
                    if d == 0 { out[i] = image } else if d < 4 { out[i] = Clips.blend(image, out[i], Double(d) / 4) }
                }
            }
            if model.supports(K.previews)?.boolValue == true {
                let mid = frames / 2
                if let jpeg = Clips.encode(out[mid], width: w, height: h) {
                    await context.reporter.preview(jpeg, mediaType: "image/jpeg", output: "video", atSeconds: Double(mid) / fps, frame: mid)
                }
            }
            try await self.step(VideoProfile.Phase.decode, 2)
            // Sound (§1.7): the soundtrack, fitted; else the model's own; or none.
            var audio: [Float]?
            if context.param(P.audio)?.boolValue != false {
                if var t = track {
                    let n = Tones.frames(seconds, rate: 48_000) * 2
                    if t.count != n {
                        warn(VideoProfile.WarningCode.soundtrackFitted,
                             "The soundtrack (\(String(format: "%.2f", Double(t.count / 2) / 48_000)) s) was \(t.count > n ? "cut" : "padded") to the clip.",
                             param: I.soundtrack)
                        t = t.count > n ? Array(t.prefix(n)) : t + [Float](repeating: 0, count: n - t.count)
                    }
                    audio = t
                } else if makesSound {
                    audio = tone(seconds: seconds, seed: seed)
                }
            }
            track = nil
            return Clip(width: w, height: h, fps: fps, frames: out, audio: audio, comment: VideoProfile.disclosure(model: model.title),
                        copyright: copyright())
        }

        mutating func extend() async throws -> Clip {
            var src = try await source()
            try await step(VideoProfile.Phase.encode, 1)
            let after = context.param(P.after)?.numberValue ?? (context.param(P.before) == nil ? 1 : 0)
            let before = context.param(P.before)?.numberValue ?? 0
            // The added frames are whole grid steps, so a source on the grid gives an output on it (§3.2).
            func added(_ seconds: Double) -> Int {
                guard seconds > 0 else { return 0 }
                return max(grid.multiple, Int((seconds * src.fps / Double(grid.multiple)).rounded()) * grid.multiple)
            }
            let (pre, post) = (added(before), added(after))
            if abs(Double(pre + post) / src.fps - (before + after)) > 0.5 / src.fps {
                warn(VideoProfile.WarningCode.durationSnapped, "Adding \(before + after) s became \(pre + post) frames on \(model.title)'s grid.",
                     param: post > 0 ? P.after : P.before)
            }
            let total = pre + src.frames.count + post
            if let max = maxFrames, total > max {
                throw MESError(.outOfLimits, "The extended clip would be \(total) frames; \(model.title) makes at most \(max).", param: P.after)
            }
            try await step(VideoProfile.Phase.denoise, 4)
            let base = color()
            let first = src.frames.first!, last = src.frames.last!
            let head = (0..<pre).map { i in Clips.blend(Clips.synthetic(width: src.width, height: src.height, color: base, t: Double(i) / Double(max(1, pre))),
                                                        first, Double(i + 1) / Double(pre + 1)) }
            let tail = (0..<post).map { i in Clips.blend(last, Clips.synthetic(width: src.width, height: src.height, color: base,
                                                                                t: Double(i + 1) / Double(post)), Double(i + 1) / Double(post + 1)) }
            try await step(VideoProfile.Phase.decode, 1)
            // Sound: the source's under the source; the model's, or silence, under the new parts.
            var audio: [Float]?
            if context.param(P.audio)?.boolValue != false, src.audio != nil || makesSound {
                let rate = src.audio != nil ? src.sampleRate : 48_000
                let ch = src.audio != nil ? src.channels : 2
                func pad(_ frames: Int) -> [Float] {
                    let n = Tones.frames(Double(frames) / src.fps, rate: rate) * ch
                    if makesSound, rate == 48_000, ch == 2 { return Tones.fit(tone(seconds: Double(frames) / src.fps, seed: seed), count: n) }
                    return [Float](repeating: 0, count: n)
                }
                let middle = Tones.fit(src.audio ?? [], count: Tones.frames(src.durationSeconds, rate: rate) * ch)
                audio = pad(pre) + middle + pad(post)
                src.sampleRate = rate; src.channels = ch
            } else if context.param(P.audio)?.boolValue == true {
                warn(VideoProfile.WarningCode.audioUnavailable, "The source has no sound and \(model.title) makes none.", param: P.audio)
            }
            effective[P.after] = .number(Double(post) / src.fps)
            effective[P.before] = .number(Double(pre) / src.fps)
            return Clip(width: src.width, height: src.height, fps: src.fps, frames: head + src.frames + tail, audio: audio,
                        sampleRate: src.sampleRate, channels: src.channels, comment: VideoProfile.disclosure(model: model.title),
                        copyright: copyright())
        }

        mutating func retake() async throws -> Clip {
            var src = try await source()
            let start = context.param(P.start)?.numberValue ?? 0, end = context.param(P.end)?.numberValue ?? 0
            guard end <= src.durationSeconds + 0.5 / src.fps else {
                throw MESError(.outOfLimits, "The span ends at \(end) s; the source is \(String(format: "%.3f", src.durationSeconds)) s.", param: P.end)
            }
            let modes = model.supports(K.retake)?.arrayValue?.compactMap(\.stringValue) ?? ["picture"]
            let mode = context.param(P.retake)?.stringValue ?? (modes.contains("both") ? "both" : "picture")
            if mode != "picture", src.audio == nil {
                throw MESError(.inputInvalid, "Retaking \(mode) needs a source with sound; this one is silent.", param: P.retake)
            }
            // The span widens to whole grid steps (§3.3): on an 8k + 1 grid the steps start at frames 1, 9, 17, ….
            let m = grid.multiple, o = min(grid.offset, 1)
            var a = Int((start * src.fps).rounded()), b = Int((end * src.fps).rounded())
            let wa = max(0, a < o ? 0 : (a - o) / m * m + o)
            let wb = min(src.frames.count, b <= o ? o : (b - o + m - 1) / m * m + o)
            if Double(a - wa) > 0.5 || Double(wb - b) > 0.5 {
                warn(VideoProfile.WarningCode.spanSnapped,
                     "The span was widened to frames \(wa)–\(wb) (\(String(format: "%.3f", Double(wa) / src.fps))–\(String(format: "%.3f", Double(wb) / src.fps)) s), "
                     + "\(model.title)'s grid.", param: P.start)
            }
            (a, b) = (wa, max(wa + 1, wb))
            try await step(VideoProfile.Phase.denoise, 4)
            if mode != "sound" {
                let base = color(1)
                for i in a..<b { src.frames[i] = Clips.synthetic(width: src.width, height: src.height, color: base, t: Double(i - a) / Double(max(1, b - a - 1))) }
            }
            if mode != "picture", var samples = src.audio {
                let ch = src.channels
                let s0 = Tones.frames(Double(a) / src.fps, rate: src.sampleRate) * ch, s1 = min(samples.count, Tones.frames(Double(b) / src.fps, rate: src.sampleRate) * ch)
                if s1 > s0 {
                    let fresh = Tones.fit(Tones.tone(330, seconds: Double(b - a) / src.fps, rate: src.sampleRate, level: 0.2)
                        .flatMap { Array(repeating: $0, count: ch) }, count: s1 - s0)
                    samples.replaceSubrange(s0..<s1, with: fresh)
                }
                src.audio = samples
            }
            try await step(VideoProfile.Phase.decode, 1)
            if context.param(P.audio)?.boolValue == false { src.audio = nil }
            effective[P.start] = .number(Double(a) / src.fps)
            effective[P.end] = .number(Double(b) / src.fps)
            effective[P.retake] = .string(mode)
            src.comment = VideoProfile.disclosure(model: model.title)
            src.copyright = copyright()
            return src
        }

        mutating func upscale() async throws -> Clip {
            let src = try await source()
            let scales = model.supports(K.scales)?.arrayValue?.compactMap(\.intValue) ?? [2, 4]
            let scale = context.param(P.scale)?.intValue ?? (model.id == "mock-flashvsr" ? 4 : (scales.first ?? 2))
            let (w, h) = (src.width * scale, src.height * scale)
            if let mw = model.limits?.maxWidth, w > mw { throw MESError(.outOfLimits, "×\(scale) makes \(w) px wide; \(model.title) makes at most \(mw).", param: I.video) }
            if let mh = model.limits?.maxHeight, h > mh { throw MESError(.outOfLimits, "×\(scale) makes \(h) px high; \(model.title) makes at most \(mh).", param: I.video) }
            var frames: [[UInt8]] = []
            for (i, frame) in src.frames.enumerated() {
                try Task.checkCancellation()
                frames.append(Clips.scaled(frame, width: src.width, height: src.height, to: w, h))
                await context.reporter.progress(.running, phase: VideoProfile.Phase.upscale, step: i + 1, steps: src.frames.count,
                                                mediaSeconds: Double(i + 1) / src.fps)
            }
            effective[P.scale] = .number(Double(scale))
            effective[P.content] = context.param(P.content) ?? .null
            // Sound and markings travel (§1.7, §1.9): the source's track and comment, unchanged.
            return Clip(width: w, height: h, fps: src.fps, frames: frames, audio: src.audio,
                        sampleRate: src.sampleRate, channels: src.channels, comment: src.comment, copyright: src.copyright)
        }

        mutating func interpolate() async throws -> Clip {
            let src = try await source()
            let maxFactor = Int(model.limits?.value(L.maxFactor) ?? 8)
            var factor = context.param(P.factor)?.intValue ?? 2
            if let target = context.param(P.fps)?.numberValue {
                factor = min(maxFactor, max(2, Int((target / src.fps).rounded())))
                if abs(Double(factor) * src.fps - target) > 0.01 {
                    warn(VideoProfile.WarningCode.fpsAdjusted, "\(target) fps isn't a factor of the source's \(src.fps) fps; the clip is \(Double(factor) * src.fps) fps.",
                         param: P.fps)
                }
            }
            guard src.frames.count >= 2 else { throw MESError(.inputInvalid, "Interpolating needs at least two frames.", param: I.video) }
            var frames: [[UInt8]] = []
            for i in 0..<(src.frames.count - 1) {
                try Task.checkCancellation()
                frames.append(src.frames[i])
                for k in 1..<factor { frames.append(Clips.blend(src.frames[i], src.frames[i + 1], Double(k) / Double(factor))) }
                await context.reporter.progress(.running, phase: VideoProfile.Phase.interpolate, step: i + 1, steps: src.frames.count - 1,
                                                mediaSeconds: Double(frames.count) / (src.fps * Double(factor)))
            }
            frames.append(src.frames.last!)
            effective[P.factor] = .number(Double(factor))
            return Clip(width: src.width, height: src.height, fps: src.fps * Double(factor), frames: frames,
                        audio: src.audio, sampleRate: src.sampleRate,
                        channels: src.channels, comment: src.comment, copyright: src.copyright)
        }

        /// The copyright item (Base §10.2 rule 2): the licence's id and notice.
        func copyright() -> String {
            ([model.license.spdx] + [model.license.notice].compactMap { $0 }).joined(separator: ". ")
        }
    }
}
