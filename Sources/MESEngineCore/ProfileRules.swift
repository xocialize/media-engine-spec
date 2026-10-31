import Foundation
import MESCore

/// Something a request uses that the offer serving it must support (Base §6.4 rule 2): a gate key, or a limit.
public struct OfferRequirement: Sendable {
    /// The parameter or input that uses it, for the refusal's `param`.
    public var param: String
    /// `unsupported_parameter` for a gate key, `out_of_limits` for a limit.
    public var code: MESErrorCode
    /// What the request uses, for messages: "the emotion 'happy'".
    public var what: String
    public var admits: @Sendable (ModelOffer) -> Bool

    public init(param: String, code: MESErrorCode = .unsupportedParameter, what: String,
                admits: @escaping @Sendable (ModelOffer) -> Bool) {
        self.param = param; self.code = code; self.what = what; self.admits = admits
    }

    /// A gate on a boolean key (absent `false` unless `absent` says otherwise).
    static func flag(_ key: String, absent: Bool = false, param: String, what: String) -> OfferRequirement {
        OfferRequirement(param: param, what: what) { $0.supports(key)?.boolValue ?? absent }
    }

    /// A gate on a list key: the offer lists `value` (absent: `absent`).
    static func listed(_ key: String, _ value: String, absent: [String], param: String, what: String) -> OfferRequirement {
        OfferRequirement(param: param, what: what) { offer in
            let list = offer.supports(key)?.arrayValue?.compactMap(\.stringValue) ?? absent
            return list.contains(value)
        }
    }

    /// A limit: the offer's `limits[field]`, when it has one, admits `value`.
    static func limit(_ field: String, _ value: Double, atMost: Bool = true, param: String, what: String) -> OfferRequirement {
        OfferRequirement(param: param, code: .outOfLimits, what: what) { offer in
            guard let bound = offer.limits?.value(field) else { return true }
            return atMost ? value <= bound : value >= bound
        }
    }
}

/// The profiles' per-offer rules (Base §6.4), applied by the kit to every request: what a request needs of its offer,
/// and the warnings an offer without a Warn key produces.
public enum ProfileRules {
    /// Rewrites what the engine resolves before anything reads the request: Audio's emotion aliases (§2.1).
    public static func normalize(_ request: JobRequest, descriptor: Descriptor) -> JobRequest {
        descriptor.profile == AudioProfile.id ? AudioProfileRules.normalize(request) : request
    }

    /// The gate keys and limits the request uses (Base §6.4).
    public static func requirements(_ request: JobRequest, descriptor: Descriptor) -> [OfferRequirement] {
        switch descriptor.profile {
        case AudioProfile.id: AudioProfileRules.requirements(request, descriptor: descriptor)
        case ImageProfile.id: ImageProfileRules.requirements(request, descriptor: descriptor)
        default: []
        }
    }

    /// Warnings for Warn keys the chosen offer lacks (Base `seed`, and the profile's), produced by the kit so engines
    /// don't each implement them.
    public static func warnings(_ request: JobRequest, descriptor: Descriptor, model: ModelOffer) -> [Warning] {
        var out: [Warning] = []
        if request.params?["seed"] != nil, !model.usesSeed {
            out.append(Warning(code: BaseWarningCode.seedIgnored, message: "\(model.title) doesn't use a seed; its result doesn't depend on one.",
                               param: "seed"))
        }
        switch descriptor.profile {
        case AudioProfile.id: out += AudioProfileRules.warnings(request, descriptor: descriptor, model: model)
        case ImageProfile.id:
            if let np = request.params?[ImageProfile.Param.negativePrompt]?.stringValue, !np.isEmpty,
               model.supports(ImageProfile.SupportsKey.negativePrompt)?.boolValue == false {
                out.append(Warning(code: ImageProfile.WarningCode.negativePromptIgnored,
                                   message: "\(model.title) can't use a negative prompt.", param: ImageProfile.Param.negativePrompt))
            }
        default: break
        }
        return out
    }

    /// Text inputs as the model should receive them, with the warnings that cost: Audio `speak` drops cues the model
    /// can't perform (§2.2).
    public static func prepareInputs(_ inputs: [String: [RunInput]], descriptor: Descriptor,
                                     model: ModelOffer) -> ([String: [RunInput]], [Warning]) {
        guard descriptor.operation == "audio.speak", case .text(let text)? = inputs[AudioProfile.Input.text]?.first else {
            return (inputs, [])
        }
        let (kept, warnings) = AudioProfileRules.removeUnsupportedCues(text, model: model)
        var out = inputs
        out[AudioProfile.Input.text] = [.text(kept)]
        return (out, warnings)
    }
}

extension ImageProfileRules {
    /// Image's per-offer rules (§2.1): `supports.composite` gates a composite; `limits.max_layer_count` bounds a count.
    public static func requirements(_ request: JobRequest, descriptor: Descriptor) -> [OfferRequirement] {
        guard descriptor.operation == "image.decompose" else { return [] }
        var out: [OfferRequirement] = []
        let params = request.params ?? [:]
        if params[ImageProfile.Param.outputs]?.arrayValue?.contains(.string("composite")) == true {
            out.append(.flag(ImageProfile.SupportsKey.composite, absent: true, param: ImageProfile.Param.outputs, what: "a composite"))
        }
        if let count = params[ImageProfile.Param.layerCount]?.numberValue {
            out.append(.limit(ImageProfile.LimitField.maxLayerCount, count, param: ImageProfile.Param.layerCount,
                              what: "\(Int(count)) layers"))
        }
        return out
    }
}

/// The Audio profile's rules (spec/profiles/audio.md): request structure (400s), gates and limits per offer (§4), and
/// the warnings the kit produces for Warn keys.
public enum AudioProfileRules {
    typealias P = AudioProfile.Param
    typealias I = AudioProfile.Input
    typealias K = AudioProfile.SupportsKey
    typealias L = AudioProfile.LimitField

    /// The fields each speech edit kind needs (§3.3).
    static let editFields: [String: [String]] = [
        "emotion": ["emotion"], "style": ["style"], "add_cue": ["cue"], "remove_cue": [], "replace_text": ["text", "with"],
        "insert_text": ["text", "anchor", "position"], "remove_text": ["text"], "speed": ["factor"], "pitch": ["semitones"],
        "volume": ["gain_db"], "timbre": ["description"], "de_accent": [], "denoise": [], "trim_silence": [],
    ]
    /// The fields each speech edit kind may carry, beyond `kind`.
    static let editAllowed: [String: [String]] = [
        "add_cue": ["cue", "at", "text"], "remove_cue": ["cue"],
    ]

    /// Emotion aliases resolved (§2.1): `emotion.label` and an `emotion` edit's label.
    public static func normalize(_ request: JobRequest) -> JobRequest {
        var r = request
        guard var params = r.params else { return r }
        if case .object(var emotion)? = params[P.emotion], let label = emotion["label"]?.stringValue,
           let canonical = AudioProfile.canonicalEmotion(label), canonical != label {
            emotion["label"] = .string(canonical)
            params[P.emotion] = .object(emotion)
        }
        if case .object(var edit)? = params[P.edit], let label = edit["emotion"]?.stringValue,
           let canonical = AudioProfile.canonicalEmotion(label), canonical != label {
            edit["emotion"] = .string(canonical)
            params[P.edit] = .object(edit)
        }
        r.params = params
        return r
    }

    /// Structural rules beyond the params schema: 400 `invalid_request`.
    public static func validate(_ request: JobRequest, descriptor: Descriptor) throws {
        let params = request.params ?? [:], inputs = request.inputs ?? [:]
        if let spec = AudioProfile.operations.operations[descriptor.operation] {
            for name in spec.requiredParams ?? [] where params[name] == nil {
                throw MESError(.invalidRequest, "\(descriptor.operation) needs '\(name)'.", param: name)
            }
        }
        switch descriptor.operation {
        case "audio.speak":
            // §3.2: one voice, three ways.
            if params[P.voice] != nil, inputs[I.voiceRef] != nil {
                throw MESError(.invalidRequest, "Give a voice or a voice_ref, not both.", param: P.voice)
            }
            if inputs[I.voiceRefText] != nil, inputs[I.voiceRef] == nil {
                throw MESError(.invalidRequest, "voice_ref_text is the transcript of a voice_ref; send the clip too.", param: I.voiceRefText)
            }
        case "audio.edit_speech":
            guard let edit = params[P.edit]?.objectValue, let kind = edit["kind"]?.stringValue else { return }
            let needed = editFields[kind] ?? []
            for field in needed where edit[field] == nil {
                throw MESError(.invalidRequest, "A \(kind) edit needs '\(field)'.", param: P.edit)
            }
            let allowed = Set(["kind"] + needed + (editAllowed[kind] ?? []))
            if let extra = edit.keys.sorted().first(where: { !allowed.contains($0) }) {
                throw MESError(.invalidRequest, "A \(kind) edit takes no '\(extra)'.", param: P.edit)
            }
            if kind == "add_cue", edit["at"] != nil, edit["text"] != nil {
                throw MESError(.invalidRequest, "An add_cue edit places the cue with 'at' or with 'text', not both.", param: P.edit)
            }
        case "audio.compose":
            let edit = params[P.edit]?.objectValue
            if edit != nil, inputs[I.source] == nil {
                throw MESError(.invalidRequest, "An edit reworks a source; send the source input.", param: P.edit)
            }
            if edit == nil, inputs[I.source] != nil {
                throw MESError(.invalidRequest, "A source is reworked by an edit; say which with 'edit'.", param: I.source)
            }
            if inputs[I.score] != nil, inputs[I.lyrics] == nil {
                throw MESError(.invalidRequest, "A score travels with the lyrics it was planned from; send them too.", param: I.score)
            }
            if let edit, let kind = edit["kind"]?.stringValue {
                switch kind {
                case "repaint":
                    guard let start = edit["start_s"]?.numberValue, let end = edit["end_s"]?.numberValue, end > start else {
                        throw MESError(.invalidRequest, "A repaint needs start_s before end_s.", param: P.edit)
                    }
                case "extend":
                    if (edit["before_s"]?.numberValue ?? 0) + (edit["after_s"]?.numberValue ?? 0) <= 0 {
                        throw MESError(.invalidRequest, "An extend needs before_s or after_s.", param: P.edit)
                    }
                default: break
                }
            }
        default: break
        }
    }

    /// Whether an offer's `languages` admits a BCP 47 tag: equal, or one a primary-language prefix of the other
    /// (`en` admits `en-GB`, and `en-GB` asks for an offer that speaks `en`).
    public static func languageMatches(_ requested: String, _ offered: [String]) -> Bool {
        let r = requested.lowercased()
        return offered.contains { o in
            let o = o.lowercased()
            return o == r || r.hasPrefix(o + "-") || o.hasPrefix(r + "-")
        }
    }

    static func language(_ value: String) -> OfferRequirement {
        OfferRequirement(param: P.language, what: "the language '\(value)'") { offer in
            guard let langs = offer.supports(K.languages)?.arrayValue?.compactMap(\.stringValue) else { return true }
            return languageMatches(value, langs)
        }
    }

    public static func requirements(_ request: JobRequest, descriptor: Descriptor) -> [OfferRequirement] {
        let params = request.params ?? [:], inputs = request.inputs ?? [:]
        var out: [OfferRequirement] = []
        func text(_ name: String) -> String? { if case .text(let s)? = inputs[name] { return s }; return nil }
        switch descriptor.operation {
        case "audio.design_voice":
            if let l = params[P.language]?.stringValue { out.append(language(l)) }
            if let d = text(I.description) {
                out.append(.limit(L.maxTextChars, Double(d.count), param: I.description, what: "a \(d.count)-character description"))
            }
        case "audio.speak":
            if let l = params[P.language]?.stringValue { out.append(language(l)) }
            if inputs[I.voiceRef] != nil {
                out.append(.flag(K.voiceRef, param: I.voiceRef, what: "a cloned voice (voice_ref)"))
                if inputs[I.voiceRefText] == nil {
                    out.append(OfferRequirement(param: I.voiceRefText, what: "a voice_ref without its transcript") {
                        $0.supports(K.voiceRefText)?.stringValue != "required"
                    })
                }
            } else if params[P.voice] == nil {
                out.append(.flag(K.defaultVoice, param: P.voice, what: "a default voice (neither voice nor voice_ref)"))
            }
            if let emotion = params[P.emotion]?.objectValue {
                if let label = emotion["label"]?.stringValue, label != "neutral" {
                    out.append(.listed(K.emotions, label, absent: ["neutral"], param: P.emotion, what: "the emotion '\(label)'"))
                }
                if emotion["description"] != nil {
                    out.append(.flag(K.emotionDescription, param: P.emotion, what: "an emotion description"))
                }
            }
            if let style = params[P.style]?.stringValue, style != "normal" {
                out.append(.listed(K.styles, style, absent: ["normal"], param: P.style, what: "the style '\(style)'"))
            }
            if let speed = params[P.speed]?.numberValue, speed != 1 {
                out.append(.flag(K.speed, param: P.speed, what: "a speed of \(speed)"))
            }
            if params[P.targetDuration] != nil {
                out.append(.flag(K.targetDuration, param: P.targetDuration, what: "a target duration"))
                if let d = params[P.targetDuration]?.numberValue {
                    out.append(.limit(L.maxDuration, d, param: P.targetDuration, what: "a \(d) s take"))
                }
            }
            if let t = text(I.text) {
                out.append(.limit(L.maxTextChars, Double(t.count), param: I.text, what: "\(t.count) characters of text"))
            }
        case "audio.edit_speech":
            if let edit = params[P.edit]?.objectValue, let kind = edit["kind"]?.stringValue {
                out.append(.listed(K.edits, kind, absent: [], param: P.edit, what: "a \(kind) edit"))
                if kind == "emotion", let label = edit["emotion"]?.stringValue {
                    out.append(.listed(K.emotions, label, absent: [], param: P.edit, what: "the emotion '\(label)'"))
                }
                if kind == "style", let style = edit["style"]?.stringValue {
                    out.append(.listed(K.styles, style, absent: [], param: P.edit, what: "the style '\(style)'"))
                }
                if kind == "add_cue" || kind == "remove_cue" {
                    if let cue = edit["cue"]?.stringValue {
                        out.append(.listed(K.cues, cue, absent: [], param: P.edit, what: "the cue '\(cue)'"))
                    } else {
                        out.append(OfferRequirement(param: P.edit, what: "removing cues") {
                            !($0.supports(K.cues)?.arrayValue ?? []).isEmpty
                        })
                    }
                }
            }
            if let t = text(I.transcript) {
                out.append(.limit(L.maxTextChars, Double(t.count), param: I.transcript, what: "a \(t.count)-character transcript"))
            }
            if inputs[I.transcript] == nil {
                out.append(OfferRequirement(param: I.transcript, what: "an edit without a transcript") {
                    $0.supports(K.transcript)?.stringValue != "required"
                })
            }
        case "audio.generate":
            if let d = params[P.duration]?.numberValue {
                out.append(.limit(L.maxDuration, d, param: P.duration, what: "a \(d) s sound"))
                out.append(.limit(L.minDuration, d, atMost: false, param: P.duration, what: "a \(d) s sound"))
            }
        case "audio.compose":
            if let l = params[P.language]?.stringValue { out.append(language(l)) }
            if inputs[I.lyrics] == nil {
                out.append(.flag(K.instrumental, param: I.lyrics, what: "an instrumental (no lyrics)"))
            }
            if inputs[I.score] != nil || params[P.planning] != nil {
                out.append(OfferRequirement(param: inputs[I.score] != nil ? I.score : P.planning, what: "a score") {
                    ($0.supports(K.score)?.stringValue ?? "unused") != "unused"
                })
            }
            if inputs[I.reference] != nil {
                out.append(.flag(K.reference, param: I.reference, what: "a reference recording"))
            }
            if let edit = params[P.edit]?.objectValue, let kind = edit["kind"]?.stringValue {
                out.append(.listed(K.edits, kind, absent: [], param: P.edit, what: "a \(kind) edit"))
                if kind == "repaint", let s = edit["start_s"]?.numberValue, let e = edit["end_s"]?.numberValue {
                    out.append(.limit(L.maxRepaintSeconds, e - s, param: P.edit, what: "a \(e - s) s repaint"))
                }
            }
            if let d = params[P.duration]?.numberValue {
                out.append(.limit(L.maxDuration, d, param: P.duration, what: "a \(d) s song"))
                out.append(.limit(L.minDuration, d, atMost: false, param: P.duration, what: "a \(d) s song"))
            }
            if let lyrics = text(I.lyrics) {
                out.append(.limit(L.maxLyricsChars, Double(lyrics.count), param: I.lyrics, what: "\(lyrics.count) characters of lyrics"))
            }
        default: break
        }
        return out
    }

    /// Warnings for the Warn keys the chosen offer lacks (§4.1).
    public static func warnings(_ request: JobRequest, descriptor: Descriptor, model: ModelOffer) -> [Warning] {
        let params = request.params ?? [:], inputs = request.inputs ?? [:]
        var out: [Warning] = []
        switch descriptor.operation {
        case "audio.speak":
            if params[P.emotion]?["intensity"] != nil, model.supports(K.emotionIntensity)?.boolValue != true {
                out.append(Warning(code: AudioProfile.WarningCode.emotionIntensityIgnored,
                                   message: "\(model.title) has no emotion intensity; the label applies at its own strength.", param: P.emotion))
            }
            if inputs[I.voiceRefText] != nil, (model.supports(K.voiceRefText)?.stringValue ?? "unused") == "unused" {
                out.append(Warning(code: AudioProfile.WarningCode.voiceRefTextIgnored,
                                   message: "\(model.title) clones from the clip alone; the transcript wasn't used.", param: I.voiceRefText))
            }
        case "audio.compose":
            if let anchors = params[P.anchors]?.objectValue {
                let kept = Set(model.supports(K.anchors)?.arrayValue?.compactMap(\.stringValue) ?? [])
                let ignored = anchors.keys.filter { !kept.contains($0) }.sorted()
                if !ignored.isEmpty {
                    out.append(Warning(code: AudioProfile.WarningCode.anchorsIgnored,
                                       message: "\(model.title) can't keep \(ignored.joined(separator: ", ")).", param: P.anchors))
                }
            }
            if params[P.timestamps]?.boolValue == true, model.supports(K.timestamps)?.boolValue != true {
                out.append(Warning(code: AudioProfile.WarningCode.timestampsUnavailable,
                                   message: "\(model.title) doesn't time its lyrics.", param: P.timestamps))
            }
            if case .text(let lyrics)? = inputs[I.lyrics] {
                let offered = Set(model.supports(K.sections)?.arrayValue?.compactMap(\.stringValue) ?? AudioProfile.sections)
                let unsupported = Array(Set(AudioProfile.sectionTags(lyrics)).subtracting(offered)).sorted()
                if !unsupported.isEmpty {
                    out.append(Warning(code: AudioProfile.WarningCode.sectionUnsupported,
                                       message: "\(model.title) has no \(unsupported.joined(separator: ", ")) section; mapped to the nearest it has, or dropped.",
                                       param: I.lyrics))
                }
            }
        default: break
        }
        return out
    }

    /// `speak` text without the cues the model can't perform (§2.2): each removed cue warns `cue_unsupported` once.
    /// `pause` is always kept: every engine honours it.
    public static func removeUnsupportedCues(_ text: String, model: ModelOffer) -> (String, [Warning]) {
        let segments = AudioProfile.segments(text)
        guard segments.contains(where: { if case .cue = $0 { true } else { false } }) else { return (text, []) }
        let performed = Set(model.supports(K.cues)?.arrayValue?.compactMap(\.stringValue) ?? []).union(["pause"])
        var removed: [String] = []
        let kept = segments.filter { segment in
            guard case .cue(let name, _) = segment else { return true }
            if performed.contains(name) { return true }
            if !removed.contains(name) { removed.append(name) }
            return false
        }
        guard !removed.isEmpty else { return (text, []) }
        let warnings = removed.map { name in
            Warning(code: AudioProfile.WarningCode.cueUnsupported,
                    message: AudioProfile.cues.contains(name) ? "\(model.title) can't perform [\(name)]; it was removed."
                        : "[\(name)] isn't a registered cue; it was removed.", param: I.text)
        }
        return (AudioProfile.text(kept), warnings)
    }
}
