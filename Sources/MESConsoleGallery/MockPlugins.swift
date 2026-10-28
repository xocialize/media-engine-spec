import Foundation
import MESCore
import MESEngineUI
import Synchronization

// The gallery's stand-in for Gaea's plugin manager: two installed plugins that carry the mock's models, one with an
// update and a version to roll back to, a trust list, and adds that ask for trust when the repo isn't ours. Nothing is
// downloaded; progress is simulated.

/// The plugins' state, shared by the plugin backend, the models backend and the engine's descriptors.
final class MockPluginStore: Sendable {
    static let ourTeam = EngineTeam(id: "CFZS6RXUCP", name: "Dustin Nielson")

    struct State {
        var plugins: [EnginePlugin]
        var trusted: [EngineTrustedTeam]
        var pending: [String: (request: PluginTrustRequest, plugin: EnginePlugin)] = [:]
    }

    private let state: Mutex<State>

    init() {
        let now = Date()
        state = Mutex(State(plugins: [
            EnginePlugin(id: "com.xocialize.gaea.mock-image", title: "Mock Image",
                         summary: "Synthetic, rule-abiding results for every Image operation.",
                         repository: URL(string: "https://github.com/xocialize/gaea-plugin-mock-image")!, version: "1.2.0",
                         rollbackVersion: "1.1.4", team: Self.ourTeam, models: ["mock", "mock-enhancer"],
                         lastChecked: now.addingTimeInterval(-3600)),
            EnginePlugin(id: "com.xocialize.gaea.mock-research", title: "Mock Research",
                         summary: "A stand-in for a research-licensed model family.",
                         repository: URL(string: "https://github.com/xocialize/gaea-plugin-mock-research")!, version: "0.9.0",
                         update: EngineUpdate(version: "1.0.0", notes: "Int4 lanes, 2.5 GB less at peak.",
                                              publishedAt: now.addingTimeInterval(-86_400),
                                              url: URL(string: "https://github.com/xocialize/gaea-plugin-mock-research/releases")),
                         team: Self.ourTeam, models: ["mock-research"], lastChecked: now.addingTimeInterval(-3600)),
        ], trusted: [EngineTrustedTeam(team: Self.ourTeam, builtIn: true)]))
    }

    var plugins: [EnginePlugin] { state.withLock { $0.plugins } }
    var trusted: [EngineTrustedTeam] { state.withLock { $0.trusted } }

    /// The plugin a model comes in.
    func plugin(of model: String) -> EnginePlugin? { state.withLock { s in s.plugins.first { $0.models.contains(model) } } }

    /// Whether a model's plugin is on and allowed to run (a model in no plugin is built in).
    func runs(_ model: String) -> Bool {
        guard let plugin = plugin(of: model) else { return true }
        return plugin.enabled && state.withLock { s in s.trusted.contains { $0.team == plugin.team } }
    }

    func mutate<T: Sendable>(_ body: (inout sending State) throws -> sending T) rethrows -> T { try state.withLock(body) }
}

struct MockPluginBackend: EnginePluginBackend {
    let store: MockPluginStore
    /// Called after a change that alters which models are offered.
    let onChange: @Sendable () async -> Void

    func plugins() async -> [EnginePlugin] { store.plugins }
    func trustedTeams() async -> [EngineTrustedTeam] { store.trusted }

    func add(repository: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> PluginInstallOutcome {
        let parts = repository.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2 else { throw MESError(.invalidRequest, "That isn't a repo URL.") }
        let owner = parts[0], name = parts[1].replacingOccurrences(of: ".git", with: "")
        if parts.contains("missing") {
            try await Task.sleep(for: .milliseconds(600))
            throw MESError(.notFound, "\(owner)/\(name) has no release with a .gaeaplugin.zip.")
        }
        try await simulate(progress)
        let ours = owner.lowercased() == "xocialize"
        let team = ours ? MockPluginStore.ourTeam : EngineTeam(id: "ABCDE12345", name: "Example Labs")
        let plugin = EnginePlugin(id: "com.\(owner.lowercased()).gaea.\(name.lowercased())", title: name.capitalized,
                                  summary: "Added from \(owner)/\(name).", repository: repository, version: "0.1.0",
                                  team: team, lastChecked: Date())
        return store.mutate { s in
            if s.trusted.contains(where: { $0.team == team }) {
                s.plugins.append(plugin)
                return .installed(plugin)
            }
            let request = PluginTrustRequest(id: UUID().uuidString, team: team, pluginID: plugin.id, pluginTitle: plugin.title,
                                             version: plugin.version, repository: repository,
                                             signingIdentity: "Developer ID Application: \(team.name) (\(team.id))",
                                             notarized: !name.lowercased().contains("unnotarized"), models: ["\(name.lowercased())-base"])
            s.pending[request.id] = (request, plugin)
            return .needsTrust(request)
        }
    }

    func trust(_ request: PluginTrustRequest, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await simulate(progress, steps: 6)
        store.mutate { s in
            guard let pending = s.pending.removeValue(forKey: request.id) else { return }
            if !s.trusted.contains(where: { $0.team == request.team }) {
                s.trusted.append(EngineTrustedTeam(team: request.team, addedAt: Date()))
            }
            s.plugins.removeAll { $0.id == pending.plugin.id }
            s.plugins.append(pending.plugin)
        }
    }

    func decline(_ request: PluginTrustRequest) async {
        _ = store.mutate { $0.pending.removeValue(forKey: request.id) }
    }

    func update(plugin id: String, to update: EngineUpdate,
                progress: @escaping @Sendable (Double) -> Void) async throws -> PluginInstallOutcome {
        try await simulate(progress)
        let plugin = store.mutate { s -> EnginePlugin? in
            guard let i = s.plugins.firstIndex(where: { $0.id == id }) else { return nil }
            s.plugins[i].rollbackVersion = s.plugins[i].version
            s.plugins[i].version = update.version
            s.plugins[i].update = nil
            s.plugins[i].lastChecked = Date()
            return s.plugins[i]
        }
        guard let plugin else { throw MESError(.notFound, "No plugin \(id).") }
        await onChange()
        return .installed(plugin)
    }

    func rollBack(plugin id: String) async throws {
        try await Task.sleep(for: .milliseconds(400))
        try store.mutate { s in
            guard let i = s.plugins.firstIndex(where: { $0.id == id }), let previous = s.plugins[i].rollbackVersion else {
                throw MESError(.engineError, "There's no version to roll back to.")
            }
            s.plugins[i].update = EngineUpdate(version: s.plugins[i].version)
            s.plugins[i].version = previous
            s.plugins[i].rollbackVersion = nil
        }
        await onChange()
    }

    func setEnabled(_ enabled: Bool, plugin id: String) async throws {
        store.mutate { s in
            if let i = s.plugins.firstIndex(where: { $0.id == id }) { s.plugins[i].enabled = enabled }
        }
        await onChange()
    }

    func checkForUpdates() async throws {
        try await Task.sleep(for: .milliseconds(700))
        store.mutate { s in for i in s.plugins.indices { s.plugins[i].lastChecked = Date() } }
    }

    func remove(plugin id: String) async throws {
        store.mutate { $0.plugins.removeAll { $0.id == id } }
        await onChange()
    }

    func revokeTrust(team id: String) async throws {
        try store.mutate { s in
            guard let team = s.trusted.first(where: { $0.id == id }), !team.builtIn else {
                throw MESError(.engineError, "This engine's own team can't be removed.")
            }
            s.trusted.removeAll { $0.id == id }
            for i in s.plugins.indices where s.plugins[i].team.id == id {
                s.plugins[i].state = .failed("Signed by \(team.team.name), which is no longer a trusted team.")
            }
        }
        await onChange()
    }

    private func simulate(_ progress: @Sendable (Double) -> Void, steps: Int = 12) async throws {
        for step in 1...steps {
            try await Task.sleep(for: .milliseconds(80))
            progress(Double(step) / Double(steps))
        }
    }
}

// MARK: - Worker processes

/// Real child processes standing in for Gaea's plugin workers, so the System page reads true footprints with
/// `proc_pid_rusage`. Each is this executable relaunched with `--mock-worker <MB>`: it touches that much memory and waits
/// for its parent to exit.
enum MockWorkers {
    static let flag = "--mock-worker"

    /// Runs as a worker if launched as one; never returns then.
    static func runIfWorker() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count,
              let megabytes = Int(arguments[index + 1]) else { return }
        let bytes = megabytes << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16384)
        for offset in stride(from: 0, to: bytes, by: 16384) { buffer.storeBytes(of: UInt8(offset & 0xff), toByteOffset: offset, as: UInt8.self) }
        let parent = getppid()
        while getppid() == parent { sleep(1) }
        exit(0)
    }

    /// Starts one worker per plugin, holding `megabytes` each.
    static func start(_ workers: [(plugin: EnginePlugin, megabytes: Int)]) -> [(process: Process, plugin: EnginePlugin)] {
        workers.compactMap { worker in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            process.arguments = [flag, "\(worker.megabytes)"]
            do {
                try process.run()
                return (process, worker.plugin)
            } catch {
                return nil
            }
        }
    }
}
