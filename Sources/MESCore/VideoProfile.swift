import Foundation

/// The Video profile 0.1 (spec/profiles/video.md): the operations table, the vocabulary names, the `supports` keys and
/// limit fields, and the frame and size grids.
public enum VideoProfile {
    public static let id = "video"
    public static let version = "0.1"

    /// The vocabulary names (§2). Descriptor params for these concepts MUST use these names.
    public enum Param {
        public static let negativePrompt = "negative_prompt", duration = "duration_s", fps = "fps", size = "size"
        public static let aspect = "aspect", resolution = "resolution", keyframeTimes = "keyframe_times", audio = "audio"
        public static let after = "after_s", before = "before_s", start = "start_s", end = "end_s", retake = "retake"
        public static let scale = "scale", content = "content", factor = "factor", seed = "seed", quality = "quality"
        public static let output = "output", promptEnhance = "prompt_enhance"
    }

    /// The operations' input names (§3).
    public enum Input {
        public static let prompt = "prompt", firstFrame = "first_frame", lastFrame = "last_frame", keyframes = "keyframes"
        public static let soundtrack = "soundtrack", references = "references", control = "control", video = "video"
    }

    /// `retake`: what to make again in the span (§3.3).
    public static let retakeModes = ["picture", "sound", "both"]
    /// `content`: what an upscaled video is (§3.4).
    public static let contents = ["live_action", "drawn"]
    /// `output.codec` (§1.2).
    public static let codecs = ["h264", "hevc"]

    /// Warning codes the profile adds (§5).
    public enum WarningCode {
        public static let sizeSnapped = "size_snapped", durationSnapped = "duration_snapped", fpsAdjusted = "fps_adjusted"
        public static let spanSnapped = "span_snapped", keyframeMoved = "keyframe_moved", soundtrackFitted = "soundtrack_fitted"
        public static let videoRetimed = "video_retimed", colorConverted = "color_converted", audioResampled = "audio_resampled"
        public static let audioUnavailable = "audio_unavailable", negativePromptIgnored = "negative_prompt_ignored"
        public static let promptRewritten = "prompt_rewritten", promptEnhanceIgnored = "prompt_enhance_ignored"
        public static let promptEnhanceFailed = "prompt_enhance_failed"
    }

    /// Helper roles the profile registers (Base §10.1).
    public enum HelperRole {
        /// A model that rewrote the prompt.
        public static let promptEnhance = "prompt_enhance"
    }

    /// Progress phases (§1.15).
    public enum Phase {
        public static let encode = "encode", denoise = "denoise", upsample = "upsample", decode = "decode"
        public static let upscale = "upscale", interpolate = "interpolate", mux = "mux"
    }

    /// `supports` keys the profile defines (§4.1). Base defines `stream`, `seed` and `voices`.
    public enum SupportsKey {
        public static let firstFrame = "first_frame", lastFrame = "last_frame", keyframes = "keyframes"
        public static let soundtrack = "soundtrack", references = "references", audio = "audio"
        public static let sampleRate = "sample_rate", channels = "channels", negativePrompt = "negative_prompt"
        public static let frameRates = "frame_rates", frameStep = "frame_step", sizeStep = "size_step"
        public static let extendBefore = "extend_before", retake = "retake", overlap = "overlap_s", scales = "scales"
        public static let content = "content", deterministic = "deterministic", previews = "previews"
    }

    /// Limit fields the profile defines (§4.2), on a descriptor or an offer, beside Base's.
    public enum LimitField {
        public static let minWidth = "min_width", minHeight = "min_height", minDuration = "min_duration_s"
        public static let maxFrames = "max_frames", maxFPS = "max_fps", maxKeyframes = "max_keyframes"
        public static let maxSoundtrackSeconds = "max_soundtrack_s", maxSourceSeconds = "max_source_s"
        public static let maxExtendSeconds = "max_extend_s", maxRetakeSeconds = "max_retake_s", maxFactor = "max_factor"
    }

    /// The bundled copy of schemas/v0/profiles/video/operations.json (a test keeps the two identical).
    public static let operations: ProfileTable = .bundled("video-operations")

    /// The bundled copy of schemas/v0/profiles/video/vocabulary.schema.json.
    public static let vocabulary: JSONValue = ProfileTable.bundledVocabulary("video-vocabulary")

    /// The vocabulary definition for a parameter name, with every `$ref` inlined (as `ImageProfile.vocabularySchema`).
    public static func vocabularySchema(_ name: String, operation: String) -> JSONValue? {
        operations.vocabularySchema(name, operation: operation, vocabulary: vocabulary)
    }

    // MARK: - Grids (§1.4)

    /// A model's frame grid: frames are k × `multiple` + `offset` (LTX: 8k + 1).
    public struct FrameStep: Sendable, Equatable, Codable {
        public var multiple: Int
        public var offset: Int
        public init(multiple: Int, offset: Int) { self.multiple = max(1, multiple); self.offset = max(0, offset) }
        public static let any = FrameStep(multiple: 1, offset: 0)

        /// The offer's grid, from `supports.frame_step` (absent: any count).
        public init(_ offer: ModelOffer) {
            let v = offer.supports(SupportsKey.frameStep)
            self.init(multiple: v?["multiple"]?.intValue ?? 1, offset: v?["offset"]?.intValue ?? 0)
        }

        /// Whether `frames` lies on the grid.
        public func admits(_ frames: Int) -> Bool { frames >= max(1, offset) && (frames - offset) % multiple == 0 }

        /// The admissible count nearest `frames` (ties go up), at least the grid's smallest positive count.
        public func nearest(_ frames: Double) -> Int {
            let k = ((frames - Double(offset)) / Double(multiple)).rounded(.toNearestOrAwayFromZero)
            let smallest = offset > 0 ? offset : multiple
            return max(smallest, Int(k) * multiple + offset)
        }

        /// The largest admissible count at most `frames`, or nil.
        public func floor(_ frames: Int) -> Int? {
            guard frames >= max(1, offset) else { return nil }
            let n = (frames - offset) / multiple * multiple + offset
            return n >= 1 ? n : nil
        }
    }

    /// The frames for `seconds` at `fps` on `grid`: the nearest admissible count.
    public static func frames(seconds: Double, fps: Double, grid: FrameStep = .any) -> Int {
        grid.nearest(seconds * fps)
    }

    /// `size` snapped to multiples of `step`, rounding each side to the nearest multiple (at least one step).
    public static func snap(width: Int, height: Int, step: Int) -> (width: Int, height: Int) {
        guard step > 1 else { return (width, height) }
        func s(_ v: Int) -> Int { max(step, Int((Double(v) / Double(step)).rounded()) * step) }
        return (s(width), s(height))
    }

    /// The size `aspect` (`W:H`) at `resolution` (the short side), before any grid; nil for a malformed aspect.
    public static func size(aspect: String, resolution: Int) -> (width: Int, height: Int)? {
        let parts = aspect.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        let (w, h) = (parts[0], parts[1])
        if w >= h { return (Int((Double(resolution) * w / h).rounded()), resolution) }
        return (resolution, Int((Double(resolution) * h / w).rounded()))
    }

    /// The text a generated clip's comment item carries (§1.9): `AI-generated` and the model's title.
    public static func disclosure(model: String) -> String { "AI-generated with \(model)." }

    /// Whether a comment item carries the AI-content disclosure (§1.9).
    public static func isDisclosure(_ comment: String) -> Bool { comment.contains("AI-generated") }
}
