import Foundation
import MESCore
import MESEngineCore

/// A mock Audio-profile engine: the six Audio 0.1 operations, with synthetic results that obey the profile's rules and
/// offers that differ in what they support (Base §6.4), so clients and the conformance suite can exercise routing,
/// gates, voices, streaming and assets. It runs no model: speech is tone bursts, sounds are seeded noise, songs are
/// chords.
///
/// - **speak** has three offers: `mock-presets` (three preset voices and a default voice, a few emotions, styles and
///   cues, no seed), `mock-clone` (cloning, streaming at 22.05 kHz, emotion intensity, target duration) and
///   `mock-clone-research` (`named_only`, a research licence, needs the reference's transcript).
/// - **edit_speech**: `mock-editor` (the default; a transcript is required) and `mock-editor-research` (`named_only`;
///   every edit kind, keeps the length, adds cues only at an edge, removes one kind of cue at a time, fits an edit to a
///   length: AuK's shape, RFC 0006).
/// - **separate**: `mock-separator` (the default; masked `vocals` and `instrumental`, the second the mixture minus the
///   first), `mock-separator-voices` (`named_only`; regenerated `speaker`, `singing` and `voices`, a speaker picked
///   either way, ≤ 30 s), `mock-separator-flash` (regenerated `speaker` and `singing`, picked only by words) and
///   `mock-separator-described` (regenerated `target` and `residual` for a sound the request describes, with spans,
///   ≤ 10 s: SAM-Audio's shape, RFC 0008).
/// - **compose**: `mock-composer` (MIT-like, the default), `mock-composer-research` (`named_only`, non-commercial, with a
///   notice and a score) and `mock-composer-notice` (commercial, with a name to display).
public struct MockAudioEngine: MediaEngine {
    /// Delay per progress step, as the image mock's.
    public var stepDelay: Duration
    /// Delay between streamed chunks of a quarter second each.
    public var chunkDelay: Duration

    public init(stepDelay: Duration = .zero, chunkDelay: Duration = .milliseconds(20)) {
        self.stepDelay = stepDelay
        self.chunkDelay = chunkDelay
    }

    static let mockLicense = License.apache2
    static let researchLicense = License(spdx: "LicenseRef-Mock-Research", commercialUse: .no,
                                         notice: "A stand-in for research-only weights: non-commercial use only.", acceptedRequired: true)
    static let displayLicense = License(spdx: "LicenseRef-Mock-Display", commercialUse: .yes,
                                        termsURL: "https://example.com/mock-display-license",
                                        notice: "Made with Mock Composer Display (a licence that asks for its name to be shown).",
                                        acceptedRequired: true)
    static let audioTypes = ["audio/wav", "audio/flac", "audio/mpeg", "audio/mp4"]

    /// The preset voices `mock-presets` offers (Base §6.5).
    public static let voices: [Voice] = [
        Voice(id: "mock-alto", title: "Alto", languages: ["en-US"], tags: ["female", "american", "calm"],
              notes: "The default voice."),
        Voice(id: "mock-tenor", title: "Tenor", languages: ["en-GB"], tags: ["male", "british", "narration"]),
        Voice(id: "mock-bass", title: "Bass", languages: ["en-US"], tags: ["male", "deep"],
              license: License(spdx: "LicenseRef-Mock-Voice-Actor", commercialUse: .no,
                               notice: "Recorded under a non-commercial consent agreement.")),
    ]

    /// Each preset voice's pitch, and the default voice's.
    static let pitches = ["mock-alto": 220.0, "mock-tenor": 165.0, "mock-bass": 98.0]

    // MARK: - Descriptors

    public func descriptors() async -> [Descriptor] {
        AudioProfile.operations.operations.keys.sorted().map(Self.descriptor)
    }

    static func offer(_ id: String, _ title: String, license: License = mockLicense, tiers: [QualityTier] = [.draft, .standard, .best],
                      isDefault: Bool? = nil, namedOnly: Bool? = nil, notes: String? = nil, supports: [String: JSONValue],
                      limits: Descriptor.Limits? = nil) -> ModelOffer {
        ModelOffer(id: id, title: title, license: license, memoryClass: .small, speedClass: .fast, qualityTiers: tiers,
                   isDefault: isDefault, namedOnly: namedOnly, notes: notes, supports: supports, limits: limits)
    }

    static func models(_ operation: String) -> [ModelOffer] {
        switch operation {
        case "audio.design_voice":
            return [offer("mock-voice-designer", "Mock voice designer", isDefault: true,
                          notes: "Describe the voice in a sentence or two: age, pitch, pace, accent.",
                          supports: ["languages": ["en", "zh"], "sample_rate": 24000, "channels": 1],
                          limits: .init(profile: [AudioProfile.LimitField.maxTextChars: 1000]))]
        case "audio.speak":
            return [
                offer("mock-presets", "Mock preset voices", isDefault: true,
                      notes: "Three preset voices; mock-alto is the default.",
                      supports: ["voices": .number(Double(voices.count)), "default_voice": true, "seed": false,
                                 "languages": ["en-US", "en-GB"], "emotions": ["neutral", "happy", "sad", "angry"],
                                 "styles": ["normal", "whisper"], "cues": ["laugh", "sigh", "pause"], "speed": true,
                                 "sample_rate": 24000, "channels": 1],
                      limits: .init(profile: [AudioProfile.LimitField.maxTextChars: 2000])),
                offer("mock-clone", "Mock voice cloning", tiers: [.standard, .best],
                      notes: "Clones from a clip of 3–30 s; give its transcript for a closer match.",
                      supports: ["stream": true, "voice_ref": true, "voice_ref_text": "optional",
                                 "languages": ["en", "zh", "ja"], "emotions": ["neutral", "happy", "afraid", "calm"],
                                 "emotion_intensity": true, "target_duration": true, "cues": ["laugh", "pause"],
                                 "sample_rate": 22050, "channels": 1],
                      limits: .init(maxDurationSeconds: 300, profile: [AudioProfile.LimitField.maxTextChars: 4000,
                                                                       AudioProfile.LimitField.maxVoiceRefSeconds: 30])),
                offer("mock-clone-research", "Mock research cloning", license: researchLicense, tiers: [.best], namedOnly: true,
                      notes: "Needs the reference's transcript.",
                      supports: ["voice_ref": true, "voice_ref_text": "required", "languages": ["en", "zh"],
                                 "emotions": ["neutral", "happy", "sad", "angry", "afraid", "disgusted", "melancholic", "surprised", "calm"],
                                 "emotion_description": true, "sample_rate": 24000, "channels": 1]),
            ]
        case "audio.edit_speech":
            return [
                offer("mock-editor", "Mock speech editor", isDefault: true,
                      notes: "Give the take's transcript; the result's length changes.",
                      supports: ["edits": ["emotion", "style", "add_cue", "denoise", "trim_silence", "speed", "volume"],
                                 "emotions": ["happy", "sad", "angry", "surprised", "neutral"], "styles": ["whisper", "normal"],
                                 "cues": ["laugh", "breath", "sigh"], "transcript": "required", "keeps_length": false,
                                 "sample_rate": 24000, "channels": 1],
                      limits: .init(maxDurationSeconds: 90)),
                offer("mock-editor-research", "Mock research editor", license: researchLicense, tiers: [.standard], namedOnly: true,
                      notes: "Adds sounds at the start or end only, and removes one kind at a time. Give target_duration_s to fit an edit to a cue.",
                      supports: ["edits": .array(AudioProfile.editKinds.map { .string($0) }),
                                 "emotions": ["happy", "sad", "angry", "afraid", "disgusted", "surprised", "calm", "excited"],
                                 "styles": ["whisper", "normal"], "cues": ["laugh", "cough", "breath", "hum"], "transcript": "unused",
                                 "cue_placement": ["edge"], "remove_all_cues": false, "target_duration": true,
                                 "keeps_length": true, "sample_rate": 24000, "channels": 1],
                      limits: .init(maxDurationSeconds: 30)),
            ]
        case "audio.separate":
            return [
                offer("mock-separator", "Mock music separator", tiers: [.draft, .standard], isDefault: true,
                      notes: "Music: the vocals, and the instrumental as the mixture minus the vocals.",
                      supports: ["stems": ["vocals", "instrumental"], "stem_method": "masked", "seed": false,
                                 "sample_rate": 44100, "channels": 2],
                      limits: .init(maxDurationSeconds: 600)),
                offer("mock-separator-voices", "Mock voice separator", license: researchLicense, tiers: [.standard], namedOnly: true,
                      notes: "Each stem is made again, so none can be subtracted from the mixture.",
                      supports: ["stems": ["speaker", "singing", "voices"], "speaker_selection": ["ordinal", "saying"],
                                 "stem_method": "regenerated", "languages": ["en", "zh"], "sample_rate": 24000, "channels": 1],
                      limits: .init(maxDurationSeconds: 30)),
                offer("mock-separator-flash", "Mock fast voice separator", tiers: [.draft],
                      notes: "Pick the speaker by words they say. Each stem is made again.",
                      supports: ["stems": ["speaker", "singing"], "speaker_selection": ["saying"], "stem_method": "regenerated",
                                 "sample_rate": 24000, "channels": 1],
                      limits: .init(maxDurationSeconds: 30)),
                offer("mock-separator-described", "Mock described-sound separator", tiers: [.draft, .standard],
                      notes: "Name the sound in a few lowercase words: 'speech', 'dog barking'. Sentences don't work. Both outputs are made again. (The mock marks nothing; the watermark key is there for clients to show.)",
                      supports: ["stems": ["target", "residual"], "described_target": true, "spans": true, "stem_method": "regenerated",
                                 "languages": ["en"], "sample_rate": 48000, "channels": 1, "watermark": "mock-mark"],
                      limits: .init(maxDurationSeconds: 10)),
            ]
        case "audio.generate":
            return [offer("mock-foley", "Mock foley", isDefault: true,
                          notes: "Describe the sound, not a voice. Every length costs the same.",
                          supports: ["languages": ["en", "zh"], "sample_rate": 48000, "channels": 1],
                          limits: .init(maxDurationSeconds: 30))]
        case "audio.compose":
            let covers = "Covers and supplied lyrics may need the original song's rights; this model's licence doesn't grant them."
            return [
                offer("mock-composer", "Mock composer", license: License(spdx: "MIT", commercialUse: .yes,
                                                                         termsURL: "https://opensource.org/license/mit"),
                      tiers: [.draft, .standard], isDefault: true, notes: "Write the caption yourself and set language. " + covers,
                      supports: ["languages": ["en", "zh", "ja"], "instrumental": true, "reference": true,
                                 "edits": ["cover", "repaint", "extend"], "anchors": ["bpm", "key", "time_signature"],
                                 "timestamps": true, "sample_rate": 48000, "channels": 2],
                      limits: .init(maxDurationSeconds: 600, profile: [AudioProfile.LimitField.minDuration: 1,
                                                                       AudioProfile.LimitField.maxRepaintSeconds: 90,
                                                                       AudioProfile.LimitField.maxReferenceSeconds: 120,
                                                                       AudioProfile.LimitField.maxSourceSeconds: 600])),
                offer("mock-composer-research", "Mock research composer",
                      license: License(spdx: "CC-BY-NC-4.0", commercialUse: .no, termsURL: "https://creativecommons.org/licenses/by-nc/4.0/",
                                       notice: "Mock research composer, CC BY-NC 4.0. Non-commercial use only: don't sell or monetize songs made with it.",
                                       acceptedRequired: true),
                      tiers: [.standard, .best], namedOnly: true, notes: covers,
                      supports: ["languages": ["en", "zh"], "score": "optional", "sample_rate": 48000, "channels": 2],
                      limits: .init(maxDurationSeconds: 360)),
                offer("mock-composer-notice", "Mock Composer Display", license: displayLicense, tiers: [.standard, .best],
                      notes: "Commercial use is allowed; the licence asks that its name be shown with what it makes. " + covers,
                      supports: ["languages": ["en", "zh"], "instrumental": true, "sample_rate": 44100, "channels": 2],
                      limits: .init(maxDurationSeconds: 300)),
            ]
        default:
            return []
        }
    }

    static func descriptor(_ operation: String) -> Descriptor {
        let spec = AudioProfile.operations.operations[operation]!
        let inputs = spec.inputs.sorted { $0.key < $1.key }.map { name, io in
            InputSpec(name: name, kind: io.kind, required: io.required ?? false, max: io.kind == .text ? nil : 1,
                      mediaTypes: io.kind == .audio ? audioTypes : nil)
        }
        var properties: [String: JSONValue] = [:]
        for (order, name) in spec.vocabulary.enumerated() {
            guard case .object(var schema)? = AudioProfile.vocabularySchema(name, operation: operation) else { continue }
            if name == AudioProfile.Param.output, case .object(var fields)? = schema["properties"] {
                // The mock writes WAV only, 16-bit, at any rate.
                fields["media_type"] = ["enum": ["audio/wav"]]
                fields["bit_depth"] = ["enum": [16]]
                schema["properties"] = .object(fields)
            }
            schema["x-mes-ui"] = .object(ui(name, order: order))
            properties[name] = .object(schema)
        }
        // §3.6: a separator's outputs are the stems its offers make, in the registry's order.
        let made = Set(models(operation).flatMap { $0.supports(AudioProfile.SupportsKey.stems)?.arrayValue?.compactMap(\.stringValue) ?? [] })
        let ordered = spec.outputs.sorted { a, b in
            a.value.stem == true && b.value.stem == true
                ? (AudioProfile.stems.firstIndex(of: a.key) ?? 0) < (AudioProfile.stems.firstIndex(of: b.key) ?? 0) : a.key < b.key
        }
        let outputs = ordered.filter { $0.value.stem != true || made.contains($0.key) }.map { name, io -> OutputSpec in
            let many = ["samples", "sounds"].contains(name)
            let optional = (operation == "audio.edit_speech" && name == "transcript") || (operation == "audio.compose" && name != "song")
                || io.stem == true
            let mediaTypes = io.kind == .data ? ["application/json"] : io.kind == .text ? ["text/vnd.abc"] : ["audio/wav"]
            return OutputSpec(name: name, kind: io.kind, mediaTypes: mediaTypes, min: optional ? 0 : 1,
                              max: many ? (operation == "audio.design_voice" ? 4 : 8) : 1,
                              stream: io.streamable == true ? .init(encodings: [.pcmS16LE, .pcmF32LE]) : nil)
        }
        let limits: Descriptor.Limits = switch operation {
        case "audio.generate": .init(maxDurationSeconds: 30, maxCount: 8)
        case "audio.compose": .init(maxDurationSeconds: 600, profile: [AudioProfile.LimitField.minDuration: 1,
                                                                       AudioProfile.LimitField.maxRepaintSeconds: 90,
                                                                       AudioProfile.LimitField.maxReferenceSeconds: 120,
                                                                       AudioProfile.LimitField.maxSourceSeconds: 600])
        case "audio.speak": .init(maxDurationSeconds: 300, profile: [AudioProfile.LimitField.maxTextChars: 4000,
                                                                     AudioProfile.LimitField.maxVoiceRefSeconds: 30])
        case "audio.edit_speech": .init(maxDurationSeconds: 90)
        case "audio.separate": .init(maxDurationSeconds: 600)
        default: .init(maxCount: 4, profile: [AudioProfile.LimitField.maxTextChars: 1000])
        }
        return Descriptor(
            operation: operation, profile: AudioProfile.id, profileVersion: AudioProfile.version, title: title(operation),
            summary: "Mock: synthetic audio that follows the Audio profile's rules.", inputs: inputs,
            params: .object(["type": "object", "additionalProperties": false, "properties": .object(properties)]),
            outputs: outputs, limits: limits, qualityTiers: [.draft, .standard, .best], models: models(operation),
            remote: .init(possible: false))
    }

    static func title(_ op: String) -> String {
        ["audio.design_voice": "Design a voice", "audio.speak": "Speak", "audio.edit_speech": "Edit speech",
         "audio.generate": "Generate a sound", "audio.compose": "Compose a song", "audio.separate": "Separate sources"][op] ?? op
    }

    static func ui(_ name: String, order: Int) -> [String: JSONValue] {
        let widgets = ["seed": "seed", "quality": "picker", "count": "stepper", "voice": "voice", "style": "picker",
                       "speed": "slider", "language": "text", "planning": "picker", "timestamps": "toggle",
                       "negative_prompt": "textarea", "duration_s": "slider", "target_duration_s": "slider",
                       "prompt_enhance": "picker"]
        var hints: [String: JSONValue] = ["label": .string(name.replacingOccurrences(of: "_", with: " ").capitalized),
                                          "order": .number(Double(order))]
        if let w = widgets[name] { hints["widget"] = .string(w) }
        if ["seed", "output", "negative_prompt", "prompt_enhance"].contains(name) { hints["advanced"] = true }
        if name == AudioProfile.Param.describe {           // RFC 0008: what a description is, said where it's typed
            hints["label"] = "Sound to separate"
            hints["widget"] = "text"
            hints["help"] = "Name the sound in a few words: speech, dog barking. Sentences don't work."
        }
        if name == AudioProfile.Param.spans {
            hints["label"] = "Where it is heard"
            hints["help"] = "Stretches of the recording where the described sound is heard, or is not."
        }
        return hints
    }

    public func voices(operation: String, model: String) async -> [Voice] {
        operation == "audio.speak" && model == "mock-presets" ? Self.voices : []
    }

    // MARK: - Running

    public func run(_ context: RunContext) async throws -> RunOutput {
        let seed = context.param("seed")?.intValue ?? Int.random(in: 0...999_999)
        var warnings: [Warning] = []
        var effective: [String: JSONValue] = ["model_params": ["mock": true]]
        let rate = context.model.supports(AudioProfile.SupportsKey.sampleRate)?.intValue ?? 24000
        let output = context.param(AudioProfile.Param.output)?.objectValue
        let outRate = output?["sample_rate"]?.intValue ?? rate
        let modelChannels = context.model.supports(AudioProfile.SupportsKey.channels)?.intValue ?? 1
        let outChannels = output?["channels"]?.intValue ?? modelChannels
        if outRate != rate {
            warnings.append(Warning(code: AudioProfile.WarningCode.audioResampled,
                                    message: "Resampled from the model's \(rate) Hz to \(outRate) Hz.", param: AudioProfile.Param.output))
        }
        let dir = context.outputDirectory

        func step(_ phase: String, _ n: Int) async throws {
            for i in 1...n {
                try Task.checkCancellation()
                if stepDelay > .zero { try await Task.sleep(for: stepDelay) }
                await context.reporter.progress(.running, phase: phase, step: i, steps: n)
            }
        }
        func write(_ mono: [Float], _ name: String, _ i: Int = 0, pan: Float = 0) throws -> ProducedOutput {
            let url = dir.appendingPathComponent("\(name)-\(i).wav")
            let wav = try Tones.writeWAV(mono, rate: outRate, channels: outChannels, to: url, pan: pan)
            return .audio(url, name: name, durationSeconds: wav.durationSeconds, sampleRate: outRate, channels: outChannels, bitDepth: 16)
        }
        func input(_ name: String) throws -> [Float] {
            guard let url = context.input(name)?.fileURL else { throw MESError(.invalidRequest, "Input '\(name)' is missing.", param: name) }
            let (samples, inRate, downmixed) = try Tones.read(url)
            if downmixed {
                warnings.append(Warning(code: AudioProfile.WarningCode.audioDownmixed, message: "'\(name)' was mixed down to mono.", param: name))
            }
            if inRate != outRate {
                warnings.append(Warning(code: AudioProfile.WarningCode.audioResampled,
                                        message: "'\(name)' was resampled from \(inRate) Hz to \(outRate) Hz.", param: name))
            }
            return Tones.resample(samples, from: inRate, to: outRate)
        }

        var outputs: [ProducedOutput] = []
        var reportedSeed: Int? = context.model.usesSeed ? seed : nil
        switch context.operation {
        case "audio.design_voice":
            try await step("generate", 2)
            let description = context.input(AudioProfile.Input.description)?.text ?? ""
            let language = context.param(AudioProfile.Param.language)?.stringValue ?? "en"
            let text = context.input(AudioProfile.Input.text)?.text
                ?? (language.hasPrefix("zh") ? "敏捷的棕色狐狸跳过了懒狗。" : "The quick brown fox jumps over the lazy dog.")
            effective["text"] = .string(text)
            effective[AudioProfile.Param.language] = .string(language)
            for i in 0..<(context.param("count")?.intValue ?? 1) {
                let pitch = Self.designedPitch(description, seed: seed + i)
                outputs.append(try write(Self.speech(text, pitch: pitch, rate: outRate, seed: UInt64(seed + i)), "samples", i))
            }

        case "audio.speak":
            let text = context.input(AudioProfile.Input.text)?.text ?? ""
            var pitch = 220.0
            if let voice = context.voice { pitch = Self.pitches[voice.id] ?? pitch }
            if context.input(AudioProfile.Input.voiceRef) != nil {
                let ref = try input(AudioProfile.Input.voiceRef)
                pitch = Self.estimatePitch(ref, rate: outRate) ?? pitch
                if let max = context.model.limits?.value(AudioProfile.LimitField.maxVoiceRefSeconds),
                   Double(ref.count) / Double(outRate) > max {
                    warnings.append(Warning(code: AudioProfile.WarningCode.voiceRefTrimmed,
                                            message: "The reference was trimmed to its first \(Int(max)) s.", param: AudioProfile.Input.voiceRef))
                }
            }
            if let emotion = context.param(AudioProfile.Param.emotion)?.objectValue, let label = emotion["label"]?.stringValue {
                pitch *= ["happy": 1.12, "sad": 0.9, "angry": 1.05, "afraid": 1.18, "calm": 0.95][label] ?? 1
                effective[AudioProfile.Param.emotion] = .object(emotion)
            }
            let speed = context.param(AudioProfile.Param.speed)?.numberValue ?? 1
            var mono = Self.speech(text, pitch: pitch, rate: outRate, seed: Tones.hash(text), speed: speed,
                                   whisper: context.param(AudioProfile.Param.style)?.stringValue == "whisper")
            if let target = context.param(AudioProfile.Param.targetDuration)?.numberValue {
                mono = Tones.fit(mono, count: Tones.frames(target, rate: outRate))
            }
            effective[AudioProfile.Param.language] = .string(context.param(AudioProfile.Param.language)?.stringValue ?? "en")
            if let stream = context.stream("audio") {
                // A quarter second per chunk, each as soon as it's "made".
                let per = outRate / 4
                var sent = 0
                while sent < mono.count {
                    try Task.checkCancellation()
                    if chunkDelay > .zero { try await Task.sleep(for: chunkDelay) }
                    let end = min(mono.count, sent + per)
                    await context.reporter.chunk("audio", samples: Tones.pcm(Array(mono[sent..<end]), channels: stream.channels,
                                                                             encoding: stream.encoding), final: end == mono.count)
                    await context.reporter.progress(.running, phase: "generate", mediaSeconds: Double(end) / Double(outRate))
                    sent = end
                }
                if mono.isEmpty { await context.reporter.chunk("audio", samples: Data(), final: true) }
                outputs.append(.streamed("audio"))
            } else {
                try await step("generate", 2)
                outputs.append(try write(mono, "audio"))
            }
            reportedSeed = context.model.usesSeed ? seed : nil

        case "audio.edit_speech":
            try await step("edit", 2)
            var mono = try input(AudioProfile.Input.audio)
            let edit = context.param(AudioProfile.Param.edit)?.objectValue ?? [:]
            let kind = edit["kind"]?.stringValue ?? ""
            let keeps = context.model.supports(AudioProfile.SupportsKey.keepsLength)?.boolValue == true
            var transcript = context.input(AudioProfile.Input.transcript)?.text
            switch kind {
            case "speed": mono = Tones.fit(mono, count: Int(Double(mono.count) / (edit["factor"]?.numberValue ?? 1)))
            case "volume":
                let gain = Float(pow(10, (edit["gain_db"]?.numberValue ?? 0) / 20))
                mono = mono.map { max(-1, min(1, $0 * gain)) }
            case "trim_silence":
                let first = mono.firstIndex { abs($0) > 0.01 } ?? 0, last = mono.lastIndex { abs($0) > 0.01 } ?? (mono.count - 1)
                mono = first <= last ? Array(mono[first...last]) : mono
            case "add_cue":
                let cue = edit["cue"]?.stringValue ?? "laugh"
                let burst = Tones.noise(seconds: 0.4, rate: outRate, seed: Tones.hash(cue), smoothing: 0.3)
                mono = edit["at"]?.stringValue == "start" ? burst + mono : mono + burst
                if let t = transcript { transcript = edit["at"]?.stringValue == "start" ? "[\(cue)] " + t : t + " [\(cue)]" }
            case "remove_cue", "replace_text", "insert_text", "remove_text":
                if var t = transcript {
                    switch kind {
                    case "replace_text": t = t.replacingOccurrences(of: edit["text"]?.stringValue ?? "", with: edit["with"]?.stringValue ?? "")
                    case "remove_text": t = t.replacingOccurrences(of: edit["text"]?.stringValue ?? "", with: "")
                    case "insert_text":
                        let anchor = edit["anchor"]?.stringValue ?? "", words = edit["text"]?.stringValue ?? ""
                        t = t.replacingOccurrences(of: anchor, with: edit["position"]?.stringValue == "before" ? "\(words) \(anchor)" : "\(anchor) \(words)")
                    default: t = AudioProfile.text(AudioProfile.segments(t).filter { if case .cue = $0 { false } else { true } })
                    }
                    transcript = t
                }
            default:
                // emotion, style, pitch, timbre, de_accent, denoise: a gentle colouring of the take.
                mono = mono.map { $0 * 0.9 }
            }
            if !keeps, kind != "speed", kind != "trim_silence", kind != "add_cue" {
                mono += Tones.silence(0.1, rate: outRate)            // EditX-like: the take is made again, a little longer
            }
            if keeps, let source = try? input(AudioProfile.Input.audio) { mono = Tones.fit(mono, count: source.count) }
            if let target = context.param(AudioProfile.Param.targetDuration)?.numberValue {
                mono = Tones.fit(mono, count: Tones.frames(target, rate: outRate))      // RFC 0006 S-5: fitted to the cue
                effective[AudioProfile.Param.targetDuration] = .number(target)
            }
            outputs.append(try write(mono, "audio"))
            if ["add_cue", "remove_cue", "replace_text", "insert_text", "remove_text"].contains(kind), let transcript {
                outputs.append(.data(["text": .string(transcript)], name: "transcript"))
            }
            effective[AudioProfile.Param.edit] = .object(edit)

        case "audio.separate":
            // §3.6: one output per stem, each the mixture's length. Masked stems filter the mixture (and the
            // instrumental is the mixture minus the vocals); regenerated ones are made again, seeded, at its length.
            let mixture = try input(AudioProfile.Input.audio)
            let seconds = Double(mixture.count) / Double(outRate)
            if let max = context.model.limits?.maxDurationSeconds, seconds > max + 0.5 / Double(outRate) {
                throw MESError(.outOfLimits, String(format: "The mixture is %.2f s; %@ separates at most %g s.", seconds, context.model.title, max),
                               param: AudioProfile.Input.audio)
            }
            let stems = context.stems
            // RFC 0008: a described sound. Case doesn't count; spans are checked against the mixture now that it's read.
            let described = context.describe?.lowercased()
            let spans = context.spans
            try context.checkSpans(mixtureSeconds: seconds, sampleRate: Double(outRate))
            let masked = context.model.supports(AudioProfile.SupportsKey.stemMethod)?.stringValue != "regenerated"
            let vocals = Tones.smooth(mixture, window: 8)
            for (i, stem) in stems.enumerated() {
                try Task.checkCancellation()
                if stepDelay > .zero { try await Task.sleep(for: stepDelay) }
                await context.reporter.progress(.running, phase: "separate", step: i + 1, steps: stems.count)
                let mono: [Float]
                if masked {
                    mono = stem == "instrumental" ? zip(mixture, vocals).map { $0 - $1 } : vocals
                } else if let described {
                    // The target is a tone the description picks, silent where a span says the sound isn't; the
                    // residual another, silent where a span says it is. Each is made again, the mixture's length.
                    let pitch = (stem == "target" ? 220.0 : 110.0) + Double(Tones.hash(described) % 200)
                    var made = Tones.fit(Self.speech(String(repeating: "la ", count: max(1, Int(seconds * 3))), pitch: pitch, rate: outRate,
                                                     seed: UInt64(seed) ^ Tones.hash(stem + described)), count: mixture.count)
                    for span in spans where span.present == (stem == "residual") {
                        let lo = min(made.count, Tones.frames(span.start, rate: outRate)), hi = min(made.count, Tones.frames(span.end, rate: outRate))
                        for i in lo..<max(lo, hi) { made[i] = 0 }
                    }
                    mono = made
                } else {
                    let pick = context.param(AudioProfile.Param.speaker).map { "\($0)" } ?? ""
                    let pitch = stem == "singing" ? 330.0 : 150.0 + Double(Tones.hash(pick) % 120)
                    mono = Tones.fit(Self.speech(String(repeating: "la ", count: max(1, Int(seconds * 3))), pitch: pitch, rate: outRate,
                                                 seed: UInt64(seed) ^ Tones.hash(stem + pick)), count: mixture.count)
                }
                outputs.append(try write(mono, stem))
            }
            effective[AudioProfile.Param.stems] = .array(stems.map { .string($0) })
            if let pick = context.param(AudioProfile.Param.speaker) { effective[AudioProfile.Param.speaker] = pick }
            if let described {
                effective[AudioProfile.Param.describe] = .string(described)
                if !spans.isEmpty { effective[AudioProfile.Param.spans] = .array(spans.map(\.json)) }
            }

        case "audio.generate":
            try await step("denoise", 4)
            let prompt = context.input(AudioProfile.Input.prompt)?.text ?? ""
            let duration = context.param(AudioProfile.Param.duration)?.numberValue ?? 2
            effective[AudioProfile.Param.duration] = .number(duration)
            for i in 0..<(context.param("count")?.intValue ?? 1) {
                let n = Tones.frames(duration, rate: outRate)
                var r = Tones.Random(UInt64(seed + i) ^ Tones.hash(prompt))
                let smoothing = 0.2 + 0.7 * Float(r.next() % 100) / 100
                let mono = Tones.fit(Tones.noise(seconds: duration, rate: outRate, seed: UInt64(seed + i) ^ Tones.hash(prompt),
                                                 smoothing: smoothing), count: n)
                outputs.append(try write(mono, "sounds", i))
            }

        case "audio.compose":
            let caption = context.input(AudioProfile.Input.caption)?.text ?? ""
            let lyrics = context.input(AudioProfile.Input.lyrics)?.text
            let lines = lyrics.map { $0.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }.count } ?? 0
            let edit = context.param(AudioProfile.Param.edit)?.objectValue
            let quality = context.quality
            if quality != .draft { try await step("plan", 2) }
            var planned = context.param(AudioProfile.Param.duration)?.numberValue ?? Double(max(4, lines * 2 + 2))
            let maxDuration = context.model.limits?.maxDurationSeconds ?? 600
            if planned > maxDuration { planned = maxDuration }
            var source: [Float] = []
            if let edit, context.input(AudioProfile.Input.source) != nil {
                source = try input(AudioProfile.Input.source)
                let sourceSeconds = Double(source.count) / Double(outRate)
                switch edit["kind"]?.stringValue {
                case "extend":
                    let before = edit["before_s"]?.numberValue ?? 0, after = edit["after_s"]?.numberValue ?? 0
                    planned = before + sourceSeconds + after
                default:
                    if let end = edit["end_s"]?.numberValue, end > sourceSeconds {
                        throw MESError(.outOfLimits, "The repaint ends at \(end) s; the source is \(String(format: "%.2f", sourceSeconds)) s.",
                                       param: AudioProfile.Param.edit)
                    }
                    planned = sourceSeconds
                }
            }
            if lines * 2 > Int(planned), lyrics != nil {
                warnings.append(Warning(code: AudioProfile.WarningCode.songTruncated,
                                        message: "The song ended at \(Int(planned)) s, before the lyrics did.", param: AudioProfile.Param.duration))
            }
            try await step("denoise", 4)
            let bpm = context.param(AudioProfile.Param.anchors)?["bpm"]?.numberValue ?? Double(80 + (seed % 60))
            let key = context.param(AudioProfile.Param.anchors)?["key"]?.stringValue ?? ["C major", "A minor", "G major", "E minor"][seed % 4]
            let signature = context.param(AudioProfile.Param.anchors)?["time_signature"]?.stringValue ?? "4/4"
            var mono = Self.song(caption: caption, seconds: planned, bpm: bpm, rate: outRate, seed: UInt64(seed))
            if let edit, edit["kind"]?.stringValue == "extend" {
                let before = Tones.frames(edit["before_s"]?.numberValue ?? 0, rate: outRate)
                let after = Tones.frames(edit["after_s"]?.numberValue ?? 0, rate: outRate)
                mono = Array(mono.prefix(before)) + source + Array(mono.suffix(after))
                mono = Tones.fit(mono, count: before + source.count + after)
            }
            await context.reporter.progress(.running, phase: "decode", step: 1, steps: 1)
            let n = Tones.frames(planned, rate: outRate)
            if edit?["kind"]?.stringValue != "extend" { mono = Tones.fit(mono, count: n) }
            outputs.append(try write(mono, "song", pan: 0.2))
            effective[AudioProfile.Param.duration] = .number(Double(mono.count) / Double(outRate))
            effective[AudioProfile.Param.anchors] = ["bpm": .number(bpm), "key": .string(key), "time_signature": .string(signature)]
            if context.param(AudioProfile.Param.language) == nil, lyrics != nil { effective[AudioProfile.Param.language] = "en" }
            let scores = (context.model.supports(AudioProfile.SupportsKey.score)?.stringValue ?? "unused") != "unused"
            if scores, context.param(AudioProfile.Param.planning)?.stringValue != "off" {
                let abc = context.input(AudioProfile.Input.score)?.text
                    ?? "X:1\nT:\(caption.prefix(40))\nM:\(signature)\nQ:1/4=\(Int(bpm))\nK:\(key.replacingOccurrences(of: " major", with: "").replacingOccurrences(of: " minor", with: "m"))\n\"C\"C2 E2 G2 c2|\"G\"B2 G2 D2 G2|\n"
                let url = dir.appendingPathComponent("score.abc")
                try Data(abc.utf8).write(to: url)
                outputs.append(.file(url, name: "score", kind: .text, mediaType: "text/vnd.abc"))
            }
            if context.param(AudioProfile.Param.timestamps)?.boolValue == true,
               context.model.supports(AudioProfile.SupportsKey.timestamps)?.boolValue == true, let lyrics {
                var t = 1.0
                let sung = lyrics.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.hasPrefix("[") && !$0.isEmpty }
                let timed: [JSONValue] = sung.map { line in
                    defer { t += 2 }
                    return ["text": .string(line), "start_s": .number(t), "end_s": .number(min(planned, t + 1.8))]
                }
                outputs.append(.data(["lines": .array(timed)], name: "timestamps"))
            }

        default:
            throw MESError(.unknownOperation, "The audio mock doesn't implement \(context.operation).")
        }
        return RunOutput(outputs: outputs, effective: effective, seed: reportedSeed, warnings: warnings)
    }

    // MARK: - Synthesis

    /// "Speech": a tone burst per word around `pitch`, a short gap between words, and the profile's cues: laughs and
    /// sighs as shaped noise, a pause as exactly that much silence (Audio §2.2).
    static func speech(_ text: String, pitch: Double, rate: Int, seed: UInt64, speed: Double = 1, whisper: Bool = false) -> [Float] {
        var out: [Float] = []
        var r = Tones.Random(seed)
        for segment in AudioProfile.segments(text) {
            switch segment {
            case .text(let words):
                for word in words.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }) {
                    let seconds = (0.08 + 0.045 * Double(word.count)) / speed
                    let hz = pitch * (1 + 0.06 * Double(r.unit()))
                    out += whisper ? Tones.noise(seconds: seconds, rate: rate, seed: r.next(), level: 0.12, smoothing: 0.2)
                        : Tones.tone(hz, seconds: seconds, rate: rate, vibrato: 0.4)
                    out += Tones.silence(0.05 / speed, rate: rate)
                }
            case .cue("pause", let seconds):
                out += Tones.silence(seconds ?? 0.5, rate: rate)
            case .cue(let name, _):
                out += Tones.noise(seconds: name == "sigh" ? 0.5 : 0.4, rate: rate, seed: Tones.hash(name), smoothing: name == "sigh" ? 0.8 : 0.3)
                out += Tones.silence(0.05, rate: rate)
            }
        }
        return out.isEmpty ? Tones.silence(0.2, rate: rate) : out
    }

    /// A designed voice's pitch: from the description and the seed, so the same pair designs the same voice.
    static func designedPitch(_ description: String, seed: Int) -> Double {
        let h = Tones.hash(description) ^ UInt64(seed) &* 0x9E37_79B9
        var base = 90.0 + Double(h % 200)
        let d = description.lowercased()
        if d.contains("deep") || d.contains("low") { base = min(base, 120) }
        if d.contains("high") || d.contains("bright") { base = max(base, 240) }
        return base
    }

    /// A clip's pitch by zero crossings: the mock's "speaker embedding".
    static func estimatePitch(_ samples: [Float], rate: Int) -> Double? {
        var crossings = 0, voiced = 0
        for i in 1..<max(1, samples.count) where abs(samples[i]) > 0.02 {
            voiced += 1
            if (samples[i - 1] < 0) != (samples[i] < 0) { crossings += 1 }
        }
        guard voiced > rate / 20 else { return nil }
        return Double(crossings) / 2 / (Double(voiced) / Double(rate))
    }

    /// A "song": a chord a beat at `bpm`, chosen from the caption and seed, under a quiet noise bed.
    static func song(caption: String, seconds: Double, bpm: Double, rate: Int, seed: UInt64) -> [Float] {
        let roots = [130.81, 146.83, 164.81, 174.61, 196.0, 220.0]
        var r = Tones.Random(seed ^ Tones.hash(caption))
        let beat = 60 / bpm
        var out: [Float] = []
        while Double(out.count) / Double(rate) < seconds {
            let root = roots[Int(r.next() % UInt64(roots.count))]
            let a = Tones.tone(root, seconds: beat, rate: rate, level: 0.15)
            let b = Tones.tone(root * 1.26, seconds: beat, rate: rate, level: 0.1)
            let c = Tones.tone(root * 1.5, seconds: beat, rate: rate, level: 0.1)
            out += (0..<a.count).map { a[$0] + b[$0] + c[$0] }
        }
        return Array(out.prefix(Tones.frames(seconds, rate: rate)))
    }
}

/// The mock engine `mes-mock-engine` serves: the Image mock's fifteen operations, the Audio mock's six, the Video mock's
/// five and the Mesh mock's two, one engine.
public struct MockMediaEngine: MediaEngine {
    public var image: MockImageEngine
    public var audio: MockAudioEngine
    public var video: MockVideoEngine
    public var mesh: MockMeshEngine

    public init(stepDelay: Duration = .zero, steps: Int = 4, chunkDelay: Duration = .milliseconds(20)) {
        image = MockImageEngine(stepDelay: stepDelay, steps: steps)
        audio = MockAudioEngine(stepDelay: stepDelay, chunkDelay: chunkDelay)
        video = MockVideoEngine(stepDelay: stepDelay)
        mesh = MockMeshEngine(stepDelay: stepDelay)
    }

    public func descriptors() async -> [Descriptor] { await image.descriptors() + audio.descriptors() + video.descriptors() + mesh.descriptors() }

    public func validate(_ request: JobRequest, descriptor: Descriptor) throws {
        switch descriptor.profile {
        case AudioProfile.id: try audio.validate(request, descriptor: descriptor)
        case VideoProfile.id: try video.validate(request, descriptor: descriptor)
        case MeshProfile.id: try mesh.validate(request, descriptor: descriptor)
        default: try image.validate(request, descriptor: descriptor)
        }
    }

    public func run(_ context: RunContext) async throws -> RunOutput {
        switch context.descriptor.profile {
        case AudioProfile.id: try await audio.run(context)
        case VideoProfile.id: try await video.run(context)
        case MeshProfile.id: try await mesh.run(context)
        default: try await image.run(context)
        }
    }

    public func voices(operation: String, model: String) async -> [Voice] { await audio.voices(operation: operation, model: model) }
}
