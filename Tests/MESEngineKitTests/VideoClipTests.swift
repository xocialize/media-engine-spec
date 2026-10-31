import Foundation
@testable import MockEngineCore
import Testing

// The mock's MP4 plumbing (Clips): what it writes, it reads back with the same facts.
@Suite("Video clips")
struct VideoClipTests {
    static func clip(frames: Int = 17, audio: Bool = true) -> Clip {
        let w = 128, h = 96
        let frames = (0..<frames).map { Clips.synthetic(width: w, height: h, color: (40, 90, 200), t: Double($0) / 16) }
        let samples: [Float]? = audio ? (0..<(48_000 * frames.count / 24)).flatMap { i -> [Float] in
            let s = Float(0.2 * sin(2 * Double.pi * 440 * Double(i) / 48_000)); return [s, s]
        } : nil
        return Clip(width: w, height: h, fps: 24, frames: frames, audio: samples, comment: "AI-generated with Mock.", copyright: "Apache-2.0")
    }

    @Test("H.264 and HEVC with AAC round-trip: size, rate, frames, audio and metadata", arguments: [Clips.Codec.h264, .hevc])
    func roundTrip(codec: Clips.Codec) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let original = Self.clip()
        try await Clips.write(original, to: url, codec: codec)
        let (clip, facts) = try await Clips.read(url)
        #expect(facts.width == 128 && facts.height == 96)
        #expect(facts.frames == 17 && clip.frames.count == 17)
        #expect(abs(facts.fps - 24) < 0.01)
        #expect(facts.codec == (codec == .h264 ? "avc1" : "hvc1"))
        #expect(facts.sampleRate == 48_000 && facts.channels == 2)
        #expect(abs((facts.audioSeconds ?? 0) - 17.0 / 24) < 0.05)
        #expect(facts.comment == "AI-generated with Mock." && facts.copyright == "Apache-2.0")
        for i in [0, 8, 16] { #expect(Clips.meanError(clip.frames[i], original.frames[i]) < 8) }
        let counted = try await Clips.facts(url)
        #expect(counted.frames == 17)
    }

    @Test("A silent clip has no audio track")
    func silent() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try await Clips.write(Self.clip(frames: 9, audio: false), to: url)
        let facts = try await Clips.facts(url)
        #expect(facts.frames == 9 && !facts.hasAudio && facts.sampleRate == nil)
    }
}
