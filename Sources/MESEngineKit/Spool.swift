import CryptoKit
import Foundation
import MESCore

/// The engine's private storage: `uploads/<id>` and `jobs/<id>/{inputs,outputs}`. Everything in it is temporary
/// by contract (Base §13), so a start wipes it: an interrupted job's media never survives a crash.
struct Spool: Sendable {
    let root: URL
    var uploads: URL { root.appendingPathComponent("uploads", isDirectory: true) }
    var jobs: URL { root.appendingPathComponent("jobs", isDirectory: true) }

    /// Creates the spool, deleting whatever a previous run left behind. Returns how many items were swept.
    @discardableResult
    static func prepare(at root: URL) throws -> (Spool, swept: Int) {
        let fm = FileManager.default
        let spool = Spool(root: root)
        var swept = 0
        for dir in [spool.uploads, spool.jobs] {
            if let leftovers = try? fm.contentsOfDirectory(atPath: dir.path) { swept += leftovers.count }
            try? fm.removeItem(at: dir)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return (spool, swept)
    }

    func uploadFile(_ id: String) -> URL { uploads.appendingPathComponent(id) }
    func jobDirectory(_ id: String) -> URL { jobs.appendingPathComponent(id, isDirectory: true) }
    func inputsDirectory(_ id: String) -> URL { jobDirectory(id).appendingPathComponent("inputs", isDirectory: true) }
    func outputsDirectory(_ id: String) -> URL { jobDirectory(id).appendingPathComponent("outputs", isDirectory: true) }

    func makeJobDirectories(_ id: String) throws {
        try FileManager.default.createDirectory(at: inputsDirectory(id), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputsDirectory(id), withIntermediateDirectories: true)
    }

    func deleteInputs(_ id: String) { try? FileManager.default.removeItem(at: inputsDirectory(id)) }
    func deleteJob(_ id: String) { try? FileManager.default.removeItem(at: jobDirectory(id)) }
}

enum Hashing {
    /// SHA-256 of a file, streamed.
    static func sha256(of url: URL) throws -> (hex: String, bytes: Int) {
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

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

enum IDs {
    private static let alphabet = Array("0123456789abcdefghjkmnpqrstvwxyz")
    static func make(_ prefix: String, length: Int = 20) -> String {
        prefix + String((0..<length).map { _ in alphabet.randomElement()! })
    }
}

/// Media type → file extension for spool and output files.
enum MediaTypes {
    static func fileExtension(_ mediaType: String) -> String {
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
        case "application/json": "json"
        default: "bin"
        }
    }
}
