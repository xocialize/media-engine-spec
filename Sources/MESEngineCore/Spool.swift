import CryptoKit
import Foundation
import MESCore

/// The engine's private storage: `uploads/<id>`, `assets/<id>` and `jobs/<id>/{inputs,outputs}`. Everything in it is
/// temporary by contract (Base §13), so a start wipes it: an interrupted job's media never survives a crash, and assets
/// don't survive a restart (§8.1 allows that; clients create them again).
package struct Spool: Sendable {
    package let root: URL
    package var uploads: URL { root.appendingPathComponent("uploads", isDirectory: true) }
    package var jobs: URL { root.appendingPathComponent("jobs", isDirectory: true) }
    package var assets: URL { root.appendingPathComponent("assets", isDirectory: true) }

    /// Creates the spool, deleting whatever a previous run left behind. Returns how many items were swept.
    @discardableResult
    package static func prepare(at root: URL) throws -> (Spool, swept: Int) {
        let fm = FileManager.default
        let spool = Spool(root: root)
        var swept = 0
        for dir in [spool.uploads, spool.assets, spool.jobs] {
            if let leftovers = try? fm.contentsOfDirectory(atPath: dir.path) { swept += leftovers.count }
            try? fm.removeItem(at: dir)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return (spool, swept)
    }

    package func uploadFile(_ id: String) -> URL { uploads.appendingPathComponent(id) }
    package func assetFile(_ id: String) -> URL { assets.appendingPathComponent(id) }
    package func jobDirectory(_ id: String) -> URL { jobs.appendingPathComponent(id, isDirectory: true) }
    package func inputsDirectory(_ id: String) -> URL { jobDirectory(id).appendingPathComponent("inputs", isDirectory: true) }
    package func outputsDirectory(_ id: String) -> URL { jobDirectory(id).appendingPathComponent("outputs", isDirectory: true) }

    package func makeJobDirectories(_ id: String) throws {
        try FileManager.default.createDirectory(at: inputsDirectory(id), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputsDirectory(id), withIntermediateDirectories: true)
    }

    package func deleteInputs(_ id: String) { try? FileManager.default.removeItem(at: inputsDirectory(id)) }
    package func deleteJob(_ id: String) { try? FileManager.default.removeItem(at: jobDirectory(id)) }
}

package enum Hashing {
    /// SHA-256 of a file, streamed.
    package static func sha256(of url: URL) throws -> (hex: String, bytes: Int) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var total = 0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            total += chunk.count
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), total)
    }

    package static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

package enum IDs {
    private static let alphabet = Array("0123456789abcdefghjkmnpqrstvwxyz")
    package static func make(_ prefix: String, length: Int = 20) -> String {
        prefix + String((0..<length).map { _ in alphabet.randomElement()! })
    }
}

/// Media type → file extension for spool and output files.
package enum MediaTypes {
    package static func fileExtension(_ mediaType: String) -> String {
        switch mediaType {
        case "image/png": "png"
        case "image/jpeg": "jpg"
        case "image/heic": "heic"
        case "image/webp": "webp"
        case "image/tiff": "tiff"
        case "video/mp4": "mp4"
        case "video/quicktime": "mov"
        case "audio/wav", "audio/x-wav": "wav"
        case "audio/mpeg": "mp3"
        case "audio/flac", "audio/x-flac": "flac"
        case "audio/mp4", "audio/aac": "m4a"
        case "audio/ogg", "audio/opus": "ogg"
        case "text/plain": "txt"
        case "text/vnd.abc": "abc"
        case "application/json": "json"
        default: "bin"
        }
    }
}
