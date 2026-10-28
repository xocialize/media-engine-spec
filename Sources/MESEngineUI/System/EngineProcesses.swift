import Darwin
import Foundation

/// One process of an engine: the app itself, or a worker it runs (Gaea runs each plugin in a process of its own).
public struct EngineProcess: Sendable, Equatable, Hashable, Identifiable {
    public enum Role: String, Sendable, Equatable, Hashable {
        /// The engine app: the server, queue and UI.
        case host
        /// A worker process that runs models.
        case worker
    }

    /// Stable across samples, e.g. the plugin id. The page keeps each process's history under it.
    public var id: String
    /// "Gaea", "Z-Image".
    public var title: String
    /// A line under the title, e.g. the models it has loaded.
    public var detail: String?
    public var pid: pid_t?
    public var role: Role

    public init(id: String, title: String, detail: String? = nil, pid: pid_t? = nil, role: Role = .worker) {
        self.id = id; self.title = title; self.detail = detail; self.pid = pid; self.role = role
    }

    /// This process, as the host.
    public static func current(title: String = ProcessInfo.processInfo.processName) -> EngineProcess {
        EngineProcess(id: "host", title: title, pid: getpid(), role: .host)
    }
}

/// A process's physical footprint at one moment.
public struct ProcessFootprint: Sendable, Equatable, Identifiable {
    public var process: EngineProcess
    /// `phys_footprint`: what Activity Monitor shows as Memory.
    public var bytes: UInt64
    public var id: String { process.id }

    public init(process: EngineProcess, bytes: UInt64) {
        self.process = process; self.bytes = bytes
    }

    /// Reads `process.pid`'s footprint with `proc_pid_rusage` (`ri_phys_footprint`). Nil when the process has no pid, has
    /// exited, or isn't readable by this user (a child of this app always is).
    public static func read(_ process: EngineProcess) -> ProcessFootprint? {
        guard let pid = process.pid, let bytes = physFootprint(pid: pid) else { return nil }
        return ProcessFootprint(process: process, bytes: bytes)
    }

    /// `ri_phys_footprint` from `proc_pid_rusage(pid, RUSAGE_INFO_V4)`.
    public static func physFootprint(pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? info.ri_phys_footprint : nil
    }
}

/// Where the System page's engine memory comes from.
///
/// - `currentProcess`: this process only, for an engine that runs its models in process (the default).
/// - `processes`: the backend lists its processes (host and workers) and the page reads each pid with `proc_pid_rusage`.
/// - `readings`: the backend measures them itself, e.g. from its workers' memory reports.
///
/// The closures run once a sample, off the main actor, so they should be quick.
public enum EngineProcessSource: Sendable {
    case currentProcess
    case processes(@Sendable () async -> [EngineProcess])
    case readings(@Sendable () async -> [ProcessFootprint])

    func read() async -> [ProcessFootprint] {
        switch self {
        case .currentProcess:
            return ProcessFootprint.read(.current(title: "Engine")).map { [$0] } ?? []
        case .processes(let list):
            return await list().compactMap(ProcessFootprint.read)
        case .readings(let readings):
            return await readings()
        }
    }
}
