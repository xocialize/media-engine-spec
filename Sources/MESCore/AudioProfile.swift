import Foundation

/// The Audio profile 0.1 (spec/profiles/audio.md): the operations table, the vocabulary names, the one label set
/// (emotions, styles, cues, edit kinds, section tags), the `supports` keys and the cue syntax.
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
    public static let cues = ["laugh", "cough", "sigh", "breath", "gasp", "clear_throat", "hesitation", "sob", "sniff", "pause"]
    /// Speech edit kinds (§3.3), modelled on AuK's instruction set.
    public static let editKinds = ["emotion", "style", "add_cue", "remove_cue", "replace_text", "insert_text", "remove_text",
                                   "speed", "pitch", "volume", "timbre", "de_accent", "denoise", "trim_silence"]
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
