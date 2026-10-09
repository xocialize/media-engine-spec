import dnssd
import Foundation
import MESCore

/// Advertises the engine as `_mes-engine._tcp` (Base §3.1) with the spec's TXT keys. Built on `dns_sd` with a
/// dispatch queue, so it works in headless processes (adapted from ML[X] Image Server's Bonjour advertiser, same
/// author). Open mode advertises on this machine only; paired mode on every interface.
final class EngineAdvertiser: @unchecked Sendable {
    static let serviceType = "_mes-engine._tcp"
    private var ref: DNSServiceRef?
    private let queue = DispatchQueue(label: "mes.engine.advertiser")

    func start(name: String, port: Int, txt: [String: String], localOnly: Bool) {
        let record = Self.txtRecord(txt)
        queue.async { [self] in
            guard ref == nil else { return }
            var service: DNSServiceRef?
            let interface = localOnly ? UInt32(bitPattern: Int32(-1)) : 0           // kDNSServiceInterfaceIndexLocalOnly
            let error = record.withUnsafeBytes { bytes in
                DNSServiceRegister(&service, 0, interface, name, Self.serviceType, nil, nil, UInt16(port).bigEndian,
                                   UInt16(record.count), bytes.baseAddress, nil, nil)
            }
            guard error == kDNSServiceErr_NoError, let service else { return }
            DNSServiceSetDispatchQueue(service, queue)
            ref = service
        }
    }

    func stop() {
        queue.sync {
            if let ref { DNSServiceRefDeallocate(ref) }
            ref = nil
        }
    }

    deinit { if let ref { DNSServiceRefDeallocate(ref) } }

    /// RFC 6763 §6: length-prefixed `key=value` strings, each at most 255 bytes, sorted for stability.
    static func txtRecord(_ entries: [String: String]) -> Data {
        var data = Data()
        for (key, value) in entries.sorted(by: { $0.key < $1.key }) {
            let entry = Data("\(key)=\(value)".utf8.prefix(255))
            data.append(UInt8(entry.count))
            data.append(entry)
        }
        return data
    }

    /// The TXT keys Base §3.1 defines.
    static func txt(config: EngineConfiguration, profiles: [EngineInfo.ProfileVersions]) -> [String: String] {
        [
            "txtvers": "1",
            "mes": EngineConfiguration.baseVersions.joined(separator: ","),
            "profiles": profiles.flatMap { p in p.versions.map { "\(p.id)/\($0)" } }.joined(separator: ","),
            "id": config.id,
            "auth": config.mode.rawValue,
            "tls": config.mode == .paired ? "1" : "0",
            "path": config.basePath,
            "ver": config.implementationVersion,
        ]
    }
}
