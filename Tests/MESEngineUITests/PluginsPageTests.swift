import Foundation
import MESCore
import MESEngineCore
@testable import MESEngineUI
import Testing

// The Plugins page's model over a fake plugin manager: the section appears only with a plugin backend; adds, trust,
// updates, rollbacks and switches reach the backend; a plugin from an untrusted team asks first; models know their plugin.

let ourTeam = EngineTeam(id: "CFZS6RXUCP", name: "Dustin Nielson")
let otherTeam = EngineTeam(id: "ABCDE12345", name: "Example Labs")

actor FakePluginManager: EnginePluginBackend {
    var installed: [EnginePlugin]
    var trusted: [EngineTrustedTeam] = [EngineTrustedTeam(team: ourTeam, builtIn: true)]
    var pending: [String: EnginePlugin] = [:]
    var calls: [String] = []

    init(_ plugins: [EnginePlugin]) { installed = plugins }

    func plugins() async -> [EnginePlugin] { installed }
    func trustedTeams() async -> [EngineTrustedTeam] { trusted }

    func add(repository: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> PluginInstallOutcome {
        calls.append("add \(repository.absoluteString)")
        progress(0.5)
        let owner = repository.pathComponents[1]
        if owner == "nobody" { throw MESError(.notFound, "No release.") }
        let team = owner == "xocialize" ? ourTeam : otherTeam
        let plugin = EnginePlugin(id: "com.\(owner).\(repository.lastPathComponent)", title: repository.lastPathComponent,
                                  repository: repository, version: "0.1.0", team: team)
        if trusted.contains(where: { $0.team == team }) {
            installed.append(plugin)
            return .installed(plugin)
        }
        let request = PluginTrustRequest(id: "req-1", team: team, pluginID: plugin.id, pluginTitle: plugin.title,
                                         version: plugin.version, repository: repository, notarized: true)
        pending[request.id] = plugin
        return .needsTrust(request)
    }

    func trust(_ request: PluginTrustRequest, progress: @escaping @Sendable (Double) -> Void) async throws {
        calls.append("trust \(request.team.id)")
        trusted.append(EngineTrustedTeam(team: request.team, addedAt: Date()))
        if let plugin = pending.removeValue(forKey: request.id) { installed.append(plugin) }
    }

    func decline(_ request: PluginTrustRequest) async {
        calls.append("decline \(request.team.id)")
        pending[request.id] = nil
    }

    func update(plugin id: String, to update: EngineUpdate,
                progress: @escaping @Sendable (Double) -> Void) async throws -> PluginInstallOutcome {
        calls.append("update \(id) \(update.version)")
        let i = installed.firstIndex { $0.id == id }!
        installed[i].rollbackVersion = installed[i].version
        installed[i].version = update.version
        installed[i].update = nil
        return .installed(installed[i])
    }

    func rollBack(plugin id: String) async throws {
        calls.append("rollback \(id)")
        let i = installed.firstIndex { $0.id == id }!
        installed[i].version = installed[i].rollbackVersion!
        installed[i].rollbackVersion = nil
    }

    func setEnabled(_ enabled: Bool, plugin id: String) async throws {
        calls.append("\(enabled ? "enable" : "disable") \(id)")
        let i = installed.firstIndex { $0.id == id }!
        installed[i].enabled = enabled
    }

    func checkForUpdates() async throws { calls.append("check") }
}

struct FakeConsoleBackend: EngineConsoleBackend {
    let modelList: [EngineModel]
    func activity() -> AsyncStream<EngineActivity> { AsyncStream { _ in } }
    func cancel(job id: String) async throws {}
    func operations() async -> [Descriptor] { [] }
    func models() async -> [EngineModel] { modelList }
    func setEnabled(_ enabled: Bool, model id: String) async throws {}
}

/// Waits up to two seconds for `condition`, for the console's fire-and-forget actions.
@MainActor
func eventually(_ condition: @MainActor () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

@MainActor
@Suite("Plugins page")
struct PluginsPageTests {
    let zImage = EnginePlugin(id: "com.xocialize.gaea.z-image", title: "Z-Image",
                              repository: URL(string: "https://github.com/xocialize/gaea-plugin-z-image")!, version: "1.0.0",
                              update: EngineUpdate(version: "1.1.0"), team: ourTeam, models: ["z-image-turbo"])

    func models() -> [EngineModel] {
        [EngineModel(id: "z-image-turbo", title: "Z-Image Turbo", license: .apache2,
                     plugin: .init(id: zImage.id, title: zImage.title), version: "1.0.0", update: EngineUpdate(version: "1.1.0")),
         EngineModel(id: "classic", title: "Classic upscale", license: .apache2, install: .builtIn)]
    }

    @Test("The Plugins section appears only for an engine attached with a plugin backend")
    func sectionOnlyWithPlugins() async {
        let plain = EngineConsoleModel(info: EngineConsoleInfo(name: "E", profile: "Image", symbol: "photo", version: "1"))
        plain.attach(FakeConsoleBackend(modelList: []))
        #expect(plain.sections == [.queue, .models, .system])

        let gaea = EngineConsoleModel(info: EngineConsoleInfo(name: "Gaea", profile: "Image", symbol: "photo", version: "1"))
        gaea.attach(FakeConsoleBackend(modelList: models()), plugins: FakePluginManager([zImage]))
        #expect(gaea.sections == [.queue, .models, .plugins, .system])
        #expect(await eventually { gaea.plugins.count == 1 && gaea.models.count == 2 })
        #expect(gaea.updatesAvailable == 1)
        #expect(gaea.models(of: zImage).map(\.id) == ["z-image-turbo"])
        #expect(gaea.trustedTeams.map(\.team) == [ourTeam])
    }

    @Test("Add from a trusted team installs; from a new team it asks, and trusting finishes the install")
    func addAndTrust() async throws {
        let manager = FakePluginManager([])
        let console = EngineConsoleModel(info: EngineConsoleInfo(name: "Gaea", profile: "Image", symbol: "photo", version: "1"))
        console.attach(FakeConsoleBackend(modelList: []), plugins: manager)

        try await console.addPlugin(repository: URL(string: "https://github.com/xocialize/gaea-plugin-flux")!)
        #expect(console.plugins.map(\.id) == ["com.xocialize.gaea-plugin-flux"])
        #expect(console.selectedPluginID == "com.xocialize.gaea-plugin-flux")
        #expect(console.trustPrompt == nil)

        try await console.addPlugin(repository: URL(string: "https://github.com/example/gaea-plugin-wan")!)
        let request = try #require(console.trustPrompt)
        #expect(request.team == otherTeam)
        #expect(console.plugins.count == 1)   // nothing installed until the operator answers

        console.trust(request)
        #expect(console.trustPrompt == nil)
        #expect(await eventually { console.plugins.count == 2 && console.trustedTeams.count == 2 })
        #expect(await manager.calls.contains("trust ABCDE12345"))

        // A failed add throws for the sheet to show, and installs nothing.
        await #expect(throws: MESError.self) {
            try await console.addPlugin(repository: URL(string: "https://github.com/nobody/nothing")!)
        }
        #expect(console.plugins.count == 2)
    }

    @Test("Declining a team installs nothing")
    func decline() async throws {
        let manager = FakePluginManager([])
        let console = EngineConsoleModel(info: EngineConsoleInfo(name: "Gaea", profile: "Image", symbol: "photo", version: "1"))
        console.attach(FakeConsoleBackend(modelList: []), plugins: manager)
        try await console.addPlugin(repository: URL(string: "https://github.com/example/gaea-plugin-wan")!)
        console.decline(try #require(console.trustPrompt))
        #expect(await eventually { await manager.calls.contains("decline ABCDE12345") })
        #expect(console.plugins.isEmpty)
        #expect(await manager.pending.isEmpty)
    }

    @Test("Update, roll back and switch a plugin off reach the backend and refresh the page")
    func updateRollBackDisable() async {
        let manager = FakePluginManager([zImage])
        let console = EngineConsoleModel(info: EngineConsoleInfo(name: "Gaea", profile: "Image", symbol: "photo", version: "1"))
        console.attach(FakeConsoleBackend(modelList: models()), plugins: manager)
        #expect(await eventually { console.plugins.count == 1 })

        console.update(plugin: console.plugins[0])
        #expect(await eventually { console.plugins[0].version == "1.1.0" && console.pluginWork.isEmpty })
        #expect(console.plugins[0].rollbackVersion == "1.0.0")
        #expect(console.updatesAvailable == 0)

        console.rollBack(plugin: console.plugins[0])
        #expect(await eventually { console.plugins[0].version == "1.0.0" })

        console.setEnabled(false, plugin: zImage.id)
        #expect(console.plugins[0].enabled == false)   // optimistic
        #expect(await eventually { await manager.calls.contains("disable \(zImage.id)") })

        console.checkForUpdates()
        #expect(await eventually { await manager.calls.contains("check") && !console.isCheckingForUpdates })
        #expect(console.actionError == nil)
    }

    @Test("Repo URLs: GitHub URLs with or without .git, and owner/repo; anything else is refused")
    func repositoryURLs() {
        #expect(EngineConsoleModel.repositoryURL("https://github.com/xocialize/gaea-plugin-z-image")?.absoluteString
            == "https://github.com/xocialize/gaea-plugin-z-image")
        #expect(EngineConsoleModel.repositoryURL("  https://github.com/a/b.git ")?.absoluteString == "https://github.com/a/b.git")
        #expect(EngineConsoleModel.repositoryURL("xocialize/gaea-plugin-flux")?.absoluteString
            == "https://github.com/xocialize/gaea-plugin-flux")
        #expect(EngineConsoleModel.repositoryURL("") == nil)
        #expect(EngineConsoleModel.repositoryURL("https://github.com/onlyowner") == nil)
        #expect(EngineConsoleModel.repositoryURL("ftp://example.com/a/b") == nil)
        #expect(EngineConsoleModel.repositoryURL("not a url") == nil)
    }
}
