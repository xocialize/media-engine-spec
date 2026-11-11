import Foundation

/// The Audio profile 0.1 (spec/profiles/audio.md): the operations table, the vocabulary names, the one label set
/// (emotions, styles, cues, edit kinds, section tags, stems), the `supports` keys and the cue syntax.
public enum AudioProfile {
    public static let id = "audio"
    public static let version = "0.1"

    /// The vocabulary names (§2). Descriptor params for these concepts MUST use these names.
    public enum Param {
        public static let language = "language", seed = "seed", count = "count", quality = "quality", output = "output"
        public static let voice = "voice", emotion = "emotion", style = "style", speed = "speed"
        public static let targetDuration = "target_duration_s", edit = "edit", negativePrompt = "negative_prompt"
        public static let duration = "duration_s", planning = "planning", anchors = "anchors", timestamps = "timestamps"
        public static let promptEnhance = "prompt_enhance"
        /// `separate` (§3.6, RFC 0006).
        public static let stems = "stems", speaker = "speaker"
        /// `separate` by description (§3.6, RFC 0008): the sound to separate, and where it is heard or isn't.
        public static let describe = "describe", spans = "spans"
    }

    /// The operations' input names (§3).
    public enum Input {
        public static let description = "description", text = "text", voiceRef = "voice_ref", voiceRefText = "voice_ref_text"
        public static let audio = "audio", transcript = "transcript", prompt = "prompt", caption = "caption"
        public static let lyrics = "lyrics", score = "score", reference = "reference", source = "source"
    }

    /// The registered emotion labels (§2.1), adjectives as every package uses them.
    public static let emotions = ["neutral", "happy", "sad", "angry", "afraid", "disgusted", "surprised", "calm", "melancholic",
                                  "excited", "humorous", "confused", "empathetic", "embarrassed", "depressed", "cold", "admiring"]
    /// Aliases the engine resolves before anything else reads the request (§2.1): never the client's job.
    public static let emotionAliases = ["fearful": "afraid", "fear": "afraid", "scared": "afraid", "anger": "angry",
                                        "sadness": "sad", "happiness": "happy", "joy": "happy", "surprise": "surprised",
                                        "disgust": "disgusted"]
    /// The registered style labels (§2.1): delivery rather than feeling.
    public static let styles = ["normal", "whisper", "shout", "gentle", "serious", "warm", "narration", "conversational", "news"]
    /// The registered nonverbal cues (§2.2).
    public static let cues = ["laugh", "cough", "sigh", "breath", "gasp", "clear_throat", "hesitation", "sob", "sniff", "pause", "hum"]
    /// Speech edit kinds (§3.3), modelled on AuK's instruction set.
    public static let editKinds = ["emotion", "style", "add_cue", "remove_cue", "replace_text", "insert_text", "remove_text",
                                   "speed", "pitch", "volume", "timbre", "de_accent", "denoise", "dereverb", "trim_silence"]
    /// The fields each speech edit kind needs (§3.3).
    public static let editFields: [String: [String]] = [
        "emotion": ["emotion"], "style": ["style"], "add_cue": ["cue"], "remove_cue": [], "replace_text": ["text", "with"],
        "insert_text": ["text", "anchor", "position"], "remove_text": ["text"], "speed": ["factor"], "pitch": ["semitones"],
        "volume": ["gain_db"], "timbre": ["description"], "de_accent": [], "denoise": [], "dereverb": [], "trim_silence": [],
    ]
    /// The fields a speech edit kind may carry beyond the ones it needs.
    public static let editOptionalFields: [String: [String]] = ["add_cue": ["at", "text"], "remove_cue": ["cue"]]
    /// Where an `add_cue` edit puts its cue (§3.3): `edge` (`at`) or `inline` (`text`).
    public static let cuePlacements = ["edge", "inline"]
    /// The registered stems (§3.6): AuK's speech stems, the music separators', then the described sound and the rest.
    public static let stems = ["speaker", "singing", "voices", "vocals", "instrumental", "drums", "bass", "other", "target", "residual"]
    /// The stems a description makes (§3.6, RFC 0008): `target` is the sound `describe` names, `residual` the mixture
    /// without it. They need `describe`, and `describe` takes no other stem.
    public static let describedStems = ["target", "residual"]
    /// The ways `separate` picks one speaker (§3.6).
    public static let speakerSelections = ["ordinal", "saying"]
    /// How an offer makes its stems (§3.6): `masked` stems are sample-aligned with the mixture; `regenerated` ones are
    /// made again and must never be subtracted from it.
    public static let stemMethods = ["masked", "regenerated"]
    /// Song edit kinds (§3.5).
    public static let composeEditKinds = ["cover", "repaint", "extend"]
    /// Lyrics section tags (§3.5.1).
    public static let sections = ["intro", "verse", "pre-chorus", "chorus", "bridge", "solo", "instrumental", "outro"]

    /// The canonical emotion label for a label or alias; nil for neither.
    public static func canonicalEmotion(_ label: String) -> String? {
        let l = label.lowercased()
        if emotions.contains(l) { return l }
        return emotionAliases[l]
    }

    /// Warning codes the profile adds (§5).
    public enum WarningCode {
        public static let audioResampled = "audio_resampled", audioDownmixed = "audio_downmixed"
        public static let voiceRefTrimmed = "voice_ref_trimmed", voiceRefTextIgnored = "voice_ref_text_ignored"
        public static let durationMissed = "duration_missed", cueUnsupported = "cue_unsupported"
        public static let emotionIntensityIgnored = "emotion_intensity_ignored"
        public static let songTruncated = "song_truncated", sectionUnsupported = "section_unsupported"
        public static let anchorsIgnored = "anchors_ignored", timestampsUnavailable = "timestamps_unavailable"
        public static let promptRewritten = "prompt_rewritten", promptEnhanceIgnored = "prompt_enhance_ignored"
        public static let promptEnhanceFailed = "prompt_enhance_failed"
    }

    /// Helper roles the profile registers (Base §10.1).
    public enum HelperRole {
        /// A model that rewrote a voice description.
        public static let promptEnhance = "prompt_enhance"
    }

    /// `supports` keys the profile defines (§4.1). Base defines `stream`, `seed` and `voices`.
    public enum SupportsKey {
        public static let languages = "languages", defaultVoice = "default_voice", voiceRef = "voice_ref"
        public static let voiceRefText = "voice_ref_text", emotions = "emotions", emotionDescription = "emotion_description"
        public static let emotionIntensity = "emotion_intensity", styles = "styles", cues = "cues", speed = "speed"
        public static let targetDuration = "target_duration", edits = "edits", transcript = "transcript"
        public static let keepsLength = "keeps_length", instrumental = "instrumental", score = "score"
        public static let reference = "reference", sections = "sections", anchors = "anchors", timestamps = "timestamps"
        public static let sampleRate = "sample_rate", channels = "channels"
        /// `edit_speech` (RFC 0006): where `add_cue` may put a cue, and whether `remove_cue` may remove every cue.
        public static let cuePlacement = "cue_placement", removeAllCues = "remove_all_cues"
        /// `separate` (RFC 0006): the stems an offer makes, the speaker picks it takes, and how it makes stems.
        public static let stems = "stems", speakerSelection = "speaker_selection", stemMethod = "stem_method"
        /// `separate` (RFC 0008): the offer separates a sound the request describes, and takes spans for it.
        public static let describedTarget = "described_target", spans = "spans"
    }

    /// Limit fields the profile defines (§4.2), on a descriptor or an offer.
    public enum LimitField {
        public static let maxTextChars = "max_text_chars", maxVoiceRefSeconds = "max_voice_ref_s"
        public static let minDuration = "min_duration_s", maxDuration = "max_duration_s", maxLyricsChars = "max_lyrics_chars"
        public static let maxReferenceSeconds = "max_reference_s", maxSourceSeconds = "max_source_s"
        public static let maxRepaintSeconds = "max_repaint_s"
    }

    /// The bundled copy of schemas/v0/profiles/audio/operations.json (a test keeps the two identical).
    public static let operations: ProfileTable = .bundled("audio-operations")

    /// The bundled copy of schemas/v0/profiles/audio/vocabulary.schema.json.
    public static let vocabulary: JSONValue = ProfileTable.bundledVocabulary("audio-vocabulary")

    /// The vocabulary definition for a parameter name, with every `$ref` inlined (as `ImageProfile.vocabularySchema`).
    public static func vocabularySchema(_ name: String, operation: String) -> JSONValue? {
        operations.vocabularySchema(name, operation: operation, vocabulary: vocabulary)
    }

    // MARK: - Cues (§2.2)

    /// A piece of `speak` text: words, or a nonverbal cue (`[laugh]`, `[pause 1.5s]`).
    public enum Segment: Sendable, Equatable {
        case text(String)
        /// A cue by name; `seconds` for `pause`.
        case cue(String, seconds: Double?)
    }

    /// Splits text into words and cues, in the profile's one syntax: a cue is `[name]` or `[pause <n>s]`, and `\[` is a
    /// literal bracket. Bracketed text that isn't cue-shaped (`[S1]`, `[a long aside]`) stays text.
    public static func segments(_ text: String) -> [Segment] {
        var out: [Segment] = []
        var buffer = ""
        var i = text.startIndex
        func flush() { if !buffer.isEmpty { out.append(.text(buffer)); buffer = "" } }
        while i < text.endIndex {
            let c = text[i]
            if c == "\\", text.index(after: i) < text.endIndex, text[text.index(after: i)] == "[" {
                buffer.append("[")
                i = text.index(i, offsetBy: 2)
                continue
            }
            if c == "[", let close = text[i...].firstIndex(of: "]") {
                let body = String(text[text.index(after: i)..<close])
                if let m = body.wholeMatch(of: /([a-z_]+)(?: ([0-9]+(?:\.[0-9]+)?)s)?/) {
                    flush()
                    out.append(.cue(String(m.1), seconds: m.2.flatMap { Double($0) }))
                    i = text.index(after: close)
                    continue
                }
            }
            buffer.append(c)
            i = text.index(after: i)
        }
        flush()
        return out
    }

    /// The text with its cues written back in the profile's syntax (literal brackets escaped).
    public static func text(_ segments: [Segment]) -> String {
        segments.map { segment in
            switch segment {
            case .text(let s): s.replacingOccurrences(of: "[", with: "\\[")
            case .cue(let name, let seconds): seconds.map { "[\(name) \(Self.format($0))s]" } ?? "[\(name)]"
            }
        }.joined()
    }

    static func format(_ seconds: Double) -> String {
        seconds == seconds.rounded() ? String(Int(seconds)) : String(seconds)
    }

    // MARK: - Lyrics (§3.5.1)

    /// The section tags in lyrics, in order: a tag is a line of its own, `[name]` or `[name - direction]`,
    /// case-insensitive. Lyrics with no tag are one `verse`.
    public static func sectionTags(_ lyrics: String) -> [String] {
        let tags = lyrics.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let m = t.wholeMatch(of: /\[([A-Za-z-]+)(?:\s+-\s+[^\]]*)?\]/) else { return nil }
            return m.1.lowercased()
        }
        return tags.isEmpty ? ["verse"] : tags
    }
}

/// A stretch of a mixture where a described sound is heard, or is not (Audio §3.6, RFC 0008): seconds from the
/// mixture's start, `end` after `start`.
public struct SeparationSpan: Codable, Sendable, Equatable {
    public var start: Double
    public var end: Double
    /// `true`: the sound is heard throughout the span. `false`: it isn't heard in it.
    public var present: Bool
    public init(start: Double, end: Double, present: Bool) { self.start = start; self.end = end; self.present = present }
    enum CodingKeys: String, CodingKey { case start = "start_s", end = "end_s", present }

    /// The span as it travels in `spans`.
    public var json: JSONValue { ["start_s": .number(start), "end_s": .number(end), "present": .bool(present)] }

    /// The spans of a `spans` value, in time order; nil when it isn't a list of whole spans.
    public static func list(_ value: JSONValue?) -> [SeparationSpan]? {
        guard let items = value?.arrayValue else { return nil }
        var out: [SeparationSpan] = []
        for item in items {
            guard let start = item["start_s"]?.numberValue, let end = item["end_s"]?.numberValue,
                  let present = item["present"]?.boolValue else { return nil }
            out.append(SeparationSpan(start: start, end: end, present: present))
        }
        return out.sorted { $0.start < $1.start }
    }

    /// What is wrong with a list of spans on its own (§3.6: each 400): a span that ends at or before its start, or
    /// two that overlap. Spans may touch. Nil when the list is sound.
    public static func problem(_ spans: [SeparationSpan]) -> String? {
        if let bad = spans.first(where: { $0.end <= $0.start }) {
            return "A span ends after it starts; one runs from \(bad.start) s to \(bad.end) s."
        }
        let ordered = spans.sorted { $0.start < $1.start }
        for (a, b) in zip(ordered, ordered.dropFirst()) where b.start < a.end {
            return "Spans don't overlap; \(a.start)–\(a.end) s and \(b.start)–\(b.end) s do."
        }
        return nil
    }

    /// The first span that ends more than a frame after a mixture `seconds` long (§3.6: refused `out_of_limits`).
    public static func firstPastEnd(_ spans: [SeparationSpan], mixtureSeconds seconds: Double, sampleRate: Double) -> SeparationSpan? {
        spans.first { $0.end > seconds + 1.0 / max(sampleRate, 1) + 1e-9 }
    }
}

extension JobResult {
    /// The output named `name` (its first, for an output with several values).
    public func output(named name: String) -> Output? { outputs.first { $0.name == name } }

    /// Audio `separate` (§3.6, RFC 0006): each stem the job made with its output, in the order the job made them
    /// (`effective.stems`, else the outputs' order).
    public var stems: [(stem: String, output: Output)] {
        let order = effective[AudioProfile.Param.stems]?.arrayValue?.compactMap(\.stringValue)
            ?? outputs.map(\.name).filter(AudioProfile.stems.contains)
        return order.compactMap { stem in output(named: stem).map { (stem, $0) } }
    }

    /// Audio `separate` by description (RFC 0008): the description the model was given (`effective.describe`), and
    /// the spans that ran (`effective.spans`).
    public var describedSound: String? { effective[AudioProfile.Param.describe]?.stringValue }
    public var separationSpans: [SeparationSpan]? { SeparationSpan.list(effective[AudioProfile.Param.spans]) }
}
